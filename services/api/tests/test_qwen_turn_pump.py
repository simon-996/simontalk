"""Synthetic provider and downstream; no model, accounts or real microphone."""

import asyncio
import json

import pytest
from test_qwen_websocket_turn_policy import event, pcm
from test_websocket_pcm_wire import frame

from simontalk_api.qwen_turn_pump import QwenPumpError, QwenTurnPump
from simontalk_api.qwen_websocket_session import QwenSessionGate


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


def test_end_drains_only_the_existing_user_item_without_starting_a_reply():
    async def run():
        up, down = Upstream(), Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        try:
            await pump.accept_client('{"kind":"mode","epoch":1,"muted":false}')
            assert await pump.accept_client(frame(1, 1)) == "forwarded"
            await deliver(
                pump, up, msg("input_audio_buffer.speech_started", "e1", item_id="user_a")
            )
            await deliver(
                pump, up, msg("input_audio_buffer.speech_stopped", "e3", item_id="user_a")
            )
            assert await pump.accept_client('{"kind":"drain"}') == "draining"
            assert (
                await deliver(
                    pump, up, msg("input_audio_buffer.speech_started", "e2", item_id="user_b")
                )
                == "ignored"
            )
            await deliver(pump, up, msg("input_audio_buffer.committed", "e4", item_id="user_a"))
            await deliver(
                pump,
                up,
                msg(
                    "conversation.item.input_audio_transcription.completed",
                    "e5",
                    item_id="user_a",
                    content_index=0,
                    transcript="My last words",
                ),
            )
            assert down.sent[-1]["event"]["transcript"] == "My last words"
            assert [value["type"] for value in up.sent] == ["input_audio_buffer.append"]
            assert await pump.accept_client('{"kind":"stop"}') == "stopped"
        finally:
            await pump.close()

    asyncio.run(run())


def test_end_finishes_only_the_unstopped_known_input_with_one_provider_commit():
    async def run():
        up, down = Upstream(), Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        try:
            await deliver(
                pump, up, msg("input_audio_buffer.speech_started", "e1", item_id="user_a")
            )
            assert await pump.accept_client('{"kind":"drain"}') == "draining"
            assert up.sent == [
                {"type": "input_audio_buffer.commit", "event_id": "simontalk_finish_input"}
            ]
            await deliver(pump, up, msg("input_audio_buffer.committed", "e2", item_id="user_a"))
            await deliver(
                pump,
                up,
                msg(
                    "conversation.item.input_audio_transcription.completed",
                    "e3",
                    item_id="user_a",
                    content_index=0,
                    transcript="Good morning.",
                ),
            )
            assert [value["type"] for value in up.sent] == ["input_audio_buffer.commit"]
            assert down.sent[-1]["event"]["transcript"] == "Good morning."
        finally:
            await pump.close()

    asyncio.run(run())


def test_end_while_final_is_being_forwarded_prevents_the_reply():
    async def run():
        received, release = asyncio.Event(), asyncio.Event()

        class HeldFinal(Downstream):
            async def send(self, value):
                event = json.loads(value).get("event", {})
                if event.get("type") == "conversation.item.input_audio_transcription.completed":
                    received.set()
                    await release.wait()
                await super().send(value)

        up, down = Upstream(), HeldFinal()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        delivery = None
        try:
            await deliver(
                pump, up, msg("input_audio_buffer.speech_started", "e1", item_id="user_a")
            )
            await deliver(
                pump, up, msg("input_audio_buffer.speech_stopped", "e2", item_id="user_a")
            )
            await deliver(pump, up, msg("input_audio_buffer.committed", "e3", item_id="user_a"))
            delivery = asyncio.create_task(
                deliver(
                    pump,
                    up,
                    msg(
                        "conversation.item.input_audio_transcription.completed",
                        "e4",
                        item_id="user_a",
                        content_index=0,
                        transcript="My last words",
                    ),
                )
            )
            await asyncio.wait_for(received.wait(), 1)
            assert await pump.accept_client('{"kind":"drain"}') == "draining"
            release.set()
            assert await delivery == "forwarded"
            assert down.sent[-1]["event"]["transcript"] == "My last words"
            assert up.sent == []
        finally:
            release.set()
            if delivery is not None:
                await asyncio.gather(delivery, return_exceptions=True)
            await pump.close()

    asyncio.run(run())


