"""Synthetic provider and downstream; no model, accounts or real microphone."""

import asyncio
import json

import pytest
from test_qwen_websocket_turn_policy import event, pcm
from test_websocket_pcm_wire import frame

from simontalk_api.qwen_turn_pump import QwenPumpError, QwenTurnPump


class Upstream:
    def __init__(self):
        self.incoming = asyncio.Queue()
        self.sent = []
        self.closed = 0

    async def receive(self):
        return await self.incoming.get()

    async def send(self, value):
        self.sent.append(json.loads(value))

    async def close(self):
        self.closed += 1


class Downstream:
    def __init__(self):
        self.sent = []
        self.closed = 0
        self.fail = False
        self.stall_quarantine = False

    async def send(self, value):
        payload = json.loads(value)
        if self.fail:
            raise RuntimeError("private downstream error")
        if self.stall_quarantine and payload.get("kind") == "quarantine":
            await asyncio.Future()
        self.sent.append(payload)

    async def close(self):
        self.closed += 1


def msg(kind, eid, **kwargs):
    return event(kind, eid, **kwargs)


async def deliver(pump, up, raw):
    await up.incoming.put(raw)
    return await pump.receive_one()


async def prepare_response(pump, up):
    await deliver(pump, up, msg("input_audio_buffer.speech_started", "e1", item_id="user_a"))
    await deliver(pump, up, msg("input_audio_buffer.speech_stopped", "e2", item_id="user_a"))
    await deliver(pump, up, msg("input_audio_buffer.committed", "e3", item_id="user_a"))
    await deliver(
        pump,
        up,
        msg(
            "conversation.item.input_audio_transcription.completed",
            "e4",
            item_id="user_a",
            content_index=0,
            transcript="Hello there",
        ),
    )
    await deliver(pump, up, msg("response.created", "e5", response={"id": "response_a"}))
    await deliver(
        pump,
        up,
        msg(
            "response.output_item.added",
            "e6",
            response_id="response_a",
            output_index=0,
            item={"id": "item_a", "type": "message", "role": "assistant"},
        ),
    )


def test_one_turn_pcm_reply_and_interruption_are_composed():
    async def run():
        up = Upstream()
        down = Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        assert await pump.accept_client('{"kind":"mode","epoch":1,"muted":false}') == "mode"
        assert await pump.accept_client(frame(1, 1)) == "forwarded"
        await prepare_response(pump, up)
        assert [value["type"] for value in up.sent] == [
            "input_audio_buffer.append",
            "response.create",
        ]
        await deliver(pump, up, pcm())
        assert down.sent[-1]["event"]["type"] == "response.audio.delta"
        await deliver(
            pump,
            up,
            msg(
                "conversation.item.input_audio_transcription.delta",
                "e8",
                item_id="user_b",
                content_index=0,
                text="Wait",
                stash="",
            ),
        )
        assert down.sent[-2] == {"kind": "quarantine", "response_id": "response_a"}
        assert down.sent[-1]["event"]["type"] == "conversation.item.input_audio_transcription.delta"
        assert [value["type"] for value in up.sent].count("response.cancel") == 1
        before = len(down.sent)
        await deliver(pump, up, pcm("e9"))
        assert len(down.sent) == before
        await pump.close()
        assert up.closed == 1 and down.closed == 1

    asyncio.run(run())


def test_downstream_failure_prevents_reply_and_closes():
    async def run():
        up = Upstream()
        down = Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        await deliver(pump, up, msg("input_audio_buffer.speech_started", "e1", item_id="user_a"))
        await deliver(pump, up, msg("input_audio_buffer.speech_stopped", "e2", item_id="user_a"))
        await deliver(pump, up, msg("input_audio_buffer.committed", "e3", item_id="user_a"))
        down.fail = True
        with pytest.raises(QwenPumpError) as caught:
            await deliver(
                pump,
                up,
                msg(
                    "conversation.item.input_audio_transcription.completed",
                    "e4",
                    item_id="user_a",
                    content_index=0,
                    transcript="private words",
                ),
            )
        assert "private" not in str(caught.value)
        assert not up.sent and up.closed == 1 and down.closed == 1

    asyncio.run(run())


def test_cancel_is_sent_even_if_quarantine_notification_stalls(monkeypatch):
    import simontalk_api.qwen_turn_pump as module

    monkeypatch.setattr(module, "_DELIVERY_TIMEOUT", 0.05)

    async def run():
        up = Upstream()
        down = Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        await prepare_response(pump, up)
        down.stall_quarantine = True
        with pytest.raises(QwenPumpError):
            await deliver(
                pump, up, msg("input_audio_buffer.speech_started", "e8", item_id="user_b")
            )
        assert [value["type"] for value in up.sent].count("response.cancel") == 1
        assert up.closed == 1 and down.closed == 1

    asyncio.run(run())


def test_failed_quarantine_closes_without_waiting_for_stalled_cancel(monkeypatch):
    import simontalk_api.qwen_turn_pump as module

    monkeypatch.setattr(module, "_ACTION_TIMEOUT", 2.0)

    async def run():
        release = asyncio.Event()

        class StalledCancel(Upstream):
            async def send(self, value):
                if json.loads(value)["type"] == "response.cancel":
                    await release.wait()
                await super().send(value)

        up = StalledCancel()
        down = Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        try:
            await prepare_response(pump, up)
            down.fail = True
            with pytest.raises(QwenPumpError):
                await asyncio.wait_for(
                    deliver(
                        pump,
                        up,
                        msg("input_audio_buffer.speech_started", "e8", item_id="user_b"),
                    ),
                    timeout=0.5,
                )
            assert up.closed == 1 and down.closed == 1
        finally:
            release.set()
            await pump.close()
            await asyncio.sleep(0)

    asyncio.run(run())


def test_failed_cancel_closes_without_waiting_for_stalled_quarantine(monkeypatch):
    import simontalk_api.qwen_turn_pump as module

    monkeypatch.setattr(module, "_DELIVERY_TIMEOUT", 2.0)
    monkeypatch.setattr(module, "_ACTION_TIMEOUT", 2.0)

    async def run():
        class FailedCancel(Upstream):
            async def send(self, value):
                if json.loads(value)["type"] == "response.cancel":
                    raise RuntimeError("private upstream error")
                await super().send(value)

        up, down = FailedCancel(), Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        await prepare_response(pump, up)
        down.stall_quarantine = True
        with pytest.raises(QwenPumpError) as caught:
            await asyncio.wait_for(
                deliver(pump, up, msg("input_audio_buffer.speech_started", "e8", item_id="user_b")),
                timeout=0.5,
            )
        assert "private" not in str(caught.value)
        assert up.closed == 1 and down.closed == 1

    asyncio.run(run())
