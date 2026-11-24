"""Internal one-turn message pump; caller owns authentication and lifecycle."""

import asyncio
import json
import time

from simontalk_api.qwen_outbound_serializer import QwenSerializedSender
from simontalk_api.qwen_pcm_upstream import QwenPcmInput
from simontalk_api.qwen_websocket_turn_policy import QwenTurnPolicy
from simontalk_api.websocket_pcm_relay import WebSocketPcmRelay

_DELIVERY_TIMEOUT = 3.0
_ACTION_TIMEOUT = 4.0
_CLOSE_WAIT = 7.0
_MAX_PUMPS = 128
_MAX_DELIVERIES = 128
_PUMPS = set()
_DELIVERIES = set()


class QwenPumpError(Exception):
    """Fixed error without provider, transcript, or PCM contents."""


def _consume_delivery(task):
    _DELIVERIES.discard(task)
    try:
        task.result()
    except BaseException:
        pass


class QwenTurnPump:
    def __init__(self, connection, send_downstream, close_downstream, *, clock=time.monotonic):
        if (
            not callable(getattr(connection, "send", None))
            or not callable(getattr(connection, "receive", None))
            or not callable(getattr(connection, "close", None))
            or not callable(send_downstream)
            or not callable(close_downstream)
            or not callable(clock)
            or len(_PUMPS) >= _MAX_PUMPS
        ):
            raise QwenPumpError("pump_unavailable")
        self._connection = connection
        self._send_downstream = send_downstream
        self._close_downstream = close_downstream
        self._sender = QwenSerializedSender(connection)
        self._relay = WebSocketPcmRelay(QwenPcmInput(self._sender, clock=clock), clock=clock)
        self._policy = QwenTurnPolicy()
        self._closed = False
        self._reading = False
        self._reader = None
        self._close_task = None
        self._deliveries = set()
        _PUMPS.add(self)

    def _start_close(self):
        if self._close_task is None:
            self._closed = True
            if self._reader is not None and not self._reader.done():
                self._reader.cancel()
            self._close_task = asyncio.create_task(self._finish_close())
            self._close_task.add_done_callback(self._close_done)
        return self._close_task

    def _close_done(self, task):
        _PUMPS.discard(self)
        try:
            task.result()
        except BaseException:
            pass

    async def _finish_close(self):
        async def close_downstream():
            await self._close_downstream()

        await asyncio.gather(self._sender.close(), close_downstream(), return_exceptions=True)

    async def close(self):
        task = self._start_close()
        await asyncio.wait({task}, timeout=_CLOSE_WAIT)

    @property
    def stop_requested(self):
        return self._relay.stop_requested

    async def wait_for_quiescence(self):
        """Wait only after the caller has stopped all producers and begun close."""
        if self._close_task is not None:
            await asyncio.shield(self._close_task)
        while self._deliveries:
            await asyncio.wait(set(self._deliveries))

    async def _fail(self):
        await self.close()
        raise QwenPumpError("pump_unavailable") from None

    async def _deliver(self, payload):
        encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        if (
            len(encoded.encode("utf-8", errors="strict")) > 131072
            or len(_DELIVERIES) >= _MAX_DELIVERIES
        ):
            raise QwenPumpError("pump_unavailable")

        async def send():
            await self._send_downstream(encoded)

        task = asyncio.create_task(send())
        _DELIVERIES.add(task)
        self._deliveries.add(task)
        task.add_done_callback(_consume_delivery)
        task.add_done_callback(self._deliveries.discard)
        try:
            done, _ = await asyncio.wait({task}, timeout=_DELIVERY_TIMEOUT)
        except asyncio.CancelledError:
            task.cancel()
            raise
        if not done:
            task.cancel()
            raise QwenPumpError("pump_unavailable")
        task.result()

    async def _interrupt(self, response_id):
        notify = asyncio.create_task(
            self._deliver({"kind": "quarantine", "response_id": response_id})
        )
        cancel = asyncio.create_task(self._sender.send('{"type":"response.cancel"}'))
        tasks = {notify, cancel}
        try:
            done, pending = await asyncio.wait(
                tasks, timeout=_ACTION_TIMEOUT, return_when=asyncio.FIRST_EXCEPTION
            )
        except asyncio.CancelledError:
            for task in tasks:
                task.cancel()
                task.add_done_callback(_consume_delivery)
            raise
        for task in pending:
            task.cancel()
            task.add_done_callback(_consume_delivery)
        failed = False
        for task in done:
            if task.cancelled() or task.exception() is not None:
                failed = True
        if pending or failed:
            raise QwenPumpError("pump_unavailable")

    async def accept_client(self, value):
        if self._closed:
            raise QwenPumpError("pump_unavailable")
        try:
            result = await self._relay.accept(value)
            if result == "stopped":
                await self.close()
            return result
        except asyncio.CancelledError:
            self._start_close()
            raise
        except Exception:
            await self._fail()

    async def receive_one(self):
        if self._closed:
            raise QwenPumpError("pump_unavailable")
        if self._reading:
            await self._fail()
        self._reading = True
        try:
            self._reader = asyncio.create_task(self._connection.receive())
            raw = await self._reader
            self._reader = None
            decision = self._policy.accept(raw)
            if decision.quarantine:
                await self._interrupt(decision.quarantine_response)
            if decision.forward:
                event = decision.audio if decision.audio is not None else decision.event
                await self._deliver({"kind": "provider_event", "event": event})
            if decision.create_response:
                await self._sender.send('{"type":"response.create"}')
            if self._closed:
                raise QwenPumpError("pump_unavailable")
            return "forwarded" if decision.forward else "ignored"
        except asyncio.CancelledError:
            self._start_close()
            if asyncio.current_task().cancelling():
                raise
            raise QwenPumpError("pump_unavailable") from None
        except Exception:
            await self._fail()
        finally:
            self._reader = None
            self._reading = False
