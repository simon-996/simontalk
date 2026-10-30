import asyncio
from dataclasses import dataclass, field
from typing import Protocol
from uuid import UUID

from pydantic import Field, field_validator
from sqlalchemy import select
from starlette.concurrency import run_in_threadpool

from simontalk_api.connections import ConnectionControl, _expire, own_connection
from simontalk_api.errors import APIError
from simontalk_api.models import User
from simontalk_api.practice import own_preparation
from simontalk_api.practice_routes import locked_identity
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest, now, session_identity
from simontalk_api.termination_checks import ensure_termination_check

MAX_SDP_BYTES = 65536
EXCHANGE_TIMEOUT_SECONDS = 8


def valid_sdp(value):
    return (
        isinstance(value, str)
        and value.startswith(("v=0\r\n", "v=0\n"))
        and "\x00" not in value
        and len(value.encode("utf-8")) <= MAX_SDP_BYTES
    )


class OfferInput(ConnectionControl):
    offer: str = Field(strict=True, min_length=1, max_length=MAX_SDP_BYTES, repr=False)

    @field_validator("offer")
    @classmethod
    def validate_offer(cls, value):
        if not valid_sdp(value):
            raise ValueError("Invalid offer")
        return value


class AnswerOutput(InputModel):
    session_id: UUID
    connection_id: UUID
    client_instance_id: UUID
    epoch: int
    answer: str = Field(repr=False)


class SignallingGateway(Protocol):
    def check_configuration(self, configuration: dict) -> None:
        """Local validation only: fixed endpoints, supported config and credentials."""
        ...

    async def exchange_offer(self, configuration: dict, offer: str) -> str:
        """One cancellable exchange, no retry/redirect to a client-provided URL."""
        ...


class UnavailableSignallingGateway:
    def check_configuration(self, configuration):
        raise APIError(503, "realtime_unavailable", "实时语音尚未就绪。")

    async def exchange_offer(self, configuration, offer):
        raise APIError(503, "realtime_unavailable", "实时语音尚未就绪。")


@dataclass(frozen=True)
class SignallingAttempt:
    user_id: UUID
    auth_id: UUID
    session_id: UUID
    connection_id: UUID
    client_instance_id: UUID
    epoch: int
    offer_digest: str
    configuration: dict
    gateway: SignallingGateway = field(repr=False, compare=False)


def _configuration(request, user_id, practice, connection):
    permit = request.app.state.practice_admission.admit(user_id)
    configuration = {
        name: getattr(permit, name) for name in ("provider", "region", "model", "config_id")
    }
    if (
        configuration != connection.configuration
        or configuration != practice.configuration["provider"]
    ):
        raise APIError(409, "practice_configuration_changed", "语音配置已更改。")
    return configuration


def prepare_offer(request, session_id, connection_id, payload):
    with request.app.state.session_factory() as db:
        user = locked_identity(request, db)
        practice = own_preparation(db, user.id, session_id, lock=True)
        connection = own_connection(db, user.id, session_id, connection_id, lock=True)
        if (
            connection.client_instance_id != payload.client_instance_id
            or connection.epoch != payload.epoch
        ):
            raise APIError(409, "connection_identity_changed", "连接身份或代次已变化。")
        if practice.connection_epoch != payload.epoch:
            raise APIError(409, "connection_epoch_changed", "连接代次已变化。")
        fingerprint = digest(payload.offer)
        if connection.offer_digest is not None:
            code = (
                "signalling_already_attempted"
                if connection.offer_digest == fingerprint
                else "signalling_offer_conflict"
            )
            raise APIError(409, code, "这条连接已尝试交换信令，不能重复调用上游。")
        if (
            practice.status != "connecting"
            or connection.status != "preparing"
            or connection.termination_status != "not_started"
        ):
            raise APIError(409, "signalling_state_changed", "连接状态暂不允许交换信令。")
        stamp = now()
        if connection.lease_expires_at <= stamp:
            _expire(db, practice, connection, stamp)
            db.commit()
            raise APIError(409, "connection_lease_expired", "连接租约已到期。")
        configuration = _configuration(request, user.id, practice, connection)
        gateway = request.app.state.signalling_gateway
        gateway.check_configuration(dict(configuration))
        auth_id = session_identity(request, db)[0].id
        connection.offer_digest = fingerprint
        connection.signalling_started_at = stamp
        connection.status = "negotiating"
        connection.termination_status = "unknown"
        connection.state_reason = "signalling_started"
        attempt = SignallingAttempt(
            user.id,
            auth_id,
            session_id,
            connection_id,
            payload.client_instance_id,
            payload.epoch,
            fingerprint,
            configuration,
            gateway,
        )
        # External exchange must never start unless this durable claim commits.
        db.commit()
        return attempt


