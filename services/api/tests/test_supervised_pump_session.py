"""Lifecycle composition using a real supervisor and synthetic sockets."""

import asyncio
import json

import pytest
from test_qwen_turn_pump import msg
from test_qwen_turn_pump_supervisor import PumpSocket, scope
from test_websocket_pcm_wire import frame

from simontalk_api.supervised_pump_session import SessionError, run_pump_session


class Downstream:
    def __init__(self):
        self.incoming = asyncio.Queue()
        self.output = asyncio.Queue()
        self.closed = 0

    async def receive(self):
        value = await self.incoming.get()
        if isinstance(value, Exception):
            raise value
        return value

    async def send(self, value):
        await self.output.put(json.loads(value))

    async def close(self):
        self.closed += 1


@pytest.fixture
def supervisor_stubs(monkeypatch):
    from simontalk_api import websocket_supervisor as supervisor

    finalized = []
    monkeypatch.setattr(supervisor, "_revalidate", lambda *args, **kwargs: None)
    monkeypatch.setattr(
        supervisor, "mark_websocket_unknown", lambda *args: finalized.append(args[2])
    )
    return finalized


async def start(socket, downstream):
    identity, claim = scope(socket)
    return asyncio.create_task(run_pump_session(None, identity, claim, None, downstream))


def test_stop_closes_both_sides_after_pcm_and_provider_event(supervisor_stubs):
    async def run():
        socket, down = PumpSocket(), Downstream()
        task = await start(socket, down)
        await down.incoming.put('{"kind":"mode","epoch":1,"muted":false}')
        await down.incoming.put(frame(1, 1))
        await socket.incoming.put(msg("input_audio_buffer.speech_started", "e1", item_id="user"))
        event = await asyncio.wait_for(down.output.get(), 1)
        assert event["event"]["item_id"] == "user"
        for _ in range(100):
            if any(event["type"] == "input_audio_buffer.append" for event in socket.sent):
                break
            await asyncio.sleep(0.001)
        else:
            pytest.fail("PCM not sent")
        await down.incoming.put('{"kind":"stop"}')
        assert await asyncio.wait_for(task, 1) == "stopped"
        assert socket.close_calls == down.closed == 1
        assert supervisor_stubs == ["disconnected"]

    asyncio.run(run())


def test_end_cannot_keep_the_session_open_without_a_stop(supervisor_stubs, monkeypatch):
    from simontalk_api import supervised_pump_session as module

    monkeypatch.setattr(module, "_DRAIN_TIMEOUT", 0.02, raising=False)

    async def run():
        socket, down = PumpSocket(), Downstream()
        task = await start(socket, down)
        await down.incoming.put('{"kind":"drain"}')
        with pytest.raises(SessionError):
            await asyncio.wait_for(task, 0.5)
        assert socket.close_calls == down.closed == 1
        assert supervisor_stubs == ["disconnected"]
        assert [event["type"] for event in socket.sent] == ["session.update"]

    asyncio.run(run())


def test_invalid_client_payload_closes_both_sides_with_fixed_error(supervisor_stubs):
    async def run():
        socket, down = PumpSocket(), Downstream()
        task = await start(socket, down)
        await down.incoming.put('{"secret":"private words"}')
        with pytest.raises(SessionError) as caught:
            await asyncio.wait_for(task, 1)
        assert "private" not in str(caught.value)
        assert socket.close_calls == down.closed == 1
        assert supervisor_stubs == ["disconnected"]

    asyncio.run(run())


def test_startup_failure_closes_downstream(supervisor_stubs):
    async def run():
        socket, down = PumpSocket(), Downstream()
        socket.bad_update = True
        task = await start(socket, down)
        with pytest.raises(SessionError):
            await asyncio.wait_for(task, 1)
        assert socket.close_calls == down.closed == 1
        assert supervisor_stubs == ["config_failed"]

    asyncio.run(run())


def test_cancel_during_startup_closes_downstream(supervisor_stubs):
    async def run():
        socket, down = PumpSocket(), Downstream()
        socket.stall = True
        task = await start(socket, down)
        await asyncio.wait_for(socket.created.wait(), 1)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await asyncio.wait_for(task, 1)
        assert socket.close_calls == down.closed == 1
        assert supervisor_stubs == ["cancelled"]

    asyncio.run(run())


def test_downstream_send_failure_closes_both_sides(supervisor_stubs):
    async def run():
        class FailedSend(Downstream):
            async def send(self, value):
                raise RuntimeError("private transcript")

        socket, down = PumpSocket(), FailedSend()
        task = await start(socket, down)
        await socket.incoming.put(msg("input_audio_buffer.speech_started", "e1", item_id="user"))
        with pytest.raises(SessionError) as caught:
            await asyncio.wait_for(task, 1)
        assert "private" not in str(caught.value)
        assert socket.close_calls == down.closed == 1

    asyncio.run(run())


def test_cancellation_closes_both_sides(supervisor_stubs):
    async def run():
        socket, down = PumpSocket(), Downstream()
        task = await start(socket, down)
        await socket.incoming.put(msg("input_audio_buffer.speech_started", "e1", item_id="user"))
        await asyncio.wait_for(down.output.get(), 1)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await asyncio.wait_for(task, 1)
        assert socket.close_calls == down.closed == 1
        assert supervisor_stubs == ["cancelled"]

    asyncio.run(run())


