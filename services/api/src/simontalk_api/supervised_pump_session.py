"""Internal supervised media session; no WebSocket route or admission."""

import asyncio
import logging
from concurrent.futures import ThreadPoolExecutor

from simontalk_api.qwen_turn_pump import QwenTurnPump
from simontalk_api.voice_response_usage import record_response_usage
from simontalk_api.websocket_supervisor import supervise_websocket

_MAX_SESSIONS = 128
_MAX_REJECT_CLOSES = 128
_CLEANUP_WAIT = 7.0
_DRAIN_TIMEOUT = 5.0
_MAX_USAGE_OBSERVATIONS = 64
_USAGE_WRITERS = ThreadPoolExecutor(max_workers=2, thread_name_prefix="voice-usage")
_SESSIONS = set()
_REJECT_CLOSES = set()
_OWNED_DOWNSTREAMS = set()
_LOG = logging.getLogger(__name__)


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
    session_gate = None
    usage_writer = None
    usage_queue = (
        asyncio.Queue(maxsize=_MAX_USAGE_OBSERVATIONS + 1) if session_factory is not None else None
    )

    def enqueue_usage(measurement):
        if usage_queue.qsize() >= _MAX_USAGE_OBSERVATIONS:
            _LOG.warning("voice_usage_queue_full")
            return
        usage_queue.put_nowait(measurement)

    async def write_usage():
        loop = asyncio.get_running_loop()
        while (measurement := await usage_queue.get()) is not None:
            try:
                await loop.run_in_executor(
                    _USAGE_WRITERS, record_response_usage, session_factory, claim, measurement
                )
            except Exception:
                _LOG.warning("voice_usage_write_failed")

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
        loop = asyncio.get_running_loop()
        deadline = None
        while True:
            async with asyncio.timeout_at(deadline):
                value = await downstream.receive()
            received_at = loop.time()
            if deadline is not None and received_at >= deadline:
                raise SessionError("session_unavailable")
            result = await pump.accept_client(value)
            if result == "stopped":
                return "stopped"
            if result == "draining":
                deadline = received_at + _DRAIN_TIMEOUT

    async def read_provider():
        while True:
            await pump.receive_one()

    def capture_gate(gate):
        nonlocal session_gate
        session_gate = gate

    try:
        try:
            async with supervise_websocket(
                session_factory,
                identity,
                claim,
                admission,
                on_owned=on_owned,
                on_configured=capture_gate,
            ) as connection:
                pump = QwenTurnPump(
                    connection,
                    downstream.send,
                    close_downstream,
                    on_response_usage=enqueue_usage if usage_queue is not None else None,
                    session_gate=session_gate,
                )
                if on_ready is not None:
                    try:
                        await on_ready()
                    except BaseException:
                        await pump.close()
                        raise
                if usage_queue is not None:
                    usage_writer = track(asyncio.create_task(write_usage()))
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
                        if usage_queue is not None:
                            usage_queue.put_nowait(None)
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
        foreground = pending - {usage_writer}
        if foreground:
            await asyncio.wait(foreground, timeout=_CLEANUP_WAIT)
        if not pending:
            _SESSIONS.discard(slot)
            _OWNED_DOWNSTREAMS.discard(downstream_id)
