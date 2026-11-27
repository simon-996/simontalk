"""Disabled server-owned Qwen startup; no downstream endpoint or admission."""

import asyncio
from contextlib import asynccontextmanager
from uuid import UUID

from simontalk_api.connections import own_connection
from simontalk_api.errors import APIError
from simontalk_api.practice import own_preparation
from simontalk_api.practice_topics import PracticeTopic, practice_topic
from simontalk_api.qwen_websocket import _Attempt
from simontalk_api.qwen_websocket_session import QwenSessionGate, RehearsalPrompt
from simontalk_api.security import now
from simontalk_api.websocket_claim import WebSocketClaim, _fingerprint
from simontalk_api.websocket_handshake import HandshakeIdentity
from simontalk_api.websocket_identity import lock_websocket_identity
from simontalk_api.websocket_unknown import mark_websocket_unknown

_STARTUP_TIMEOUT = 20.0
_CLEANUP_WAIT = 7.0
_RECHECK_INTERVAL = 1.0
_RECHECK_TIMEOUT = 2.0
_MAX_ACTIVE = 128
_ACTIVE = set()
_CLEANUPS = set()


class QwenSupervisorError(Exception):
    """Fixed error without upstream events, credentials, or session IDs."""


def _revalidate(session_factory, identity, claim, admission, *, confirm, active=False):
    with session_factory() as db:
        auth = lock_websocket_identity(db, identity)
        if auth.user_id != claim.user_id or auth.auth_id != claim.auth_id:
            raise APIError(409, "account_changed", "账号身份已变化。")
        practice = own_preparation(db, auth.user_id, claim.session_id, lock=True)
        connection = own_connection(
            db, auth.user_id, claim.session_id, claim.connection_id, lock=True
        )
        snapshot = practice.configuration
        preferences = snapshot.get("preferences") if type(snapshot) is dict else None
        permit = admission.admit(auth.user_id)
        configuration = {
            name: getattr(permit, name) for name in ("provider", "region", "model", "config_id")
        }
        if (
            practice.status
            not in ({"connecting", "active", "ending"} if active else {"connecting"})
            or practice.connection_epoch != claim.epoch
            or connection.epoch != claim.epoch
            or connection.client_instance_id != claim.client_instance_id
            or connection.status not in ({"configuring", "ready"} if active else {"negotiating"})
            or connection.termination_status != "unknown"
            or connection.offer_digest != claim.fingerprint
            or connection.signalling_started_at is None
            or (connection.signalling_finished_at is None) == active
            or connection.lease_expires_at <= now()
            or configuration != dict(claim.configuration)
            or configuration != connection.configuration
            or type(snapshot) is not dict
            or snapshot.get("provider") != configuration
            or snapshot.get("effective_difficulty") != claim.difficulty
            or type(preferences) is not dict
            or preferences.get("speech_pace") != claim.speech_pace
            or practice.kind != ("rehearsal" if claim.rehearsal is not None else "ordinary")
            or practice.rehearsal_target_hash
            != (claim.rehearsal.target_hash if claim.rehearsal is not None else None)
            or practice_topic(practice) != claim.topic
        ):
            raise APIError(409, "connection_identity_changed", "连接身份或状态已变化。")
        # Recheck after all possibly blocking account, practice and connection locks.
        if lock_websocket_identity(db, identity) != auth or connection.lease_expires_at <= now():
            raise APIError(409, "connection_identity_changed", "连接身份或状态已变化。")
        if confirm:
            stamp = max(now(), connection.signalling_started_at)
            connection.status = "configuring"
            connection.state_reason = "websocket_configured"
            connection.signalling_finished_at = stamp
            db.commit()


async def _cleanup(session_factory, claim, connection, reason):
    tasks = [asyncio.to_thread(mark_websocket_unknown, session_factory, claim, reason)]
    if connection is not None:
        tasks.append(connection.close())
    await asyncio.gather(*tasks, return_exceptions=True)