def test_late_receive_retains_capacity_and_cannot_reopen_pump(supervisor_stubs, monkeypatch):
    from simontalk_api import supervised_pump_session as module

    monkeypatch.setattr(module, "_CLEANUP_WAIT", 0.02)
    monkeypatch.setattr(module, "_MAX_SESSIONS", 1)

    async def run():
        entered, release = asyncio.Event(), asyncio.Event()

        class Stubborn(Downstream):
            async def receive(self):
                entered.set()
                try:
                    await asyncio.Future()
                except asyncio.CancelledError:
                    await release.wait()
                return '{"kind":"mode","epoch":1,"muted":false}'

        socket, down = PumpSocket(), Stubborn()
        task = await start(socket, down)
        await asyncio.wait_for(entered.wait(), 1)
        await socket.incoming.put(None)
        with pytest.raises(SessionError):
            await asyncio.wait_for(task, 1)
        second_socket, second_down = PumpSocket(), Downstream()
        second = await start(second_socket, second_down)
        with pytest.raises(SessionError):
            await asyncio.wait_for(second, 1)
        assert second_socket.calls == 0 and second_down.closed == 1
        assert socket.close_calls == down.closed == 1
        release.set()
        for _ in range(100):
            if not module._SESSIONS:
                break
            await asyncio.sleep(0.001)
        assert not module._SESSIONS
        assert [event["type"] for event in socket.sent] == ["session.update"]

    asyncio.run(run())


def test_same_downstream_cannot_be_reused_while_active(supervisor_stubs):
    async def run():
        socket, down = PumpSocket(), Downstream()
        first = await start(socket, down)
        await socket.incoming.put(msg("input_audio_buffer.speech_started", "e1", item_id="user"))
        await asyncio.wait_for(down.output.get(), 1)
        other_socket = PumpSocket()
        second = await start(other_socket, down)
        with pytest.raises(SessionError):
            await asyncio.wait_for(second, 1)
        assert other_socket.calls == 0 and down.closed == 0
        await down.incoming.put('{"kind":"stop"}')
        assert await asyncio.wait_for(first, 1) == "stopped"
        assert down.closed == socket.close_calls == 1

    asyncio.run(run())


def test_runtime_identity_loss_closes_downstream(monkeypatch):
    from simontalk_api import websocket_supervisor as supervisor

    invalidated = False
    finalized = []

    def revalidate(*args, active=False, **kwargs):
        if active and invalidated:
            raise ValueError("private identity")

    monkeypatch.setattr(supervisor, "_revalidate", revalidate)
    monkeypatch.setattr(supervisor, "_RECHECK_INTERVAL", 0.01)
    monkeypatch.setattr(
        supervisor, "mark_websocket_unknown", lambda *args: finalized.append(args[2])
    )

    async def run():
        nonlocal invalidated
        socket, down = PumpSocket(), Downstream()
        task = await start(socket, down)
        await socket.incoming.put(msg("input_audio_buffer.speech_started", "e1", item_id="user"))
        await asyncio.wait_for(down.output.get(), 1)
        invalidated = True
        with pytest.raises(SessionError) as caught:
            await asyncio.wait_for(task, 1)
        assert "private" not in str(caught.value)
        assert socket.close_calls == down.closed == 1
        assert finalized == ["auth_lost"]

    asyncio.run(run())


def test_cancelled_late_delivery_prevents_downstream_reuse(supervisor_stubs, monkeypatch):
    from simontalk_api import supervised_pump_session as module

    monkeypatch.setattr(module, "_CLEANUP_WAIT", 0.02)

    async def run():
        entered, release = asyncio.Event(), asyncio.Event()

        class StubbornSend(Downstream):
            async def send(self, value):
                entered.set()
                try:
                    await asyncio.Future()
                except asyncio.CancelledError:
                    await release.wait()

        socket, down = PumpSocket(), StubbornSend()
        task = await start(socket, down)
        await socket.incoming.put(msg("input_audio_buffer.speech_started", "e1", item_id="user"))
        try:
            await asyncio.wait_for(entered.wait(), 1)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await asyncio.wait_for(task, 1)
            second_socket = PumpSocket()
            second = await start(second_socket, down)
            with pytest.raises(SessionError):
                await asyncio.wait_for(second, 1)
            assert second_socket.calls == 0
        finally:
            release.set()
        for _ in range(100):
            if not module._SESSIONS:
                break
            await asyncio.sleep(0.001)
        assert not module._SESSIONS

    asyncio.run(run())


def test_supervised_pump_session_forwards_slow_pace_once_and_rejects_bad_provider_echo(
    supervisor_stubs,
):
    async def run():
        socket, down = PumpSocket(), Downstream()
        task = await start(socket, down)
        await down.incoming.put('{"kind":"pace","pace":"slow"}')
        pace_event = await asyncio.wait_for(down.output.get(), 1)
        assert pace_event == {"kind": "pace_updated", "pace": "slow"}
        assert [event["type"] for event in socket.sent] == ["session.update", "session.update"]
        assert "natural conversational pace" in socket.sent[0]["session"]["instructions"]
        assert "Speak slowly and clearly." in socket.sent[1]["session"]["instructions"]
        await down.incoming.put('{"kind":"stop"}')
        assert await asyncio.wait_for(task, 1) == "stopped"

        bad_socket, bad_down = PumpSocket(), Downstream()
        bad_socket.bad_pace_update = True
        bad_task = await start(bad_socket, bad_down)
        await bad_down.incoming.put('{"kind":"pace","pace":"slow"}')
        with pytest.raises(SessionError):
            await asyncio.wait_for(bad_task, 1)
        assert bad_socket.close_calls == bad_down.closed == 1

    asyncio.run(run())