@pytest.mark.parametrize("status", ["failed", "incomplete"])
def test_known_failed_reply_does_not_drop_the_interrupting_users_tail(status):
    async def run():
        up, down = Upstream(), Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        try:
            await prepare_response(pump, up)
            await deliver(
                pump, up, msg("input_audio_buffer.speech_started", "e7", item_id="user_b")
            )
            assert await pump.accept_client('{"kind":"drain"}') == "draining"
            await deliver(
                pump,
                up,
                msg("response.done", "e8", response={"id": "response_a", "status": status}),
            )
            await deliver(
                pump, up, msg("input_audio_buffer.speech_stopped", "e9", item_id="user_b")
            )
            await deliver(pump, up, msg("input_audio_buffer.committed", "e10", item_id="user_b"))
            await deliver(
                pump,
                up,
                msg(
                    "conversation.item.input_audio_transcription.completed",
                    "e11",
                    item_id="user_b",
                    content_index=0,
                    transcript="Please wait.",
                ),
            )
            assert down.sent[-1]["event"]["transcript"] == "Please wait."
            assert [value["type"] for value in up.sent] == [
                "response.create",
                "response.cancel",
                "input_audio_buffer.commit",
            ]
        finally:
            await pump.close()

    asyncio.run(run())


def test_end_keeps_the_known_assistant_tail_when_user_transcription_fails():
    async def run():
        up, down = Upstream(), Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        try:
            await prepare_response(pump, up)
            await deliver(
                pump, up, msg("input_audio_buffer.speech_started", "e7", item_id="user_b")
            )
            assert await pump.accept_client('{"kind":"drain"}') == "draining"
            await deliver(pump, up, msg("input_audio_buffer.committed", "e8", item_id="user_b"))
            assert (
                await deliver(
                    pump,
                    up,
                    msg(
                        "conversation.item.input_audio_transcription.failed",
                        "e9",
                        item_id="user_b",
                        content_index=0,
                        error={"code": "transcription_failed", "message": "private provider text"},
                    ),
                )
                == "ignored"
            )
            await deliver(
                pump,
                up,
                msg(
                    "response.audio_transcript.done",
                    "e10",
                    response_id="response_a",
                    item_id="item_a",
                    output_index=0,
                    content_index=0,
                    transcript="Assistant tail.",
                ),
            )
            assert down.sent[-1]["event"]["transcript"] == "Assistant tail."
            assert all("private provider text" not in str(e) for e in down.sent)
            assert [value["type"] for value in up.sent] == [
                "response.create",
                "response.cancel",
                "input_audio_buffer.commit",
            ]
            assert (
                await deliver(
                    pump,
                    up,
                    msg(
                        "conversation.item.input_audio_transcription.completed",
                        "e11",
                        item_id="user_b",
                        content_index=0,
                        transcript="An inconsistent final.",
                    ),
                )
                == "ignored"
            )
            assert await pump.accept_client('{"kind":"stop"}') == "stopped"
        finally:
            await pump.close()

    asyncio.run(run())


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


def test_server_usage_survives_failure_to_send_terminal_event_to_the_browser():
    async def run():
        up, down = Upstream(), Downstream()
        observations = []
        pump = QwenTurnPump(up, down.send, down.close, on_response_usage=observations.append)
        try:
            await prepare_response(pump, up)
            down.fail = True
            with pytest.raises(QwenPumpError):
                await deliver(
                    pump,
                    up,
                    msg(
                        "response.done",
                        "done",
                        response={
                            "id": "response_a",
                            "status": "completed",
                            "usage": {"input_tokens": 11, "output_tokens": 5},
                        },
                    ),
                )
            assert len(observations) == 1 and observations[0].input_tokens == 11
        finally:
            await pump.close()

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


