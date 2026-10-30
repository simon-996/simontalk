"""Bounded client-reported final text; never evidence of playback or termination."""

import json
from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import Field, field_validator, model_validator
from sqlalchemy import select

from simontalk_api.connections import ConnectionControl, own_connection
from simontalk_api.errors import APIError
from simontalk_api.models import FinalTranscript
from simontalk_api.playback_evidence import validate_transcript_evidence
from simontalk_api.practice import own_preparation
from simontalk_api.practice_completion import try_finalize_completion, validate_completion_append
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest

MAX_TRANSCRIPT_EVENTS = 512
MAX_TRANSCRIPT_TURNS = 256
MAX_TRANSCRIPT_BYTES = 1024 * 1024


class TranscriptEvent(InputModel):
    event_id: UUID
    sequence: int = Field(strict=True, ge=1, le=2147483647)
    turn_id: UUID
    turn_index: int = Field(strict=True, ge=1, le=2147483647)
    role: Literal["user", "assistant"]
    revision: int = Field(strict=True, ge=1, le=2147483647)
    text: str = Field(strict=True)
    response_id: UUID | None = None
    provider_item_id: str | None = Field(default=None, strict=True, min_length=1, max_length=256)

    @field_validator("text", "provider_item_id")
    @classmethod
    def valid_unicode(cls, value, info):
        if value is not None:
            if "\x00" in value:
                raise ValueError("NUL is not supported")
            try:
                size = len(value.encode("utf-8", errors="strict"))
            except UnicodeError as error:
                raise ValueError("Invalid Unicode") from error
            if info.field_name == "text" and size > 8192:
                raise ValueError("Text limit exceeded")
        return value

    @model_validator(mode="after")
    def response_matches_role(self):
        if (self.role == "assistant") != (self.response_id is not None):
            raise ValueError("Response identity must match role")
        return self


class TranscriptBatch(ConnectionControl):
    events: list[TranscriptEvent] = Field(min_length=1, max_length=4)

    @model_validator(mode="after")
    def ordered_unique_events(self):
        sequences = [event.sequence for event in self.events]
        if sequences != sorted(set(sequences)) or len({e.event_id for e in self.events}) != len(
            self.events
        ):
            raise ValueError("Events must have unique IDs and increasing sequences")
        return self


class TranscriptIdentity(InputModel):
    source: Literal["client_reported"] = "client_reported"
    account_id: UUID
    session_id: UUID
    connection_id: UUID
    client_instance_id: UUID
    epoch: int
    last_sequence: int
    total_events: int
    total_text_bytes: int


class TranscriptAcknowledgement(TranscriptIdentity):
    acknowledged_event_ids: list[UUID]


class TranscriptEventOutput(TranscriptEvent):
    received_at: datetime
    delivery_status: Literal["unknown"] | None


class TranscriptPage(TranscriptIdentity):
    events: list[TranscriptEventOutput]
    next_after_sequence: int
    has_more: bool


def _rows(db, connection_id):
    return list(
        db.scalars(
            select(FinalTranscript)
            .where(FinalTranscript.connection_id == connection_id)
            .order_by(FinalTranscript.sequence)
        )
    )


def _identity(connection, rows):
    return {
        "account_id": connection.user_id,
        "session_id": connection.session_id,
        "connection_id": connection.id,
        "client_instance_id": connection.client_instance_id,
        "epoch": connection.epoch,
        "last_sequence": rows[-1].sequence if rows else 0,
        "total_events": len(rows),
        "total_text_bytes": sum(len(row.text.encode("utf-8")) for row in rows),
    }


def append_transcripts(db, user_id, session_id, connection_id, payload):
    practice = own_preparation(db, user_id, session_id, lock=True)
    connection = own_connection(db, user_id, session_id, connection_id, lock=True)
    if (
        connection.client_instance_id != payload.client_instance_id
        or connection.epoch != payload.epoch
    ):
        raise APIError(409, "connection_identity_changed", "连接身份或代次已变化。")
    rows = _rows(db, connection_id)
    by_id = {row.event_id: row for row in rows}
    by_sequence = {row.sequence: row for row in rows}
    by_turn = {row.turn_id: row for row in rows}
    by_index = {row.turn_index: row.turn_id for row in rows}
    last_sequence = rows[-1].sequence if rows else 0
    additions = []
    for event in payload.events:
        fingerprint = digest(
            json.dumps(event.model_dump(mode="json"), sort_keys=True, separators=(",", ":"))
        )
        previous = by_id.get(event.event_id)
        if previous is not None:
            if previous.event_digest != fingerprint:
                raise APIError(409, "transcript_conflict", "文字标识已用于其他内容。")
            continue
        validate_completion_append(db, practice, connection, "transcripts", event)
        if event.sequence in by_sequence:
            raise APIError(409, "transcript_conflict", "文字序号已用于其他内容。")
        if event.sequence <= last_sequence:
            raise APIError(409, "transcript_sequence_stale", "文字序号已过期，请读取当前记录。")
        validate_transcript_evidence(db, connection_id, event)
        previous_turn = by_turn.get(event.turn_id)
        if previous_turn is not None:
            if any(
                getattr(previous_turn, key) != getattr(event, key)
                for key in ("turn_index", "role", "response_id", "provider_item_id")
            ):
                raise APIError(409, "transcript_conflict", "原话映射与已有记录不一致。")
            if event.revision <= previous_turn.revision:
                raise APIError(409, "transcript_revision_stale", "文字修订版本已过期。")
        if event.turn_index in by_index and by_index[event.turn_index] != event.turn_id:
            raise APIError(409, "transcript_conflict", "原话顺序已被其他记录使用。")
        row = FinalTranscript(
            connection_id=connection.id,
            client_instance_id=connection.client_instance_id,
            epoch=connection.epoch,
            event_digest=fingerprint,
            **event.model_dump(),
        )
        additions.append(row)
        by_turn[event.turn_id] = row
        by_index[event.turn_index] = event.turn_id
    combined = sorted([*rows, *additions], key=lambda row: row.sequence)
    identity = _identity(connection, combined)
    if (
        len(combined) > MAX_TRANSCRIPT_EVENTS
        or len(by_turn) > MAX_TRANSCRIPT_TURNS
        or identity["total_text_bytes"] > MAX_TRANSCRIPT_BYTES
    ):
        raise APIError(429, "transcript_limit_reached", "这条连接的最终文字记录已达上限。")
    db.add_all(additions)
    db.flush()
    try_finalize_completion(db, practice)
    db.commit()
    return TranscriptAcknowledgement(
        **identity, acknowledged_event_ids=[event.event_id for event in payload.events]
    )


def read_transcripts(db, user_id, session_id, connection_id, after_sequence, limit):
    own_preparation(db, user_id, session_id)
    connection = own_connection(db, user_id, session_id, connection_id)
    rows = _rows(db, connection_id)
    remaining = [row for row in rows if row.sequence > after_sequence]
    page = remaining[:limit]
    return TranscriptPage(
        **_identity(connection, rows),
        events=[
            TranscriptEventOutput(
                **{key: getattr(row, key) for key in TranscriptEvent.model_fields},
                received_at=row.received_at,
                delivery_status="unknown" if row.role == "assistant" else None,
            )
            for row in page
        ],
        next_after_sequence=page[-1].sequence if page else after_sequence,
        has_more=len(remaining) > limit,
    )
