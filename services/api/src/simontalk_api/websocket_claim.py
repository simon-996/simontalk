"""Durable one-shot WebSocket claim; not registered as an endpoint."""

from dataclasses import dataclass, field
from types import MappingProxyType
from uuid import UUID

from simontalk_api.connections import _expire, own_connection
from simontalk_api.errors import APIError
from simontalk_api.practice import own_preparation
from simontalk_api.practice_topics import PracticeTopic, practice_topic
from simontalk_api.qwen_websocket_session import (
    QwenSessionError,
    QwenSessionGate,
    RehearsalPrompt,
)
from simontalk_api.rehearsal_targets import verified_rehearsal_prompt
from simontalk_api.security import digest, now
from simontalk_api.websocket_identity import lock_websocket_identity


@dataclass(frozen=True, slots=True)
class WebSocketClaim:
    user_id: UUID
    auth_id: UUID
    session_id: UUID
    connection_id: UUID
    client_instance_id: UUID
    epoch: int
    fingerprint: str
    difficulty: str
    speech_pace: str
    configuration: MappingProxyType
    provider_attempt: object = field(repr=False, compare=False)
    rehearsal: RehearsalPrompt | None = None
    topic: PracticeTopic | None = None


def _fingerprint(user_id, session_id, connection_id, client_instance_id, epoch):
    return digest(
        f"simontalk:websocket:v1:{user_id.hex}:{session_id.hex}:"
        f"{connection_id.hex}:{client_instance_id.hex}:{epoch}"
    )


def claim_websocket(
    session_factory,
    identity,
    admission,
    gateway,
    *,
    session_id,
    connection_id,
    client_instance_id,
    epoch,
):
    """Commit the claim before returning a single, unstarted provider attempt."""
    if (
        any(type(value) is not UUID for value in (session_id, connection_id, client_instance_id))
        or type(epoch) is not int
        or not 1 <= epoch <= 2147483647
    ):
        raise APIError(409, "connection_identity_changed", "连接身份或代次已变化。")
    with session_factory() as db:
        auth = lock_websocket_identity(db, identity)
        practice = own_preparation(db, auth.user_id, session_id, lock=True)
        connection = own_connection(db, auth.user_id, session_id, connection_id, lock=True)
        if (
            connection.client_instance_id != client_instance_id
            or connection.epoch != epoch
            or practice.connection_epoch != epoch
        ):
            raise APIError(409, "connection_identity_changed", "连接身份或代次已变化。")
        if connection.offer_digest is not None:
            raise APIError(409, "signalling_already_attempted", "这条连接已尝试启动。")
        if (
            practice.status != "connecting"
            or connection.status != "preparing"
            or connection.termination_status != "not_started"
        ):
            raise APIError(409, "signalling_state_changed", "连接状态暂不允许启动。")
        stamp = now()
        if connection.lease_expires_at <= stamp:
            _expire(db, practice, connection, stamp)
            db.commit()
            raise APIError(409, "connection_lease_expired", "连接租约已到期。")
        permit = admission.admit(auth.user_id)
        configuration = {
            name: getattr(permit, name) for name in ("provider", "region", "model", "config_id")
        }
        snapshot = practice.configuration
        preferences = snapshot.get("preferences") if type(snapshot) is dict else None
        difficulty = snapshot.get("effective_difficulty") if type(snapshot) is dict else None
        pace = preferences.get("speech_pace") if type(preferences) is dict else None
        if (
            configuration != connection.configuration
            or type(snapshot) is not dict
            or configuration != snapshot.get("provider")
            or type(difficulty) is not str
            or difficulty not in {"beginner", "intermediate", "advanced"}
            or type(pace) is not str
            or pace not in {"normal", "slow"}
        ):
            raise APIError(409, "practice_configuration_changed", "语音配置已更改。")
        if practice.kind == "ordinary":
            if (
                practice.source_session_id is not None
                or practice.source_kind is not None
                or practice.source_review_item_id is not None
                or practice.rehearsal_target is not None
                or practice.rehearsal_target_hash is not None
            ):
                raise APIError(409, "practice_configuration_changed", "语音配置已更改。")
            rehearsal = None
        elif practice.kind == "rehearsal":
            rehearsal = verified_rehearsal_prompt(practice, auth.user_id)
        else:
            raise APIError(409, "practice_configuration_changed", "语音配置已更改。")
        topic = practice_topic(practice)
        try:
            QwenSessionGate(difficulty, pace, rehearsal=rehearsal, topic=topic)
        except QwenSessionError:
            raise APIError(409, "practice_configuration_changed", "语音配置已更改。") from None
        # QwenWebSocketGateway.attempt performs local validation only; no network.
        provider_attempt = gateway.attempt(dict(configuration))
        latest_auth = lock_websocket_identity(db, identity)
        if latest_auth != auth:
            raise APIError(409, "account_changed", "账号身份已变化。")
        stamp = now()
        if connection.lease_expires_at <= stamp:
            _expire(db, practice, connection, stamp)
            db.commit()
            raise APIError(409, "connection_lease_expired", "连接租约已到期。")
        fingerprint = _fingerprint(
            auth.user_id, session_id, connection_id, client_instance_id, epoch
        )
        connection.offer_digest = fingerprint
        connection.signalling_started_at = stamp
        connection.status = "negotiating"
        connection.termination_status = "unknown"
        connection.state_reason = "websocket_started"
        result = WebSocketClaim(
            auth.user_id,
            auth.auth_id,
            session_id,
            connection_id,
            client_instance_id,
            epoch,
            fingerprint,
            difficulty,
            pace,
            MappingProxyType(configuration),
            provider_attempt,
            rehearsal=rehearsal,
            topic=topic,
        )
        db.commit()
        return result