def test_multi_turn_settle_and_post_done_playback_overlap_quarantine():
    async def run():
        up, down = Upstream(), Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        await prepare_response(pump, up)
        await deliver(
            pump,
            up,
            msg("response.done", "e7", response={"id": "response_a", "status": "completed"}),
        )
        assert (
            await pump.accept_client('{"kind":"settled","response_id":"response_a"}') == "settled"
        )

        await deliver(pump, up, msg("input_audio_buffer.speech_started", "e8", item_id="user_b"))
        await deliver(pump, up, msg("input_audio_buffer.speech_stopped", "e9", item_id="user_b"))
        await deliver(pump, up, msg("input_audio_buffer.committed", "e10", item_id="user_b"))
        await deliver(
            pump,
            up,
            msg(
                "conversation.item.input_audio_transcription.completed",
                "e11",
                item_id="user_b",
                content_index=0,
                transcript="Second turn",
            ),
        )
        assert [m["type"] for m in up.sent] == ["response.create", "response.create"]
        await deliver(pump, up, msg("response.created", "e12", response={"id": "response_b"}))
        await deliver(
            pump,
            up,
            msg("response.done", "e13", response={"id": "response_b", "status": "completed"}),
        )

        # User speaks before browser sends settled for response_b.
        await deliver(pump, up, msg("input_audio_buffer.speech_started", "e14", item_id="user_c"))
        assert down.sent[-2] == {"kind": "quarantine", "response_id": "response_b"}
        assert "response.cancel" not in [m["type"] for m in up.sent]
        await pump.close()

    asyncio.run(run())


def _configured_gate(pace="normal"):
    gate = QwenSessionGate("intermediate", pace)
    created = json.dumps(
        {
            "type": "session.created",
            "event_id": "evt_created",
            "session": {
                "id": "sess_pump",
                "object": "realtime.session",
                "model": "qwen3.8-omni-flash-realtime",
            },
        }
    )
    settings = json.loads(gate.accept_created(created))["session"]
    updated = {
        "type": "session.updated",
        "event_id": "evt_updated_1",
        "session": {
            **settings,
            "id": "sess_pump",
            "object": "realtime.session",
            "model": "qwen3.8-omni-flash-realtime",
            "input_audio_format": "pcm",
            "output_audio_format": "pcm",
        },
    }
    assert gate.accept_updated(json.dumps(updated)) is True
    return gate


def test_mid_session_slow_pace_updates_upstream_and_notifies_downstream_without_cancelling_reply():
    async def run():
        up, down = Upstream(), Downstream()
        gate = _configured_gate("normal")
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0, session_gate=gate)
        await prepare_response(pump, up)
        await deliver(pump, up, pcm("e_pcm"))
        assert await pump.accept_client('{"kind":"pace","pace":"slow"}') == "pace_requested"
        assert [m["type"] for m in up.sent] == ["response.create", "session.update"]
        slow_session = up.sent[-1]["session"]
        assert "Speak slowly and clearly." in slow_session["instructions"]

        echo = json.dumps(
            {
                "type": "session.updated",
                "event_id": "evt_updated_2",
                "session": {
                    **slow_session,
                    "id": "sess_pump",
                    "object": "realtime.session",
                    "model": "qwen3.8-omni-flash-realtime",
                    "input_audio_format": "pcm",
                    "output_audio_format": "pcm",
                },
            }
        )
        assert await deliver(pump, up, echo) == "pace_updated"
        assert down.sent[-1] == {"kind": "pace_updated", "pace": "slow"}
        assert "response.cancel" not in [m["type"] for m in up.sent]
        # Exact duplicate delivery of session.updated is ignored, while unsolicited new one fails.
        assert await deliver(pump, up, echo) == "ignored"
        with pytest.raises(QwenPumpError):
            await deliver(
                pump,
                up,
                echo.replace('"evt_updated_2"', '"evt_unsolicited"'),
            )
        assert up.closed == 1 and down.closed == 1

    asyncio.run(run())


