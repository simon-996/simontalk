"""Strict, bounded downstream PCM message handling; not a WebSocket route."""

import asyncio
import json
import math
import time

from simontalk_api.qwen_websocket import _invalid_constant, _unique_pairs
from simontalk_api.websocket_pcm_wire import decode_pcm_frame

_MAX_EPOCH = 0xFFFFFFFF
_MAX_FRAMES = 36000
_MAX_CONTROLS = 256


class PcmRelayError(Exception):
    """Fixed error without audio or control contents."""


class WebSocketPcmRelay:
    def __init__(self, adapter, *, clock=time.monotonic):
        if (
            not callable(getattr(adapter, "append", None))
            or not callable(getattr(adapter, "set_muted", None))
            or not callable(getattr(adapter, "close", None))
            or not callable(clock)
        ):
            raise ValueError("Invalid PCM relay configuration")
        self._adapter = adapter
        self._clock = clock
        self._closed = False
        self._stop_requested = False
        self._busy = False
        self._epoch = 0
        self._muted = True
        self._frames = 0
        self._controls = 0
        self._tokens = {"frame": 6.0, "control": 8.0}
        self._last_time = {"frame": None, "control": None}
        self._close_task = None

    def _start_close(self):
        if self._close_task is None:
            self._closed = True
            self._close_task = asyncio.create_task(self._finish_close())
        return self._close_task

    async def _finish_close(self):
        try:
            await self._adapter.close()
        except Exception:
            pass

    async def close(self):
        await asyncio.shield(self._start_close())

    @property
    def stop_requested(self):
        return self._stop_requested

    async def _fail(self):
        await self.close()
        raise PcmRelayError("pcm_relay_closed") from None

    def _take(self, kind):
        stamp = self._clock()
        if type(stamp) not in (int, float) or not math.isfinite(stamp):
            raise ValueError("invalid clock")
        previous = self._last_time[kind]
        if previous is not None and stamp < previous:
            raise ValueError("invalid clock")
        capacity, rate = (6.0, 10.0) if kind == "frame" else (8.0, 4.0)
        if previous is not None:
            self._tokens[kind] = min(capacity, self._tokens[kind] + (stamp - previous) * rate)
        self._last_time[kind] = stamp
        if self._tokens[kind] + 1e-9 < 1:
            raise ValueError("rate exceeded")
        self._tokens[kind] = max(0.0, self._tokens[kind] - 1)

    async def _control(self, value):
        if len(value) > 1024 or len(value.encode("utf-8")) > 1024:
            raise ValueError("invalid control")
        self._controls += 1
        if self._controls > _MAX_CONTROLS:
            raise ValueError("control limit")
        self._take("control")
        data = json.loads(value, object_pairs_hook=_unique_pairs, parse_constant=_invalid_constant)
        if type(data) is not dict:
            raise ValueError("invalid control")
        if data == {"kind": "stop"}:
            self._stop_requested = True
            await self.close()
            return "stopped"
        if set(data) != {"kind", "epoch", "muted"} or data["kind"] != "mode":
            raise ValueError("invalid control")
        epoch, muted = data["epoch"], data["muted"]
        if (
            type(epoch) is not int
            or epoch != self._epoch + 1
            or epoch > _MAX_EPOCH
            or type(muted) is not bool
            or muted == self._muted
        ):
            raise ValueError("invalid mode")
        await self._adapter.set_muted(muted, epoch)
        if self._closed:
            raise ValueError("closed during mode change")
        self._epoch, self._muted = epoch, muted
        return "mode"

    async def accept(self, value):
        if self._closed:
            raise PcmRelayError("pcm_relay_closed")
        if self._busy:
            await self._fail()
        self._busy = True
        try:
            if type(value) is str:
                return await self._control(value)
            if type(value) is not bytes:
                raise ValueError("invalid message")
            self._frames += 1
            if self._frames > _MAX_FRAMES:
                raise ValueError("frame limit")
            self._take("frame")
            frame = decode_pcm_frame(value)
            sent = await self._adapter.append(frame.epoch, frame.sequence, frame.pcm)
            if self._closed:
                raise ValueError("closed during send")
            return "forwarded" if sent else "dropped"
        except asyncio.CancelledError:
            self._start_close()
            raise
        except Exception:
            await self._fail()
        finally:
            self._busy = False
