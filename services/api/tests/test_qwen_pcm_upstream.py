"""Offline tests for an unregistered PCM adapter; no provider calls."""

import asyncio
import base64
import json

import pytest

from simontalk_api.qwen_pcm_upstream import PcmInputError, QwenPcmInput


class Connection:
    def __init__(self):
        self.messages = []
        self.closes = 0
        self.entered = asyncio.Event()
        self.release = asyncio.Event()
        self.block = False
        self.error = False

    async def send(self, message):
        self.entered.set()
        if self.block:
            await self.release.wait()
        if self.error:
            raise RuntimeError("synthetic secret audio")
        self.messages.append(json.loads(message))

    async def close(self):
        self.closes += 1
        self.release.set()


def test_pcm_encoded_and_disabled_until_explicit_unmute():
    async def run():
        c = Connection()
        a = QwenPcmInput(c, clock=lambda: 10.0)
        frame = bytes(range(256)) * 12 + bytes(128)
        assert not await a.append(0, 1, frame)
        await a.set_muted(False, 1)
        assert await a.append(1, 2, frame)
        assert c.messages[0]["type"] == "input_audio_buffer.append"
        assert base64.b64decode(c.messages[0]["audio"], validate=True) == frame
        assert c.messages[0]["event_id"] == "event_audio_1"
        await a.set_muted(True, 2)
        assert not await a.append(1, 3, frame)
        await a.set_muted(False, 3)
        assert not await a.append(1, 4, frame)
        assert await a.append(3, 5, frame)
        await a.close()
        assert c.closes == 1

    asyncio.run(run())


@pytest.mark.parametrize("kind", ["future_epoch", "bad_sequence", "bad_size", "bad_control"])
def test_invalid_input_is_sanitized_and_closes(kind):
    async def run():
        c = Connection()
        a = QwenPcmInput(c, clock=lambda: 0.0)
        await a.set_muted(False, 1)
        with pytest.raises(PcmInputError) as exc:
            if kind == "future_epoch":
                await a.append(2, 1, bytes(3200))
            elif kind == "bad_sequence":
                await a.append(1, 0, bytes(3200))
            elif kind == "bad_size":
                await a.append(1, 1, b"secret")
            else:
                await a.set_muted(True, 3)
        assert "secret" not in str(exc.value)
        assert c.closes == 1 and c.messages == []
        with pytest.raises(PcmInputError):
            await a.append(1, 2, bytes(3200))

    asyncio.run(run())


def test_replay_and_rate_limit_fail_closed():
    async def run():
        c = Connection()
        a = QwenPcmInput(c, clock=lambda: 0.0)
        await a.set_muted(False, 1)
        for seq in range(1, 7):
            assert await a.append(1, seq, bytes(3200))
        with pytest.raises(PcmInputError):
            await a.append(1, 7, bytes(3200))
        assert c.closes == 1 and len(c.messages) == 6
        c2 = Connection()
        a2 = QwenPcmInput(c2, clock=lambda: 0.0)
        await a2.set_muted(False, 1)
        await a2.append(1, 1, bytes(3200))
        with pytest.raises(PcmInputError):
            await a2.append(1, 1, bytes(3200))
        assert c2.closes == 1 and len(c2.messages) == 1

    asyncio.run(run())


def test_time_refill_backwards_clock_and_send_error():
    async def run():
        c = Connection()
        now = [10.0]
        a = QwenPcmInput(c, clock=lambda: now[0])
        await a.set_muted(False, 1)
        for seq in range(1, 7):
            await a.append(1, seq, bytes(3200))
        now[0] += 0.1
        assert await a.append(1, 7, bytes(3200))
        now[0] = 9
        with pytest.raises(PcmInputError):
            await a.append(1, 8, bytes(3200))
        assert c.closes == 1
        c2 = Connection()
        c2.error = True
        a2 = QwenPcmInput(c2, clock=lambda: 0.0)
        await a2.set_muted(False, 1)
        with pytest.raises(PcmInputError) as exc:
            await a2.append(1, 1, bytes(3200))
        assert "secret" not in str(exc.value) and c2.closes == 1

    asyncio.run(run())


def test_concurrent_send_and_cancellation_close_once():
    async def run():
        c = Connection()
        c.block = True
        a = QwenPcmInput(c, clock=lambda: 0.0)
        await a.set_muted(False, 1)
        first = asyncio.create_task(a.append(1, 1, bytes(3200)))
        await c.entered.wait()
        with pytest.raises(PcmInputError):
            await a.append(1, 2, bytes(3200))
        with pytest.raises(PcmInputError):
            await first
        assert c.closes == 1
        c2 = Connection()
        c2.block = True
        a2 = QwenPcmInput(c2, clock=lambda: 0.0)
        await a2.set_muted(False, 1)
        task = asyncio.create_task(a2.append(1, 1, bytes(3200)))
        await c2.entered.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        await a2.close()
        assert c2.closes == 1

    asyncio.run(run())


def test_muting_during_inflight_send_gates_future_audio():
    async def run():
        c = Connection()
        c.block = True
        a = QwenPcmInput(c, clock=lambda: 0.0)
        await a.set_muted(False, 1)
        first = asyncio.create_task(a.append(1, 1, bytes(3200)))
        await c.entered.wait()
        await a.set_muted(True, 2)
        assert not await a.append(1, 2, bytes(3200))
        c.release.set()
        assert not await first  # already started: delivery cannot be undone
        assert len(c.messages) == 1
        await a.set_muted(False, 3)
        assert await a.append(3, 3, bytes(3200))
        await a.close()

    asyncio.run(run())


def test_actual_gateway_connection_receives_only_generated_json():
    from simontalk_api.qwen_websocket import _Connection

    class Socket:
        def __init__(self):
            self.messages = []
            self.closed = 0

        async def send(self, message):
            self.messages.append(message)

        async def close(self, code):
            assert code == 1000
            self.closed += 1

    async def run():
        socket = Socket()
        a = QwenPcmInput(_Connection(socket), clock=lambda: 0.0)
        await a.set_muted(False, 1)
        assert await a.append(1, 1, bytes(3200))
        message = json.loads(socket.messages[0])
        assert set(message) == {"type", "event_id", "audio"}
        assert len(base64.b64decode(message["audio"])) == 3200
        await a.close()
        assert socket.closed == 1

    asyncio.run(run())


@pytest.mark.parametrize("value", [float("nan"), float("inf"), True, "now"])
def test_invalid_clock_closes_without_sending(value):
    async def run():
        c = Connection()
        a = QwenPcmInput(c, clock=lambda: value)
        await a.set_muted(False, 1)
        with pytest.raises(PcmInputError):
            await a.append(1, 1, bytes(3200))
        assert c.closes == 1 and not c.messages

    asyncio.run(run())


def test_total_limit_prevents_unbounded_connection(monkeypatch):
    import simontalk_api.qwen_pcm_upstream as module

    monkeypatch.setattr(module, "_MAX_FRAMES", 2)

    async def run():
        c = Connection()
        a = QwenPcmInput(c, clock=lambda: 0.0)
        await a.set_muted(False, 1)
        await a.append(1, 1, bytes(3200))
        await a.append(1, 2, bytes(3200))
        with pytest.raises(PcmInputError):
            await a.append(1, 3, bytes(3200))
        assert len(c.messages) == 2 and c.closes == 1

    asyncio.run(run())
