"""Bounded outbound ordering with a fake socket; no provider calls."""

import asyncio
import base64
import json

import pytest

from simontalk_api.qwen_outbound_serializer import QwenSendError, QwenSerializedSender


def audio(n):
    return json.dumps(
        {
            "type": "input_audio_buffer.append",
            "event_id": f"event_audio_{n}",
            "audio": base64.b64encode(bytes(3200)).decode(),
        },
        separators=(",", ":"),
    )


class Connection:
    def __init__(self):
        self.sent = []
        self.entered = asyncio.Event()
        self.release = asyncio.Event()
        self.block = True
        self.closes = 0

    async def send(self, value):
        if self.block:
            self.block = False
            self.entered.set()
            await self.release.wait()
        self.sent.append(json.loads(value)["type"])

    async def close(self):
        self.closes += 1
        self.release.set()


def test_control_is_serialized_ahead_of_waiting_audio():
    async def run():
        connection = Connection()
        sender = QwenSerializedSender(connection)
        first = asyncio.create_task(sender.send(audio(1)))
        await connection.entered.wait()
        second = asyncio.create_task(sender.send(audio(2)))
        await asyncio.sleep(0)
        cancel = asyncio.create_task(sender.send('{"type":"response.cancel"}'))
        await asyncio.sleep(0)
        connection.release.set()
        await asyncio.gather(first, second, cancel)
        assert connection.sent == [
            "input_audio_buffer.append",
            "response.cancel",
            "input_audio_buffer.append",
        ]
        await sender.close()
        assert connection.closes == 1

    asyncio.run(run())


@pytest.mark.parametrize(
    "value",
    [
        '{"type":"response.create","secret":"private"}',
        '{"type":"session.update"}',
        '{"type":"response.cancel","type":"response.cancel"}',
        "x",
        b"private",
        audio(1)[:-3],
    ],
)
def test_invalid_or_unapproved_messages_fail_closed(value):
    async def run():
        connection = Connection()
        sender = QwenSerializedSender(connection)
        with pytest.raises(QwenSendError) as caught:
            await sender.send(value)
        assert "private" not in str(caught.value)
        assert not connection.sent and connection.closes == 1
        with pytest.raises(QwenSendError):
            await sender.send(audio(1))

    asyncio.run(run())


def test_queue_overflow_closes_and_drops_pending(monkeypatch):
    import simontalk_api.qwen_outbound_serializer as module

    monkeypatch.setattr(module, "_MAX_AUDIO_PENDING", 1)

    async def run():
        connection = Connection()
        sender = QwenSerializedSender(connection)
        first = asyncio.create_task(sender.send(audio(1)))
        await connection.entered.wait()
        second = asyncio.create_task(sender.send(audio(2)))
        await asyncio.sleep(0)
        with pytest.raises(QwenSendError):
            await sender.send(audio(3))
        results = await asyncio.gather(first, second, return_exceptions=True)
        assert all(isinstance(e, QwenSendError) for e in results)
        assert connection.closes == 1

    asyncio.run(run())


def test_cancellation_closes_once_and_rejects_queued_writes():
    async def run():
        connection = Connection()
        sender = QwenSerializedSender(connection)
        first = asyncio.create_task(sender.send(audio(1)))
        await connection.entered.wait()
        second = asyncio.create_task(sender.send(audio(2)))
        await asyncio.sleep(0)
        first.cancel()
        with pytest.raises(asyncio.CancelledError):
            await first
        with pytest.raises(QwenSendError):
            await second
        await asyncio.gather(sender.close(), sender.close())
        assert connection.closes == 1

    asyncio.run(run())


def test_real_pcm_adapter_and_turn_policy_share_one_ordered_sender():
    from test_qwen_websocket_turn_policy import event, user_ready

    from simontalk_api.qwen_pcm_upstream import QwenPcmInput
    from simontalk_api.qwen_websocket_turn_policy import QwenTurnPolicy

    async def run():
        connection = Connection()
        connection.release.set()
        sender = QwenSerializedSender(connection)
        adapter = QwenPcmInput(sender, clock=lambda: 0.0)
        await adapter.set_muted(False, 1)
        policy = QwenTurnPolicy()
        ready = user_ready(policy)
        assert ready.create_response
        await sender.send('{"type":"response.create"}')
        assert await adapter.append(1, 1, bytes(3200))
        policy.accept(event("response.created", "r1", response={"id": "response_a"}))
        decision = policy.accept(event("input_audio_buffer.speech_started", "i1", item_id="user_b"))
        assert decision.quarantine and decision.cancel_response
        await sender.send('{"type":"response.cancel"}')
        assert connection.sent == [
            "response.create",
            "input_audio_buffer.append",
            "response.cancel",
        ]
        await adapter.close()
        assert connection.closes == 1

    asyncio.run(run())


def test_transport_failure_rejects_inflight_and_closes_once():
    class Broken(Connection):
        async def send(self, value):
            raise RuntimeError("private provider data")

    async def run():
        connection = Broken()
        sender = QwenSerializedSender(connection)
        with pytest.raises(QwenSendError) as caught:
            await sender.send(audio(1))
        assert "private" not in str(caught.value)
        await sender.close()
        assert connection.closes == 1

    asyncio.run(run())
