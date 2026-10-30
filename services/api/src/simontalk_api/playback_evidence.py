"""Client-reported output evidence, independent of final text and media authority."""

import json
from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import Field, field_validator, model_validator
from sqlalchemy import select

from simontalk_api.connections import ConnectionControl, own_connection
from simontalk_api.errors import APIError
from simontalk_api.models import (
    FinalTranscript,
    PlaybackEvidence,
    PracticeCompletion,
    RealtimeConnection,
)
from simontalk_api.practice import own_preparation
from simontalk_api.practice_completion import try_finalize_completion, validate_completion_append
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest

MAX_PLAYBACK_EVENTS = 512
MAX_PLAYBACK_REVOCATIONS = 256
MAX_PLAYBACK_TURNS = 256
MAX_PLAYBACK_RESPONSES = 256
MAX_PLAYBACK_TEXT_BYTES = 2 * 1024 * 1024


class PlaybackEvent(InputModel):
    event_id: UUID
    sequence: int = Field(strict=True, ge=1, le=2147483647)
    kind: Literal["alignment", "freeze", "revoke"]
    response_id: UUID
    turn_id: UUID | None = None
    turn_index: int | None = Field(default=None, strict=True, ge=1, le=2147483647)
    transcript_revision: int | None = Field(default=None, strict=True, ge=0, le=2147483647)
    generated_text: str | None = Field(default=None, strict=True)
    transcript_final: bool | None = Field(default=None, strict=True)
    playback_revision: int | None = Field(default=None, strict=True, ge=0, le=2147483647)
    delivery_status: Literal["unknown", "not_played", "partial", "played"] | None = None
    played_text: str | None = Field(default=None, strict=True)
    played_until_ms: int | None = Field(default=None, strict=True, ge=0, le=86400000)
    evidence_source: Literal["unknown", "device_output_aligned"] | None = None
    stop_boundary_ms: int | None = Field(default=None, strict=True, ge=0, le=86400000)
    reason: Literal["interrupted", "normal_end"] | None = None

    @field_validator("generated_text", "played_text")
    @classmethod
    def valid_text(cls, value):
        if value is not None:
            if "\x00" in value:
                raise ValueError("NUL is not supported")
            try:
                size = len(value.encode("utf-8", errors="strict"))
            except UnicodeError as error:
                raise ValueError("Invalid Unicode") from error
            if size > 8192:
                raise ValueError("Text limit exceeded")
        return value

    @model_validator(mode="after")
    def valid_shape_and_alignment(self):
        optional = set(PlaybackEvent.model_fields) - {"event_id", "sequence", "kind", "response_id"}
        if self.kind == "revoke":
            if any(getattr(self, key) is not None for key in optional):
                raise ValueError("Revocation has no body")
            return self
        required = optional - {"played_until_ms", "stop_boundary_ms", "reason"}
        if any(getattr(self, key) is None for key in required):
            raise ValueError("Output snapshot is required")
        if self.kind == "alignment":
            if self.stop_boundary_ms is not None or self.reason is not None:
                raise ValueError("Alignment cannot freeze a response")
            if self.transcript_revision == 0 or self.playback_revision == 0:
                raise ValueError("Alignment requires positive versions")
        elif self.stop_boundary_ms is None or self.reason is None:
            raise ValueError("Freeze requires boundary and reason")
        if self.transcript_revision == 0 and (
            self.generated_text != "" or self.transcript_final or self.playback_revision != 0
        ):
            raise ValueError("Untranscribed freeze must be empty")
        if self.playback_revision == 0 and self.delivery_status != "unknown":
            raise ValueError("Version zero has no playback evidence")
        if self.delivery_status == "unknown":
            if (
                self.played_text != ""
                or self.played_until_ms is not None
                or self.evidence_source != "unknown"
            ):
                raise ValueError("Unknown output cannot claim playback")
        else:
            if self.evidence_source != "device_output_aligned":
                raise ValueError("Known output requires device alignment")
            if self.delivery_status == "not_played":
                if self.played_text != "" or self.played_until_ms != 0 or not self.transcript_final:
                    raise ValueError("Not played requires final text and zero output")
            elif self.delivery_status == "partial":
                if (
                    not self.played_text
                    or not self.played_until_ms
                    or not self.generated_text.startswith(self.played_text)
                    or self.generated_text == self.played_text
                ):
                    raise ValueError("Partial output must be a strict generated prefix")
            elif (
                not self.transcript_final
                or not self.played_text
                or not self.played_until_ms
                or self.played_text != self.generated_text
            ):
                raise ValueError("Played output requires the complete final text")
        if (
            self.stop_boundary_ms is not None
            and (self.played_until_ms or 0) > self.stop_boundary_ms
        ):
            raise ValueError("Output exceeds stop boundary")
        return self


