from pydantic import Field
from sqlalchemy import select

from simontalk_api.errors import APIError
from simontalk_api.models import RealtimeConnection
from simontalk_api.practice import own_preparation
from simontalk_api.schemas import InputModel
from simontalk_api.security import now


class DiscardPreparationInput(InputModel):
    expected_epoch: int = Field(strict=True, ge=0, le=2147483647)


def _unsafe():
    raise APIError(
        409, "preparation_not_discardable", "无法将这项记录作为未开始准备清理，请刷新核实。"
    )


def discard_preparation(db, user_id, session_id, payload):
    """Caller holds User lock. Never invoke upstream or adopt a client's media lease."""
    practice = own_preparation(db, user_id, session_id, lock=True)
    if payload.expected_epoch != practice.connection_epoch:
        raise APIError(409, "preparation_changed", "连接代次已变化，请刷新并重新确认。")
    if practice.status not in {"created", "connecting", "cancelled"}:
        _unsafe()
    connections = list(
        db.scalars(
            select(RealtimeConnection)
            .where(
                RealtimeConnection.session_id == session_id, RealtimeConnection.user_id == user_id
            )
            .order_by(RealtimeConnection.epoch)
            .with_for_update()
        )
    )
    # A deleted attempt is missing evidence, not evidence of never starting upstream.
    if len(connections) != practice.connection_epoch:
        _unsafe()
    pending = None
    for epoch, connection in enumerate(connections, start=1):
        if (
            connection.epoch != epoch
            or connection.termination_status != "not_started"
            or connection.offer_digest is not None
            or connection.signalling_started_at is not None
            or connection.signalling_finished_at is not None
        ):
            _unsafe()
        if connection.status == "preparing" and epoch == practice.connection_epoch:
            pending = connection
        elif connection.status not in {"closed", "failed"} or connection.ended_at is None:
            _unsafe()
    if (practice.status == "connecting") != (pending is not None):
        _unsafe()
    if practice.status == "cancelled":
        if practice.ended_at is None:
            _unsafe()
        return practice
    stamp = now()
    if pending is not None:
        pending.status = "closed"
        pending.state_reason = "cancelled_before_signalling"
        pending.ended_at = stamp
    practice.status = "cancelled"
    practice.state_reason = "cancelled_before_signalling"
    practice.ended_at = stamp
    db.commit()
    return practice
