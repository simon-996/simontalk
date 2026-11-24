"""Internal supervised one-turn session; no WebSocket route or admission."""

import asyncio

from simontalk_api.qwen_turn_pump import QwenTurnPump
from simontalk_api.websocket_supervisor import supervise_websocket

_MAX_SESSIONS = 128
_MAX_REJECT_CLOSES = 128
_CLEANUP_WAIT = 7.0
_SESSIONS = set()
_REJECT_CLOSES = set()
_OWNED_DOWNSTREAMS = set()


class SessionError(Exception):
    """Fixed diagnostic with no user data, upstream events, or credentials."""


def _consume(task):
    try:
        task.result()
    except BaseException:
        pass


async def _reject(downstream):
    # If all reject-close slots are occupied, the caller retains ownership.
    if callable(getattr(downstream, "close", None)) and len(_REJECT_CLOSES) < _MAX_REJECT_CLOSES:

        async def close():
            await downstream.close()

        task = asyncio.create_task(close())
        _REJECT_CLOSES.add(task)

        def done(result):
            _REJECT_CLOSES.discard(result)
            _OWNED_DOWNSTREAMS.discard(id(downstream))
            _consume(result)

        task.add_done_callback(done)
        await asyncio.wait({task}, timeout=_CLEANUP_WAIT)
    else:
        _OWNED_DOWNSTREAMS.discard(id(downstream))


async def run_pump_session(
    session_factory, identity, claim, admission, downstream, *, on_owned=None, on_ready=None
):
    """Run one already-claimed session over a dedicated, non-reusable downstream.

    The caller still owns browser authentication and the socket if capacity is
    exhausted and a reject-close cannot be started. No remote exit is established.
    """
    downstream_id = id(downstream)
    if downstream_id in _OWNED_DOWNSTREAMS:
        raise SessionError("session_unavailable")
    _OWNED_DOWNSTREAMS.add(downstream_id)
    if len(_SESSIONS) >= _MAX_SESSIONS or not all(
        callable(getattr(downstream, name, None)) for name in ("receive", "send", "close")
    ):
        await _reject(downstream)
        raise SessionError("session_unavailable")

    slot = object()
    _SESSIONS.add(slot)
    pending = set()
    finished = False
    close_task = None
    pump = None

    def track(task):
        pending.add(task)

        def done(result):
            pending.discard(result)
            _consume(result)
            if finished and not pending:
                _SESSIONS.discard(slot)
                _OWNED_DOWNSTREAMS.discard(downstream_id)

        task.add_done_callback(done)
        return task

    def start_close():
        nonlocal close_task
        if close_task is None:

            async def close():
                await downstream.close()

            close_task = track(asyncio.create_task(close()))
        return close_task

    async def close_downstream():
        await asyncio.shield(start_close())

    async def read_client():
        while True:
            value = await downstream.receive()
            if await pump.accept_client(value) == "stopped":
                return "stopped"

    async def read_provider():
        while True:
            await pump.receive_one()

    try:
        try:
            async with supervise_websocket(
                session_factory, identity, claim, admission, on_owned=on_owned
            ) as connection:
                pump = QwenTurnPump(connection, downstream.send, close_downstream)
                if on_ready is not None:
                    try:
                        await on_ready()
                    except BaseException:
                        await pump.close()
                        raise
                client = track(asyncio.create_task(read_client()))
                provider = track(asyncio.create_task(read_provider()))
                try:
                    done, _ = await asyncio.wait(
                        {client, provider}, return_when=asyncio.FIRST_COMPLETED
                    )
                    # A validated stop closes upstream before the client loop
                    # necessarily returns; give that close a bounded chance to finish.
                    if provider in done and client not in done and pump.stop_requested:
                        await asyncio.wait({client}, timeout=_CLEANUP_WAIT)
                        if client.done():
                            done.add(client)
                    if pump.stop_requested and client in done and not client.cancelled():
                        if client.exception() is None and client.result() == "stopped":
                            return "stopped"
                    for task in done:
                        if task.cancelled() or task.exception() is not None:
                            raise SessionError("session_unavailable")
                    raise SessionError("session_unavailable")
                finally:
                    for task in (client, provider):
                        if not task.done():
                            task.cancel()
                    pump._start_close()

                    async def wait_for_idle():
                        await asyncio.gather(client, provider, return_exceptions=True)
                        await pump.wait_for_quiescence()

                    track(asyncio.create_task(wait_for_idle()))
                    await pump.close()
        except asyncio.CancelledError:
            raise
        except Exception:
            raise SessionError("session_unavailable") from None
    finally:
        closing = start_close()
        finished = True
        await asyncio.wait({closing}, timeout=_CLEANUP_WAIT)
        if pending:
            await asyncio.wait(set(pending), timeout=_CLEANUP_WAIT)
        if not pending:
            _SESSIONS.discard(slot)
            _OWNED_DOWNSTREAMS.discard(downstream_id)
