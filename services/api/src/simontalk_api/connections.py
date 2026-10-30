from datetime import datetime, timedelta
from uuid import UUID

from pydantic import ConfigDict, Field
from sqlalchemy import select

from simontalk_api.errors import APIError
from simontalk_api.models import (
    OCCUPIED_CONNECTION_STATES,
    PracticeSession,
    RealtimeConnection,
    User,
)
from simontalk_api.practice import own_preparation
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest, now
from simontalk_api.termination_checks import ensure_termination_check

LEASE_SECONDS = 45  # Business liveness only; never an upstream billing limit.
SCANNABLE_STATES = tuple(value for value in OCCUPIED_CONNECTION_STATES if value != "unknown")


class ConnectionInput(InputModel):
    client_instance_id: UUID
    expected_epoch: int = Field(strict=True, ge=0, le=2147483647)


class ConnectionControl(InputModel):
    client_instance_id: UUID
    epoch: int = Field(strict=True, ge=1, le=2147483647)


class ConnectionOutput(InputModel):
    model_config = ConfigDict(from_attributes=True)
    id: UUID
    session_id: UUID
    client_instance_id: UUID
    epoch: int
    configuration: dict
    status: str
    termination_status: str
    state_reason: str | None
    last_seen_at: datetime
    lease_expires_at: datetime
    created_at: datetime
    ended_at: datetime | None


def create_connection(db, user_id, session_id, payload, key, admission):
    practice = own_preparation(db, user_id, session_id, lock=True)
    request_digest = digest(payload.model_dump_json())
    existing = db.scalar(
        select(RealtimeConnection).where(
            RealtimeConnection.user_id == user_id,
            RealtimeConnection.creation_key == key,
        )
    )
    if existing is not None:
        if existing.session_id != session_id or existing.request_digest != request_digest:
            raise APIError(409, "idempotency_conflict", "这个请求已用于其他连接设置，请重新确认。")
        return existing
    if practice.status not in {"created", "interrupted"}:
        raise APIError(409, "connection_in_progress", "当前练习暂不能新建连接。")
    if payload.expected_epoch != practice.connection_epoch:
        raise APIError(409, "connection_epoch_changed", "连接状态已更新，请读取当前状态后重试。")
    if practice.connection_epoch == 2147483647:
        raise APIError(409, "connection_epoch_exhausted", "这次练习无法再创建连接。")
    occupied = db.scalar(
        select(RealtimeConnection.id)
        .where(
            RealtimeConnection.user_id == user_id,
            RealtimeConnection.status.in_(OCCUPIED_CONNECTION_STATES),
        )
        .limit(1)
    )
    if occupied is not None:
        raise APIError(409, "connection_in_progress", "已有连接尚未安全结束。")
    permit = admission.admit(user_id)
    configuration = {
        name: getattr(permit, name) for name in ("provider", "region", "model", "config_id")
    }
    if configuration != practice.configuration["provider"]:
        raise APIError(409, "practice_configuration_changed", "语音配置已更改，请重新准备练习。")
    stamp = now()
    connection = RealtimeConnection(
        session_id=session_id,
        user_id=user_id,
        creation_key=key,
        request_digest=request_digest,
        client_instance_id=payload.client_instance_id,
        epoch=practice.connection_epoch + 1,
        configuration=configuration,
        # Keep the creation/heartbeat/lease ordering on one application clock.
        # A database clock slightly ahead would otherwise invalidate this read.
        created_at=stamp,
        last_seen_at=stamp,
        lease_expires_at=stamp + timedelta(seconds=LEASE_SECONDS),
    )
    db.add(connection)
    practice.connection_epoch = connection.epoch
    practice.status = "connecting"
    db.commit()
    return connection


def own_connection(db, user_id, session_id, connection_id, *, lock=False):
    query = select(RealtimeConnection).where(
        RealtimeConnection.id == connection_id,
        RealtimeConnection.session_id == session_id,
        RealtimeConnection.user_id == user_id,
    )
    if lock:
        query = query.with_for_update()
    connection = db.scalar(query)
    if connection is None:
        raise APIError(404, "connection_not_found", "没有找到这次连接。")
    return connection


def _controlled_connection(db, user_id, session_id, connection_id, payload):
    practice = own_preparation(db, user_id, session_id, lock=True)
    connection = own_connection(db, user_id, session_id, connection_id, lock=True)
    if (
        connection.epoch != payload.epoch
        or connection.client_instance_id != payload.client_instance_id
    ):
        raise APIError(409, "connection_identity_changed", "连接代次或当前客户端不匹配。")
    return practice, connection


