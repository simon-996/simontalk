"""Offline downstream message gating; synthetic audio and no sockets."""

import asyncio
import json

import pytest
from test_websocket_pcm_wire import frame

from simontalk_api.qwen_pcm_upstream import QwenPcmInput
from simontalk_api.websocket_pcm_relay import PcmRelayError, WebSocketPcmRelay


class Connection:
    def __init__(self):
        self.sent = []
        self.closes = 0
        self.entered = asyncio.Event()
        self.release = asyncio.Event()
        self.block = False

    async def send(self, value):
        self.entered.set()
        if self.block:
            await self.release.wait()
        self.sent.append(json.loads(value))

    async def close(self):
        self.closes += 1
        self.release.set()


def make(clock=lambda: 0.0):
    connection = Connection()
    return connection, WebSocketPcmRelay(QwenPcmInput(connection, clock=clock), clock=clock)


def mode(epoch, muted):
    return json.dumps({"kind": "mode", "epoch": epoch, "muted": muted})


def test_controls_and_pcm_allow_only_current_unmuted_generation():
    async def run():
        connection, relay = make()
        assert await relay.accept(frame(0, 1)) == "dropped"
        assert await relay.accept(mode(1, False)) == "mode"
        assert await relay.accept(frame(1, 2)) == "forwarded"
        assert await relay.accept(mode(2, True)) == "mode"
        assert await relay.accept(frame(1, 3)) == "dropped"
        assert await relay.accept(mode(3, False)) == "mode"
        assert await relay.accept(frame(3, 4)) == "forwarded"
        assert [e["type"] for e in connection.sent] == ["input_audio_buffer.append"] * 2
        assert await relay.accept('{"kind":"pace","pace":"slow"}') == ("pace", "slow")
        assert await relay.accept('{"kind":"interrupt"}') == "interrupt"
        assert await relay.accept('{"kind":"settled","response_id":"resp_1"}') == (
            "settled",
            "resp_1",
        )
        assert await relay.accept('{"kind":"stop"}') == "stopped"
        assert connection.closes == 1
        with pytest.raises(PcmRelayError):
            await relay.accept(frame(3, 5))

    asyncio.run(run())


@pytest.mark.parametrize(
    "message",
    [
        "{}",
        '{"kind":"drain","extra":"secret"}',
        '{"kind":"mode","kind":"mode","epoch":1,"muted":false}',
        '{"kind":"mode","epoch":2,"muted":false}',
        '{"kind":"mode","epoch":1,"muted":0}',
        '{"kind":"mode","epoch":1,"muted":false,"provider":"secret"}',
        '{"kind":"response.create"}',
        '{"kind":"settled"}',
        '{"kind":"settled","response_id":""}',
        '{"kind":"settled","response_id":"bad id"}',
        '{"kind":"settled","response_id":"r","extra":1}',
        '{"kind":"pace"}',
        '{"kind":"pace","pace":"normal"}',
        '{"kind":"pace","pace":"slow","extra":1}',
        '{"kind":"interrupt"}',
        '{"kind":"interrupt","extra":1}',
        '{"kind":"stop","extra":"secret"}',
        "x" * 1025,
        "\ud800",
        bytearray(3213),
        bytes(3212),
    ],
)
def test_invalid_controls_and_frames_fail_closed(message):
    async def run():
        connection, relay = make()
        with pytest.raises(PcmRelayError) as caught:
            await relay.accept(message)
        assert "secret" not in str(caught.value)
        assert connection.sent == [] and connection.closes == 1
        with pytest.raises(PcmRelayError):
            await relay.accept(mode(1, False))

    asyncio.run(run())


@pytest.mark.parametrize(
    "late",
    [
        frame(1, 2),
        mode(2, True),
        '{"kind":"drain"}',
        '{"kind":"pace","pace":"slow"}',
        '{"kind":"interrupt"}',
        '{"kind":"settled","response_id":"r"}',
    ],
)
def test_drain_rejects_further_audio_and_controls_other_than_stop(late):
    async def run():
        connection, relay = make()
        assert await relay.accept(mode(1, False)) == "mode"
        assert await relay.accept('{"kind":"drain"}') == "draining"
        with pytest.raises(PcmRelayError):
            await relay.accept(late)
        assert connection.sent == [] and connection.closes == 1

    asyncio.run(run())


