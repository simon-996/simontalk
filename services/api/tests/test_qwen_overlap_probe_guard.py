"""Local safety checks for the next bounded overlap experiment; no vendor I/O."""

import asyncio
import base64
import importlib.util
import json
from pathlib import Path


def guard_module():
    path = Path(__file__).resolve().parents[3] / "scripts" / "qwen_overlap_probe_guard.py"
    spec = importlib.util.spec_from_file_location("qwen_overlap_probe_guard", path)
    assert spec is not None and path.is_file(), "Bounded probe guard is missing"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeSocket:
    def __init__(self, events, *, send_fails=False):
        self.events = asyncio.Queue()
        for event in events:
            self.events.put_nowait(event)
        self.sent = []
        self.send_fails = send_fails

    async def recv(self):
        return await self.events.get()

    async def send(self, payload):
        if self.send_fails:
            raise OSError("private transport detail")
        self.sent.append(json.loads(payload))


def audio(data):
    return {"type": "response.audio.delta", "delta": base64.b64encode(data).decode()}


def test_audio_cap_sends_one_cancel_and_collects_terminal_usage():
    async def run():
        module = guard_module()
        socket = FakeSocket(
            [
                audio(b"1234"),
                audio(b"5678"),
                audio(b"90"),
                {"type": "response.done", "response": {"status": "cancelled", "usage": None}},
            ]
        )
        result = await module.receive_bounded(socket, max_audio_bytes=6, timeout_seconds=1)
        assert result["reason"] == "audio_limit"
        assert result["response_status"] == "cancelled"
        assert result["usage"] is None
        assert result["cancel_sent"] is True
        assert [value["type"] for value in socket.sent] == ["response.cancel"]
        assert result["audio_bytes_observed"] == 10

    asyncio.run(run())


def test_reader_failure_sends_cancel_and_reports_unknown_without_leaking_exception():
    async def run():
        module = guard_module()
        socket = FakeSocket([audio(b"123")])
        result = await module.receive_bounded(socket, max_audio_bytes=1, timeout_seconds=0.03)
        assert result["reason"] == "audio_limit"
        assert result["response_status"] is None and result["usage"] is None
        assert result["cancel_sent"] is True
        assert len(socket.sent) == 1

    asyncio.run(run())


def test_bad_audio_sends_cancel_once_and_never_logs_payload():
    async def run():
        module = guard_module()
        socket = FakeSocket(
            [
                {"type": "response.audio.delta", "delta": "not-base64-private"},
                {"type": "response.done", "response": {"status": "cancelled"}},
            ]
        )
        result = await module.receive_bounded(socket, max_audio_bytes=100, timeout_seconds=1)
        assert result["reason"] == "invalid_audio"
        assert result["cancel_sent"] is True
        assert "not-base64-private" not in repr(result)
        assert len(socket.sent) == 1

    asyncio.run(run())


def test_completed_response_is_not_cancelled_and_still_records_usage():
    async def run():
        module = guard_module()
        socket = FakeSocket(
            [audio(b"abc"), {"type": "response.done", "response": {"status": "completed"}}]
        )
        result = await module.receive_bounded(socket, max_audio_bytes=4, timeout_seconds=1)
        assert result["reason"] == "response_done"
        assert result["response_status"] == "completed"
        assert result["cancel_sent"] is False and socket.sent == []

    asyncio.run(run())


def test_failed_response_is_not_misreported_as_success():
    async def run():
        module = guard_module()
        socket = FakeSocket([{"type": "response.done", "response": {"status": "failed"}}])
        result = await module.receive_bounded(socket, max_audio_bytes=4, timeout_seconds=1)
        assert result["reason"] == "response_done" and result["response_status"] == "failed"
        assert result["usage"] is None

    asyncio.run(run())


def test_cancel_send_failure_is_sanitized_and_bounded():
    async def run():
        module = guard_module()
        socket = FakeSocket([audio(b"123")], send_fails=True)
        result = await module.receive_bounded(socket, max_audio_bytes=1, timeout_seconds=0.03)
        assert result["reason"] == "audio_limit"
        assert result["cancel_sent"] is False
        assert result["response_status"] is None and result["usage"] is None
        assert "private transport detail" not in repr(result)

    asyncio.run(run())


def test_limit_stops_feeding_once_before_cancel():
    async def run():
        module = guard_module()
        actions = []

        class ObservedSocket(FakeSocket):
            async def send(self, payload):
                actions.append("cancel")
                await super().send(payload)

        socket = ObservedSocket(
            [
                audio(b"123"),
                audio(b"456"),
                {"type": "response.done", "response": {"status": "cancelled"}},
            ]
        )
        result = await module.receive_bounded(
            socket,
            max_audio_bytes=1,
            timeout_seconds=1,
            stop_feeding=lambda: actions.append("stop_feed"),
        )
        assert actions == ["stop_feed", "cancel"]
        assert result["response_status"] == "cancelled"

    asyncio.run(run())


def test_transport_reader_failure_stops_feeding_and_attempts_cancel():
    async def run():
        module = guard_module()
        stopped = []

        class BrokenReader(FakeSocket):
            async def recv(self):
                raise OSError("private receiver detail")

        socket = BrokenReader([])
        result = await module.receive_bounded(
            socket,
            max_audio_bytes=16,
            timeout_seconds=1,
            stop_feeding=lambda: stopped.append(True),
        )
        assert result["reason"] == "receiver_failed" and stopped == [True]
        assert result["cancel_sent"] and len(socket.sent) == 1
        assert result["response_status"] is None and result["usage"] is None
        assert "private receiver detail" not in repr(result)

    asyncio.run(run())


def test_external_cancellation_stops_input_and_attempts_cancel():
    async def run():
        module = guard_module()
        stopped = []
        socket = FakeSocket([])
        task = asyncio.create_task(
            module.receive_bounded(
                socket,
                max_audio_bytes=100,
                timeout_seconds=1,
                stop_feeding=lambda: stopped.append(True),
            )
        )
        await asyncio.sleep(0)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("Cancellation must propagate")
        assert stopped == [True]
        assert [value["type"] for value in socket.sent] == ["response.cancel"]

    asyncio.run(run())


def test_unrelated_response_done_does_not_complete_the_target():
    async def run():
        module = guard_module()
        socket = FakeSocket(
            [
                {"type": "response.done", "response": {"id": "other", "status": "completed"}},
                {"type": "response.done", "response": {"id": "target", "status": "cancelled"}},
            ]
        )
        result = await module.receive_bounded(
            socket, max_audio_bytes=100, timeout_seconds=1, expected_response_id="target"
        )
        assert result["response_status"] == "cancelled"

    asyncio.run(run())


def test_terminal_usage_preserves_only_bounded_token_breakdown():
    async def run():
        module = guard_module()
        socket = FakeSocket(
            [
                {
                    "type": "response.done",
                    "response": {
                        "status": "completed",
                        "usage": {
                            "input_tokens": 100,
                            "output_tokens": 35,
                            "total_tokens": 135,
                            "input_tokens_details": {
                                "text_tokens": 80,
                                "audio_tokens": 20,
                                "private": "secret",
                            },
                            "output_tokens_details": {"text_tokens": 10, "audio_tokens": 25},
                        },
                    },
                }
            ]
        )
        result = await module.receive_bounded(socket, max_audio_bytes=10, timeout_seconds=1)
        assert result["usage"]["input_tokens_details"] == {"text_tokens": 80, "audio_tokens": 20}
        assert result["usage"]["output_tokens_details"] == {"text_tokens": 10, "audio_tokens": 25}
        assert "secret" not in repr(result)

    asyncio.run(run())