@asynccontextmanager
async def supervise_websocket(
    session_factory, identity, claim, admission, *, on_owned=None, on_configured=None
):
    """Use a single durable attempt for bounded configuration and conservative exit.

    The yielded connection is server-internal; callers must not forward arbitrary
    downstream JSON. This is not a public route or proof of upstream termination.
    """
    if (
        type(identity) is not HandshakeIdentity
        or type(claim) is not WebSocketClaim
        or identity.account_id != claim.user_id
        or any(
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
        or type(claim.provider_attempt) is not _Attempt
        or (claim.rehearsal is not None and type(claim.rehearsal) is not RehearsalPrompt)
        or (claim.topic is not None and type(claim.topic) is not PracticeTopic)
        or (on_configured is not None and not callable(on_configured))
        or claim.fingerprint
        != _fingerprint(
            claim.user_id,
            claim.session_id,
            claim.connection_id,
            claim.client_instance_id,
            claim.epoch,
        )
    ):
        raise QwenSupervisorError("session_unavailable")
    if claim.fingerprint in _ACTIVE or len(_ACTIVE) >= _MAX_ACTIVE:
        raise QwenSupervisorError("session_unavailable")
    _ACTIVE.add(claim.fingerprint)
    connection = None
    reason = "network_failed"
    cleanup = None
    context_exited = False

    def begin_cleanup(cleanup_reason):
        nonlocal cleanup
        if cleanup is not None:
            return cleanup
        cleanup = asyncio.create_task(_cleanup(session_factory, claim, connection, cleanup_reason))
        _CLEANUPS.add(cleanup)

        def done(task):
            _CLEANUPS.discard(task)
            if context_exited:
                _ACTIVE.discard(claim.fingerprint)
            try:
                task.result()
            except BaseException:
                pass

        cleanup.add_done_callback(done)
        return cleanup

    async def watch_active():
        while True:
            await asyncio.sleep(_RECHECK_INTERVAL)
            try:
                async with asyncio.timeout(_RECHECK_TIMEOUT):
                    await asyncio.to_thread(
                        _revalidate,
                        session_factory,
                        identity,
                        claim,
                        admission,
                        confirm=False,
                        active=True,
                    )
            except asyncio.CancelledError:
                raise
            except Exception:
                begin_cleanup("auth_lost")
                return

    watcher = None
    try:
        if on_owned is not None:
            on_owned()
        try:
            async with asyncio.timeout(_STARTUP_TIMEOUT):
                await asyncio.to_thread(
                    _revalidate, session_factory, identity, claim, admission, confirm=False
                )
                connection = await claim.provider_attempt.open()
                reason = "config_failed"
                gate = QwenSessionGate(
                    claim.difficulty,
                    claim.speech_pace,
                    rehearsal=claim.rehearsal,
                    topic=claim.topic,
                )
                update = gate.accept_created(await connection.receive())
                await connection.send(update)
                gate.accept_updated(await connection.receive())
                await asyncio.to_thread(
                    _revalidate, session_factory, identity, claim, admission, confirm=True
                )
                if on_configured is not None:
                    on_configured(gate)
        except asyncio.CancelledError:
            reason = "cancelled"
            raise
        except Exception:
            raise QwenSupervisorError("session_unavailable") from None
        reason = "disconnected"
        watcher = asyncio.create_task(watch_active())
        try:
            yield connection
        except asyncio.CancelledError:
            reason = "cancelled"
            raise
    finally:
        if watcher is not None:
            watcher.cancel()
        context_exited = True
        cleanup = begin_cleanup(reason)
        if cleanup.done():
            _ACTIVE.discard(claim.fingerprint)
        # A blocked database must not keep the caller waiting forever. The
        # strongly referenced task and active slot remain until cleanup ends.
        await asyncio.wait({cleanup}, timeout=_CLEANUP_WAIT)