def _latest(practice, connection):
    if practice.connection_epoch != connection.epoch:
        raise APIError(409, "connection_epoch_changed", "这条连接已不是当前连接。")


def _restore_preparation_state(db, practice):
    if practice.status in {"ending", "completed"}:
        return
    upstream = db.scalar(
        select(RealtimeConnection.id)
        .where(
            RealtimeConnection.session_id == practice.id,
            RealtimeConnection.termination_status != "not_started",
        )
        .limit(1)
    )
    practice.status = "interrupted" if upstream is not None else "created"


def _expire(db, practice, connection, stamp):
    connection.state_reason = "lease_expired"
    if connection.status == "preparing" and connection.termination_status == "not_started":
        connection.status = "failed"
        connection.ended_at = stamp
        _restore_preparation_state(db, practice)
    else:
        connection.status = "unknown"
        connection.termination_status = "unknown"
        if practice.status not in {"ending", "completed"}:
            practice.status = "interrupted"
        ensure_termination_check(db, connection, stamp)


def renew_connection(db, user_id, session_id, connection_id, payload):
    practice, connection = _controlled_connection(db, user_id, session_id, connection_id, payload)
    _latest(practice, connection)
    if practice.status in {"ending", "completed"} or connection.status not in SCANNABLE_STATES:
        raise APIError(409, "connection_not_renewable", "这条连接已停止或无法确认，不能续租。")
    stamp = now()
    if connection.lease_expires_at <= stamp:
        _expire(db, practice, connection, stamp)
        db.commit()
        raise APIError(409, "connection_lease_expired", "连接租约已到期，请读取当前状态。")
    connection.last_seen_at = stamp
    connection.lease_expires_at = stamp + timedelta(seconds=LEASE_SECONDS)
    db.commit()
    return connection


def cancel_connection(db, user_id, session_id, connection_id, payload):
    practice, connection = _controlled_connection(db, user_id, session_id, connection_id, payload)
    if connection.status in {"closed", "failed"} and connection.termination_status == "not_started":
        return connection
    _latest(practice, connection)
    if connection.status != "preparing" or connection.termination_status != "not_started":
        raise APIError(
            409, "connection_not_cancellable", "已进入或无法确认上游连接，不能作为准备取消。"
        )
    stamp = now()
    if connection.lease_expires_at <= stamp:
        _expire(db, practice, connection, stamp)
        db.commit()
        raise APIError(409, "connection_lease_expired", "连接租约已到期，请读取当前状态。")
    connection.status = "closed"
    connection.state_reason = "cancelled_before_signalling"
    connection.ended_at = stamp
    _restore_preparation_state(db, practice)
    db.commit()
    return connection


def _expired_candidates(db, stamp, limit):
    return db.execute(
        select(RealtimeConnection.id, RealtimeConnection.user_id, RealtimeConnection.session_id)
        .where(
            RealtimeConnection.status.in_(SCANNABLE_STATES),
            RealtimeConnection.lease_expires_at <= stamp,
        )
        .order_by(RealtimeConnection.lease_expires_at, RealtimeConnection.id)
        .limit(limit)
    ).all()


def expire_connection_leases(db, *, limit=100):
    """Caller commits. Unknown upstream sessions remain occupied, never billed as zero."""
    if type(limit) is not int or not 1 <= limit <= 1000:
        raise ValueError("Invalid scan limit")
    stamp = now()
    count = 0
    for connection_id, user_id, session_id in _expired_candidates(db, stamp, limit):
        # Match all authenticated mutations' lock order; skip busy rows instead of blocking them.
        owner = db.scalar(
            select(User.id).where(User.id == user_id).with_for_update(skip_locked=True)
        )
        if owner is None:
            continue
        practice = db.scalar(
            select(PracticeSession)
            .where(PracticeSession.id == session_id, PracticeSession.user_id == user_id)
            .with_for_update(skip_locked=True)
            .execution_options(populate_existing=True)
        )
        if practice is None:
            continue
        connection = db.scalar(
            select(RealtimeConnection)
            .where(
                RealtimeConnection.id == connection_id,
                RealtimeConnection.status.in_(SCANNABLE_STATES),
                RealtimeConnection.lease_expires_at <= stamp,
            )
            .with_for_update(skip_locked=True)
            .execution_options(populate_existing=True)
        )
        if connection is None or connection.epoch != practice.connection_epoch:
            continue
        _expire(db, practice, connection, stamp)
        count += 1
    return count
