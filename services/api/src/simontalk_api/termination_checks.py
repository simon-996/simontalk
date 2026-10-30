"""Durable intent only: no configured upstream verifier and no release authority."""

from typing import Literal
from uuid import UUID

from pydantic import AwareDatetime, Field, model_validator
from sqlalchemy import select

from simontalk_api.errors import APIError
from simontalk_api.models import PracticeSession, RealtimeConnection, TerminationCheck, User
from simontalk_api.schemas import InputModel
from simontalk_api.security import now


class TerminationCheckSnapshot(InputModel):
    source: Literal["server_recorded"] = "server_recorded"
    account_id: UUID
    session_id: UUID
    connection_id: UUID
    client_instance_id: UUID
    epoch: int = Field(ge=1, le=2147483647, strict=True)
    status: Literal["not_requested", "blocked"]
    reason: Literal["capability_unavailable"] | None
    attempts: int = Field(ge=0, le=0, strict=True)
    created_at: AwareDatetime | None

    @model_validator(mode="after")
    def exact_state(self):
        if self.status == "not_requested":
            if self.reason is not None or self.created_at is not None:
                raise ValueError("Unexpected unrequested check data")
        elif self.reason != "capability_unavailable" or self.created_at is None:
            raise ValueError("Missing blocked check data")
        return self


def read_termination_check(db, user_id, session_id, connection_id):
    result = (
        db.execute(
            select(
                RealtimeConnection.user_id.label("account_id"),
                RealtimeConnection.session_id,
                RealtimeConnection.id.label("connection_id"),
                RealtimeConnection.client_instance_id,
                RealtimeConnection.epoch,
                TerminationCheck.status,
                TerminationCheck.reason,
                TerminationCheck.attempts,
                TerminationCheck.created_at,
            )
            .outerjoin(
                TerminationCheck,
                (TerminationCheck.connection_id == RealtimeConnection.id)
                & (TerminationCheck.client_instance_id == RealtimeConnection.client_instance_id)
                & (TerminationCheck.epoch == RealtimeConnection.epoch),
            )
            .where(
                RealtimeConnection.id == connection_id,
                RealtimeConnection.session_id == session_id,
                RealtimeConnection.user_id == user_id,
            )
        )
        .mappings()
        .one_or_none()
    )
    if result is None:
        raise APIError(404, "connection_not_found", "没有找到这次连接。")
    values = dict(result)
    if values["status"] is None:
        values.update(status="not_requested", reason=None, attempts=0, created_at=None)
    return TerminationCheckSnapshot(**values)


def ensure_termination_check(db, connection, stamp=None):
    if connection.offer_digest is None or connection.signalling_started_at is None:
        return False
    if db.get(TerminationCheck, connection.id) is not None:
        return False
    db.add(
        TerminationCheck(
            connection_id=connection.id,
            client_instance_id=connection.client_instance_id,
            epoch=connection.epoch,
            attempt_digest=connection.offer_digest,
            status="blocked",
            reason="capability_unavailable",
            attempts=0,
            created_at=stamp or now(),
        )
    )
    return True


def backfill_termination_checks(db, *, limit=100):
    if type(limit) is not int or not 1 <= limit <= 1000:
        raise ValueError("Invalid scan limit")
    candidates = db.execute(
        select(RealtimeConnection.id, RealtimeConnection.user_id, RealtimeConnection.session_id)
        .where(
            RealtimeConnection.status == "unknown",
            RealtimeConnection.offer_digest.is_not(None),
            RealtimeConnection.signalling_started_at.is_not(None),
            ~select(TerminationCheck.connection_id)
            .where(TerminationCheck.connection_id == RealtimeConnection.id)
            .exists(),
        )
        .order_by(RealtimeConnection.id)
        .limit(limit)
    ).all()
    count = 0
    for connection_id, user_id, session_id in candidates:
        if (
            db.scalar(select(User.id).where(User.id == user_id).with_for_update(skip_locked=True))
            is None
        ):
            continue
        if (
            db.scalar(
                select(PracticeSession.id)
                .where(PracticeSession.id == session_id, PracticeSession.user_id == user_id)
                .with_for_update(skip_locked=True)
            )
            is None
        ):
            continue
        connection = db.scalar(
            select(RealtimeConnection)
            .where(RealtimeConnection.id == connection_id, RealtimeConnection.status == "unknown")
            .with_for_update(skip_locked=True)
            .execution_options(populate_existing=True)
        )
        if connection is not None:
            count += ensure_termination_check(db, connection)
    return count