def _unknown(db, practice, connection, stamp, reason):
    connection.status = "unknown"
    connection.termination_status = "unknown"
    connection.signalling_finished_at = stamp
    connection.state_reason = reason
    if practice.status not in {"ending", "completed"}:
        practice.status = "interrupted"
    ensure_termination_check(db, connection, stamp)
    db.commit()


def finish_offer(request, attempt, answer, failure):
    with request.app.state.session_factory() as db:
        owner = db.scalar(select(User.id).where(User.id == attempt.user_id).with_for_update())
        if owner is None:
            raise APIError(404, "connection_not_found", "没有找到这条连接。")
        practice = own_preparation(db, owner, attempt.session_id, lock=True)
        connection = own_connection(db, owner, attempt.session_id, attempt.connection_id, lock=True)
        if (
            practice.connection_epoch != attempt.epoch
            or practice.status != "connecting"
            or connection.epoch != attempt.epoch
            or connection.client_instance_id != attempt.client_instance_id
            or connection.offer_digest != attempt.offer_digest
            or connection.status != "negotiating"
            or connection.termination_status != "unknown"
        ):
            raise APIError(409, "signalling_state_changed", "信令结果已过时，请读取当前状态。")
        stamp = now()
        try:
            auth, _ = session_identity(request, db)
            if auth.id != attempt.auth_id:
                raise APIError(409, "account_changed", "账号身份已变化。")
            configuration = _configuration(request, owner, practice, connection)
            if configuration != attempt.configuration:
                raise APIError(409, "practice_configuration_changed", "语音配置已更改。")
        except APIError:
            _unknown(db, practice, connection, stamp, "signalling_authorization_lost")
            raise
        if connection.lease_expires_at <= stamp:
            _unknown(db, practice, connection, stamp, "lease_expired")
            raise APIError(409, "connection_lease_expired", "连接租约已到期。")
        if failure is not None:
            _unknown(db, practice, connection, stamp, failure)
            raise APIError(
                504 if failure == "signalling_timeout" else 502,
                failure,
                "信令交换未能确认，请读取连接状态。",
            )
        connection.status = "configuring"
        connection.state_reason = "answer_received"
        connection.signalling_finished_at = stamp
        db.commit()
        return AnswerOutput(
            session_id=attempt.session_id,
            connection_id=attempt.connection_id,
            client_instance_id=attempt.client_instance_id,
            epoch=attempt.epoch,
            answer=answer,
        )


async def exchange_offer(request, session_id, connection_id, payload):
    attempt = await run_in_threadpool(prepare_offer, request, session_id, connection_id, payload)
    answer, failure = None, None
    try:
        async with asyncio.timeout(EXCHANGE_TIMEOUT_SECONDS):
            answer = await attempt.gateway.exchange_offer(
                dict(attempt.configuration), payload.offer
            )
        if not valid_sdp(answer):
            answer, failure = None, "signalling_invalid_answer"
    except TimeoutError:
        failure = "signalling_timeout"
    except Exception:
        # Do not log SDK errors: they may include SDP, credentials or upstream URLs.
        failure = "signalling_failed"
    # Cancellation/process loss can leave negotiating/unknown; lease scanning keeps
    # occupancy. A late result must pass a fresh transaction before any answer leaves.
    return await run_in_threadpool(finish_offer, request, attempt, answer, failure)