def test_all_stale_or_muted_frames_are_also_rate_limited():
    async def run():
        connection, relay = make()
        for seq in range(1, 7):
            assert await relay.accept(frame(0, seq)) == "dropped"
        with pytest.raises(PcmRelayError):
            await relay.accept(frame(0, 7))
        assert connection.closes == 1 and not connection.sent

    asyncio.run(run())


def test_duplicate_sequence_and_future_epoch_close():
    async def run():
        connection, relay = make()
        await relay.accept(mode(1, False))
        await relay.accept(frame(1, 1))
        with pytest.raises(PcmRelayError):
            await relay.accept(frame(1, 1))
        assert connection.closes == 1
        c2, r2 = make()
        await r2.accept(mode(1, False))
        with pytest.raises(PcmRelayError):
            await r2.accept(frame(2, 1))
        assert c2.closes == 1

    asyncio.run(run())


def test_concurrent_and_cancelled_processing_close_once():
    async def run():
        connection, relay = make()
        connection.block = True
        await relay.accept(mode(1, False))
        first = asyncio.create_task(relay.accept(frame(1, 1)))
        await connection.entered.wait()
        with pytest.raises(PcmRelayError):
            await relay.accept(mode(2, True))
        with pytest.raises(PcmRelayError):
            await first
        assert connection.closes == 1
        c2, r2 = make()
        c2.block = True
        await r2.accept(mode(1, False))
        task = asyncio.create_task(r2.accept(frame(1, 1)))
        await c2.entered.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        await r2.close()
        assert c2.closes == 1

    asyncio.run(run())


def test_limits_include_dropped_frames_and_control_messages(monkeypatch):
    import simontalk_api.websocket_pcm_relay as module

    monkeypatch.setattr(module, "_MAX_FRAMES", 1)
    monkeypatch.setattr(module, "_MAX_CONTROLS", 1)

    async def run():
        c, relay = make()
        assert await relay.accept(frame(0, 1)) == "dropped"
        with pytest.raises(PcmRelayError):
            await relay.accept(frame(0, 2))
        assert c.closes == 1
        c2, relay2 = make()
        await relay2.accept(mode(1, False))
        with pytest.raises(PcmRelayError):
            await relay2.accept(mode(2, True))
        assert c2.closes == 1

    asyncio.run(run())


def test_close_during_async_mode_change_never_reopens_delivery():
    class SlowAdapter:
        def __init__(self):
            self.entered, self.release = asyncio.Event(), asyncio.Event()
            self.closes = 0

        async def set_muted(self, muted, epoch):
            self.entered.set()
            await self.release.wait()

        async def append(self, *args):
            raise AssertionError("must not send")

        async def close(self):
            self.closes += 1
            self.release.set()

    async def run():
        adapter = SlowAdapter()
        relay = WebSocketPcmRelay(adapter, clock=lambda: 0.0)
        task = asyncio.create_task(relay.accept(mode(1, False)))
        await adapter.entered.wait()
        await relay.close()
        with pytest.raises(PcmRelayError):
            await task
        assert adapter.closes == 1
        with pytest.raises(PcmRelayError):
            await relay.accept(frame(1, 1))

    asyncio.run(run())


def test_duplicate_pace_control_fails_closed():
    async def run():
        connection, relay = make()
        assert await relay.accept('{"kind":"pace","pace":"slow"}') == ("pace", "slow")
        with pytest.raises(PcmRelayError):
            await relay.accept('{"kind":"pace","pace":"slow"}')
        assert connection.closes == 1

        c2, r2 = make()
        await r2.accept(mode(1, False))
        assert await r2.accept('{"kind":"interrupt"}') == "interrupt"
        with pytest.raises(PcmRelayError):
            await r2.accept('{"kind":"interrupt"}')
        assert c2.closes == 1

    asyncio.run(run())
