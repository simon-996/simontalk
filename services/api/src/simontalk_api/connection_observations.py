import json
from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import ConfigDict, Field, model_validator
from sqlalchemy import select

from simontalk_api.connections import ConnectionControl, own_connection
from simontalk_api.errors import APIError
from simontalk_api.models import ConnectionObservation
from simontalk_api.practice import own_preparation
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest

MAX_CONNECTION_OBSERVATIONS = 256
ObservationCode = Literal[
    "requesting_microphone",
    "negotiating",
    "transport_connected",
    "configuration_confirmed",
    "microphone_active",
    "playback_waiting",
    "playback_blocked",
    "playback_playing",
    "playback_paused",
    "muted",
    "unmuted",
    "local_closed",
]
ObservationReason = Literal[
    "user_stop",
    "background",
    "disposed",
    "account_changed",
    "lease_expired",
    "connection_failed",
    "configuration_failed",
    "other",
]


class ObservationEvent(InputModel):
    event_id: UUID
    sequence: int = Field(strict=True, ge=1, le=2147483647)
    code: ObservationCode
    elapsed_ms: int = Field(strict=True, ge=0, le=86400000)
    reason: ObservationReason | None = None

    @model_validator(mode="after")
    def reason_only_for_close(self):
        if self.reason is not None and self.code != "local_closed":
            raise ValueError("Reason requires local closure")
        return self


class ObservationBatch(ConnectionControl):
    events: list[ObservationEvent] = Field(min_length=1, max_length=16)

    @model_validator(mode="after")
    def ordered_unique_events(self):
        sequences = [e.sequence for e in self.events]
        if sequences != sorted(set(sequences)) or len({e.event_id for e in self.events}) != len(
            self.events
        ):
            raise ValueError("Events must have unique IDs and increasing sequences")
        return self


class ObservationIdentity(InputModel):
    source: Literal["client_observed"] = "client_observed"
    connection_id: UUID
    client_instance_id: UUID
    epoch: int
    last_sequence: int
    total_events: int


class ObservationAcknowledgement(ObservationIdentity):
    acknowledged_event_ids: list[UUID]


class ObservationEventOutput(ObservationEvent):
    model_config = ConfigDict(from_attributes=True, extra="forbid")
    received_at: datetime


class ObservationPage(ObservationIdentity):
    events: list[ObservationEventOutput]
    next_after_sequence: int
    has_more: bool


def _rows(db, connection_id):
    return list(
        db.scalars(
            select(ConnectionObservation)
            .where(ConnectionObservation.connection_id == connection_id)
            .order_by(ConnectionObservation.sequence)
        )
    )


def _identity(connection, rows):
    return {
        "connection_id": connection.id,
        "client_instance_id": connection.client_instance_id,
        "epoch": connection.epoch,
        "last_sequence": rows[-1].sequence if rows else 0,
        "total_events": len(rows),
    }


def append_observations(db, user_id, session_id, connection_id, payload):
    own_preparation(db, user_id, session_id, lock=True)
    connection = own_connection(db, user_id, session_id, connection_id, lock=True)
    if (
        connection.client_instance_id != payload.client_instance_id
        or connection.epoch != payload.epoch
    ):
        raise APIError(409, "connection_identity_changed", "连接身份或代次已变化。")
    rows = _rows(db, connection_id)
    by_id = {r.event_id: r for r in rows}
    by_sequence = {r.sequence: r for r in rows}
    last_sequence = rows[-1].sequence if rows else 0
    additions = []
    for event in payload.events:
        fingerprint = digest(
            json.dumps(event.model_dump(mode="json"), sort_keys=True, separators=(",", ":"))
        )
        previous = by_id.get(event.event_id)
        if previous is not None:
            if previous.event_digest != fingerprint:
                raise APIError(409, "observation_conflict", "观测标识已用于其他内容。")
            continue
        if event.sequence in by_sequence:
            raise APIError(409, "observation_conflict", "观测序号已用于其他内容。")
        if event.sequence <= last_sequence:
            raise APIError(409, "observation_sequence_stale", "观测序号已过期，请读取当前记录。")
        additions.append(
            ConnectionObservation(
                connection_id=connection.id,
                client_instance_id=connection.client_instance_id,
                epoch=connection.epoch,
                event_digest=fingerprint,
                **event.model_dump(),
            )
        )
    if len(rows) + len(additions) > MAX_CONNECTION_OBSERVATIONS:
        raise APIError(429, "observation_limit_reached", "这条连接的观测记录已达上限。")
    db.add_all(additions)
    db.commit()
    combined = sorted([*rows, *additions], key=lambda r: r.sequence)
    return ObservationAcknowledgement(
        **_identity(connection, combined),
        acknowledged_event_ids=[e.event_id for e in payload.events],
    )


def read_observations(db, user_id, session_id, connection_id, after_sequence, limit):
    connection = own_connection(db, user_id, session_id, connection_id)
    rows = _rows(db, connection_id)
    remaining = [r for r in rows if r.sequence > after_sequence]
    page = remaining[:limit]
    return ObservationPage(
        **_identity(connection, rows),
        events=[ObservationEventOutput.model_validate(r) for r in page],
        next_after_sequence=page[-1].sequence if page else after_sequence,
        has_more=len(remaining) > limit,
    )