def test_crossing_slow_pace_after_upstream_interruption_is_ignored_while_already_slow_fails():
    async def run():
        up, down = Upstream(), Downstream()
        gate = _configured_gate("normal")
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0, session_gate=gate)
        await prepare_response(pump, up)
        await deliver(pump, up, msg("input_audio_buffer.speech_started", "e7", item_id="user_b"))
        assert await pump.accept_client('{"kind":"pace","pace":"slow"}') == "ignored"
        assert "session.update" not in [m["type"] for m in up.sent]
        await pump.close()

        up2, down2 = Upstream(), Downstream()
        slow_gate = _configured_gate("slow")
        pump2 = QwenTurnPump(
            up2, down2.send, down2.close, clock=lambda: 0.0, session_gate=slow_gate
        )
        with pytest.raises(QwenPumpError):
            await pump2.accept_client('{"kind":"pace","pace":"slow"}')
        assert up2.closed == 1 and down2.closed == 1

    asyncio.run(run())


def test_explicit_client_interrupt_cancels_active_reply_and_accepts_subsequent_user_turn():
    async def run():
        up, down = Upstream(), Downstream()
        pump = QwenTurnPump(up, down.send, down.close, clock=lambda: 0.0)
        await pump.accept_client('{"kind":"mode","epoch":1,"muted":false}')
        await prepare_response(pump, up)
        await deliver(pump, up, pcm("e_pcm_1"))
        assert await pump.accept_client('{"kind":"interrupt"}') == "interrupted"
        assert down.sent[-1] == {"kind": "quarantine", "response_id": "response_a"}
        assert [m["type"] for m in up.sent] == ["response.create", "response.cancel"]
        # Late audio from retired response_a is dropped.
        before = len(down.sent)
        await deliver(pump, up, pcm("e_pcm_late"))
        assert len(down.sent) == before
        # User speaks after clicking "我来说" and their turn is transcribed without a second reply.
        await deliver(pump, up, msg("input_audio_buffer.speech_started", "e8", item_id="user_b"))
        await deliver(pump, up, msg("input_audio_buffer.speech_stopped", "e9", item_id="user_b"))
        await deliver(pump, up, msg("input_audio_buffer.committed", "e10", item_id="user_b"))
        await deliver(
            pump,
            up,
            msg(
                "conversation.item.input_audio_transcription.completed",
                "e11",
                item_id="user_b",
                content_index=0,
                transcript="Let me take over.",
            ),
        )
        assert down.sent[-1]["event"]["transcript"] == "Let me take over."
        assert [m["type"] for m in up.sent] == ["response.create", "response.cancel"]
        await pump.close()

        # Post-done buffered playback explicit interrupt skips response.cancel;
        # ending without speech skips input_audio_buffer.commit.
        up2, down2 = Upstream(), Downstream()
        pump2 = QwenTurnPump(up2, down2.send, down2.close, clock=lambda: 0.0)
        await pump2.accept_client('{"kind":"mode","epoch":1,"muted":false}')
        await prepare_response(pump2, up2)
        await deliver(
            pump2,
            up2,
            msg("response.done", "e_done", response={"id": "response_a", "status": "completed"}),
        )
        assert await pump2.accept_client('{"kind":"interrupt"}') == "interrupted"
        assert down2.sent[-1] == {"kind": "quarantine", "response_id": "response_a"}
        assert await pump2.accept_client('{"kind":"drain"}') == "draining"
        assert [m["type"] for m in up2.sent] == ["response.create"]
        await pump2.close()

        # Crossing explicit interrupt after upstream voice interruption is safely ignored.
        up3, down3 = Upstream(), Downstream()
        pump3 = QwenTurnPump(up3, down3.send, down3.close, clock=lambda: 0.0)
        await pump3.accept_client('{"kind":"mode","epoch":1,"muted":false}')
        await prepare_response(pump3, up3)
        await deliver(pump3, up3, msg("input_audio_buffer.speech_started", "e7", item_id="user_b"))
        assert await pump3.accept_client('{"kind":"interrupt"}') == "ignored"
        await pump3.close()

    asyncio.run(run())