class PlaybackBatch(ConnectionControl):
    events: list[PlaybackEvent] = Field(min_length=1, max_length=4)

    @model_validator(mode="after")
    def ordered_unique_events(self):
        sequences = [event.sequence for event in self.events]
        if sequences != sorted(set(sequences)) or len({e.event_id for e in self.events}) != len(
            self.events
        ):
            raise ValueError("Events must have unique IDs and increasing sequences")
        return self


class PlaybackIdentity(InputModel):
    source: Literal["client_reported"] = "client_reported"
    account_id: UUID
    session_id: UUID
    connection_id: UUID
    client_instance_id: UUID
    epoch: int
    last_sequence: int
    total_events: int
    total_text_bytes: int


class PlaybackAcknowledgement(PlaybackIdentity):
    acknowledged_event_ids: list[UUID]


class PlaybackEventOutput(PlaybackEvent):
    received_at: datetime


class PlaybackPage(PlaybackIdentity):
    sealed: bool = False
    recoverable: Literal[False] = False
    events: list[PlaybackEventOutput]
    next_after_sequence: int
    has_more: bool


def _rows(db, connection_id):
    return list(
        db.scalars(
            select(PlaybackEvidence)
            .where(PlaybackEvidence.connection_id == connection_id)
            .order_by(PlaybackEvidence.sequence)
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
        "total_text_bytes": sum(
            len((row.generated_text or "").encode("utf-8"))
            + len((row.played_text or "").encode("utf-8"))
            for row in rows
        ),
    }


def _conflict():
    raise APIError(409, "playback_conflict", "播放证据与已有记录不一致。")


def _same_snapshot(left, right):
    return all(
        getattr(left, key) == getattr(right, key)
        for key in (
            "playback_revision",
            "delivery_status",
            "played_text",
            "played_until_ms",
            "evidence_source",
        )
    )


def _check_progress(previous, event, *, freeze=False):
    if event.playback_revision < previous.playback_revision or (
        event.playback_revision == previous.playback_revision
        and (not freeze or not _same_snapshot(previous, event))
    ):
        raise APIError(409, "playback_revision_stale", "播放证据版本已过期。")
    if _same_snapshot(previous, event):
        return
    if (
        previous.delivery_status in {"played", "not_played"}
        and event.delivery_status != previous.delivery_status
    ) or (
        previous.delivery_status != "unknown"
        and (
            event.delivery_status == "unknown"
            or not event.played_text.startswith(previous.played_text)
            or event.played_until_ms < previous.played_until_ms
        )
    ):
        _conflict()


def validate_transcript_evidence(db, connection_id, event):
    """Both append APIs hold the same connection lock before checking this mapping."""
    for row in _rows(db, connection_id):
        if row.kind == "revoke" or (
            row.turn_id != event.turn_id and row.turn_index != event.turn_index
        ):
            continue
        if (
            row.turn_id != event.turn_id
            or row.turn_index != event.turn_index
            or event.role != "assistant"
            or row.response_id != event.response_id
            or (
                row.transcript_revision == event.revision
                and (row.generated_text != event.text or not row.transcript_final)
            )
            or (not row.transcript_final and row.transcript_revision >= event.revision)
        ):
            _conflict()


def _check_final_mapping(final_rows, event):
    for row in final_rows:
        if row.turn_id != event.turn_id and row.turn_index != event.turn_index:
            continue
        if (
            row.turn_id != event.turn_id
            or row.turn_index != event.turn_index
            or row.role != "assistant"
            or row.response_id != event.response_id
            or (
                row.revision == event.transcript_revision
                and (row.text != event.generated_text or not event.transcript_final)
            )
            or (not event.transcript_final and event.transcript_revision >= row.revision)
        ):
            _conflict()


def append_playback_evidence(db, user_id, session_id, connection_id, payload):
    practice = own_preparation(db, user_id, session_id, lock=True)
    connection = own_connection(db, user_id, session_id, connection_id, lock=True)
    if (
        connection.client_instance_id != payload.client_instance_id
        or connection.epoch != payload.epoch
    ):
        raise APIError(409, "connection_identity_changed", "连接身份或代次已变化。")
    rows = _rows(db, connection_id)
    final_rows = list(
        db.scalars(select(FinalTranscript).where(FinalTranscript.connection_id == connection_id))
    )
    by_id = {row.event_id: row for row in rows}
    by_sequence = {row.sequence: row for row in rows}
    last_sequence = rows[-1].sequence if rows else 0
    combined = list(rows)
    additions = []
    for event in payload.events:
        fingerprint = digest(
            json.dumps(event.model_dump(mode="json"), sort_keys=True, separators=(",", ":"))
        )
        previous = by_id.get(event.event_id)
        if previous is not None:
            if previous.event_digest != fingerprint:
                _conflict()
            continue
        validate_completion_append(db, practice, connection, "playback", event)
        if event.sequence in by_sequence:
            _conflict()
        if event.sequence <= last_sequence:
            raise APIError(409, "playback_sequence_stale", "播放证据序号已过期，请读取当前记录。")
        response_rows = [row for row in combined if row.response_id == event.response_id]
        if any(row.kind == "revoke" for row in response_rows):
            raise APIError(409, "playback_revoked", "这条回复的播放证据已撤销。")
        if event.kind != "revoke":
            _check_final_mapping(final_rows, event)
            turn_rows = [row for row in combined if row.turn_id == event.turn_id]
            if any(
                row.turn_index != event.turn_index or row.response_id != event.response_id
                for row in turn_rows
            ):
                _conflict()
            if any(
                row.turn_id != event.turn_id and row.turn_index == event.turn_index
                for row in combined
            ):
                _conflict()
            if turn_rows and event.transcript_revision < max(
                row.transcript_revision for row in turn_rows
            ):
                raise APIError(409, "playback_revision_stale", "播放证据文字版本已过期。")
            version_rows = [
                row for row in turn_rows if row.transcript_revision == event.transcript_revision
            ]
            if any(
                row.generated_text != event.generated_text
                or row.transcript_final != event.transcript_final
                for row in version_rows
            ):
                _conflict()
            if (
                any(
                    row.transcript_final and row.transcript_revision < event.transcript_revision
                    for row in turn_rows
                )
                and not event.transcript_final
            ):
                _conflict()
            response_freezes = [row for row in response_rows if row.kind == "freeze"]
            if event.kind == "freeze" and any(
                (row.played_until_ms or 0) > event.stop_boundary_ms for row in response_rows
            ):
                _conflict()
            if response_freezes:
                original = response_freezes[0]
                if event.kind == "freeze":
                    if (
                        event.stop_boundary_ms != original.stop_boundary_ms
                        or event.reason != original.reason
                    ):
                        _conflict()
                elif not any(row.turn_id == event.turn_id for row in response_freezes):
                    _conflict()
                if (event.played_until_ms or 0) > original.stop_boundary_ms:
                    _conflict()
            if event.kind == "freeze" and any(row.kind == "freeze" for row in turn_rows):
                _conflict()
            if version_rows:
                previous = max(version_rows, key=lambda row: row.playback_revision)
                _check_progress(previous, event, freeze=event.kind == "freeze")
        row = PlaybackEvidence(
            connection_id=connection.id,
            client_instance_id=connection.client_instance_id,
            epoch=connection.epoch,
            event_digest=fingerprint,
            **event.model_dump(),
        )
        additions.append(row)
        combined.append(row)
        by_id[row.event_id] = row
        by_sequence[row.sequence] = row
    combined.sort(key=lambda row: row.sequence)
    identity = _identity(connection, combined)
    if (
        sum(row.kind != "revoke" for row in combined) > MAX_PLAYBACK_EVENTS
        or sum(row.kind == "revoke" for row in combined) > MAX_PLAYBACK_REVOCATIONS
        or len({row.turn_id for row in combined if row.turn_id is not None}) > MAX_PLAYBACK_TURNS
        or len({row.response_id for row in combined}) > MAX_PLAYBACK_RESPONSES
        or identity["total_text_bytes"] > MAX_PLAYBACK_TEXT_BYTES
    ):
        raise APIError(429, "playback_limit_reached", "这条连接的播放证据记录已达上限。")
    db.add_all(additions)
    db.flush()
    try_finalize_completion(db, practice)
    db.commit()
    return PlaybackAcknowledgement(
        **identity, acknowledged_event_ids=[event.event_id for event in payload.events]
    )


def read_playback_evidence(db, user_id, session_id, connection_id, after_sequence, limit):
    own_preparation(db, user_id, session_id)
    connection = own_connection(db, user_id, session_id, connection_id)
    # The seal flag and all ledger rows must share the same SQL snapshot. Reading
    # the flag afterwards could label a pre-seal partial page as immutable.
    result = db.execute(
        select(PlaybackEvidence, PracticeCompletion.status)
        .select_from(RealtimeConnection)
        .outerjoin(PlaybackEvidence, PlaybackEvidence.connection_id == RealtimeConnection.id)
        .outerjoin(
            PracticeCompletion, PracticeCompletion.session_id == RealtimeConnection.session_id
        )
        .where(RealtimeConnection.id == connection_id)
        .order_by(PlaybackEvidence.sequence)
    ).all()
    rows = [row[0] for row in result if row[0] is not None]
    remaining = [row for row in rows if row.sequence > after_sequence]
    page = remaining[:limit]
    return PlaybackPage(
        sealed=bool(result and result[0][1] == "sealed"),
        **_identity(connection, rows),
        events=[
            PlaybackEventOutput(
                **{key: getattr(row, key) for key in PlaybackEvent.model_fields},
                received_at=row.received_at,
            )
            for row in page
        ],
        next_after_sequence=page[-1].sequence if page else after_sequence,
        has_more=len(remaining) > limit,
    )
