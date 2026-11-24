"""Persist conservative WebSocket closure evidence; no route or remote I/O."""

from uuid import UUID

from sqlalchemy import select

from simontalk_api.connections import own_connection
from simontalk_api.errors import APIError
from simontalk_api.models import TerminationCheck, User
from simontalk_api.practice import own_preparation
from simontalk_api.security import now
from simontalk_api.termination_checks import ensure_termination_check
from simontalk_api.websocket_claim import WebSocketClaim, _fingerprint

_REASONS = {
    "network_failed",
    "disconnected",
    "cancelled",
    "auth_lost",
    "config_failed",
    "lease_expired",
}


def _invalid():
    raise APIError(409, "connection_identity_changed", "连接身份或状态已变化。")


def mark_websocket_unknown(session_factory, claim, reason):
    """Close an exact durable claim conservatively, even after login revocation."""
    if type(claim) is not WebSocketClaim or type(reason) is not str or reason not in _REASONS:
        _invalid()
    if (
        any(
            type(value) is not UUID
            for value in (
                claim.user_id,
                claim.auth_id,
                claim.session_id,
                claim.connection_id,
                claim.client_instance_id,
            )
        )
        or type(claim.epoch) is not int
        or not 1 <= claim.epoch <= 2147483647
        or claim.fingerprint
        != _fingerprint(
            claim.user_id,
            claim.session_id,
            claim.connection_id,
            claim.client_instance_id,
            claim.epoch,
        )
    ):
        _invalid()
    with session_factory() as db:
        owner = db.scalar(select(User.id).where(User.id == claim.user_id).with_for_update())
        if owner is None:
            _invalid()
        practice = own_preparation(db, owner, claim.session_id, lock=True)
        connection = own_connection(db, owner, claim.session_id, claim.connection_id, lock=True)
        if (
            practice.connection_epoch != claim.epoch
            or connection.epoch != claim.epoch
            or connection.client_instance_id != claim.client_instance_id
            or connection.offer_digest != claim.fingerprint
            or connection.signalling_started_at is None
            or connection.termination_status != "unknown"
            or connection.status
            not in {"negotiating", "configuring", "ready", "closing", "unknown"}
        ):
            _invalid()
        existing = db.get(TerminationCheck, connection.id)
        if existing is not None and existing.attempt_digest != claim.fingerprint:
            _invalid()
        first = connection.status != "unknown"
        stamp = max(now(), connection.signalling_started_at)
        if first:
            connection.status = "unknown"
            connection.state_reason = "websocket_" + reason
        if connection.signalling_finished_at is None:
            connection.signalling_finished_at = stamp
        if practice.status not in {"ending", "completed"}:
            practice.status = "interrupted"
        ensure_termination_check(db, connection, stamp)
        db.commit()
        return first
