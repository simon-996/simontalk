"""Strict browser precheck plus one durable claim; no network or route."""

import asyncio

from simontalk_api.websocket_claim import claim_websocket
from simontalk_api.websocket_handshake import validate_handshake
from simontalk_api.websocket_unknown import mark_websocket_unknown

_CLAIM_TIMEOUT = 8.0
_MAX_CLAIMS = 128
_CLAIMS = set()
_WORKERS = set()
_FINALIZERS = set()


class ClaimError(Exception):
    """Fixed diagnostic without credentials, account IDs, or request content."""


async def authenticate_and_claim(
    *,
    session_factory,
    admission,
    gateway,
    headers,
    query,
    body,
    allowed_origins,
    session_id,
    connection_id,
    client_instance_id,
    epoch,
):
    """Return the checked identity and claim; cancellation never opens upstream.

    Callers own socket disconnect monitoring and must finalize a returned claim
    if they cannot start the supervisor. A timed-out database thread may commit;
    its eventual claim is finalized conservatively before its slot is released.
    """
    try:
        identity = validate_handshake(headers, query, body, allowed_origins)
    except Exception:
        raise ClaimError("claim_unavailable") from None
    if len(_CLAIMS) >= _MAX_CLAIMS:
        raise ClaimError("claim_unavailable")
    slot = object()
    _CLAIMS.add(slot)

    async def make_claim():
        return await asyncio.to_thread(
            claim_websocket,
            session_factory,
            identity,
            admission,
            gateway,
            session_id=session_id,
            connection_id=connection_id,
            client_instance_id=client_instance_id,
            epoch=epoch,
        )

    task = asyncio.create_task(make_claim())
    _WORKERS.add(task)
    task.add_done_callback(_WORKERS.discard)
    transferred = False
    reason = "network_failed"

    def retire(completed):
        try:
            claim = completed.result()
        except BaseException:
            _CLAIMS.discard(slot)
            return

        async def finalize():
            try:
                await asyncio.to_thread(mark_websocket_unknown, session_factory, claim, reason)
            except Exception:
                # The durable claim remains unknown and reserved for maintenance.
                pass
            finally:
                _CLAIMS.discard(slot)

        finalizer = asyncio.create_task(finalize())
        _FINALIZERS.add(finalizer)
        finalizer.add_done_callback(_FINALIZERS.discard)

    try:
        done, _ = await asyncio.wait({task}, timeout=_CLAIM_TIMEOUT)
        if not done:
            raise ClaimError("claim_unavailable")
        try:
            claim = task.result()
        except Exception:
            raise ClaimError("claim_unavailable") from None
        transferred = True
        _CLAIMS.discard(slot)
        return identity, claim
    except asyncio.CancelledError:
        reason = "cancelled"
        raise
    finally:
        if not transferred:
            task.add_done_callback(retire)
