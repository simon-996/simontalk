"""Unregistered PCM input adapter; caller owns authentication and session lifecycle."""

import asyncio
import base64
import json
import math
import time

_MAX_SAFE_INTEGER = 9007199254740991
_FRAME_BYTES = 3200
_MAX_FRAMES = 36000
_BURST = 6.0
_RATE = 10.0


class PcmInputError(Exception):
    """Fixed diagnostic without audio, upstream messages or credentials."""


class QwenPcmInput:
    """Translate already authorized PCM frames; never creates a connection or route."""

    def __init__(self, connection, *, clock=time.monotonic):
        if (
            not callable(getattr(connection, "send", None))
            or not callable(getattr(connection, "close", None))
            or not callable(clock)
        ):
            raise ValueError("Invalid PCM input configuration")
        self._connection = connection
        self._clock = clock
        self._closed = False
        self._muted = True
        self._epoch = 0
        self._last_sequence = 0
        self._sent = 0
        self._tokens = _BURST
        self._last_time = None
        self._sending = False
        self._close_task = None

    def _start_close(self):
        if self._close_task is None:
            self._closed = True
            self._close_task = asyncio.create_task(self._finish_close())
        return self._close_task

    async def _finish_close(self):
        try:
            await self._connection.close()
        except Exception:
            pass

    async def close(self):
        await asyncio.shield(self._start_close())

    async def _fail(self):
        await self.close()
        raise PcmInputError("pcm_input_closed") from None

    async def set_muted(self, muted, epoch):
        if self._closed:
            raise PcmInputError("pcm_input_closed")
        if (
            type(muted) is not bool
            or muted == self._muted
            or type(epoch) is not int
            or epoch != self._epoch + 1
            or epoch > _MAX_SAFE_INTEGER
        ):
            await self._fail()
        self._muted = muted
        self._epoch = epoch

    async def append(self, epoch, sequence, pcm):
        if self._closed:
            raise PcmInputError("pcm_input_closed")
        if (
            type(epoch) is not int
            or epoch < 0
            or epoch > self._epoch
            or type(sequence) is not int
            or not 0 < sequence <= _MAX_SAFE_INTEGER
        ):
            await self._fail()
        if epoch < self._epoch or self._muted:
            return False
        if (
            self._sending
            or sequence <= self._last_sequence
            or type(pcm) is not bytes
            or len(pcm) != _FRAME_BYTES
            or self._sent >= _MAX_FRAMES
        ):
            await self._fail()
        try:
            current = self._clock()
            if type(current) not in (int, float) or not math.isfinite(current):
                raise ValueError("invalid clock")
            if self._last_time is not None:
                if current < self._last_time:
                    raise ValueError("invalid clock")
                self._tokens = min(_BURST, self._tokens + (current - self._last_time) * _RATE)
            self._last_time = current
        except Exception:
            await self._fail()
        if self._tokens + 1e-9 < 1:
            await self._fail()
        self._tokens = max(0.0, self._tokens - 1)
        self._sent += 1
        self._last_sequence = sequence
        message = json.dumps(
            {
                "event_id": f"event_audio_{self._sent}",
                "type": "input_audio_buffer.append",
                "audio": base64.b64encode(pcm).decode("ascii"),
            },
            separators=(",", ":"),
        )
        self._sending = True
        try:
            await self._connection.send(message)
        except asyncio.CancelledError:
            self._start_close()
            raise
        except Exception:
            await self._fail()
        finally:
            self._sending = False
        if self._closed:
            raise PcmInputError("pcm_input_closed")
        return epoch == self._epoch and not self._muted
