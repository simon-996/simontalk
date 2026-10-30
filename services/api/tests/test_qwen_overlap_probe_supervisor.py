"""Local task supervision checks; no network or provider calls."""

import asyncio
import base64
import importlib.util
import json
from pathlib import Path


def module():
    import sys

    scripts = Path(__file__).resolve().parents[3] / "scripts"
    sys.path.insert(0, str(scripts))
    spec = importlib.util.spec_from_file_location(
        "overlap_supervisor", scripts / "qwen_overlap_probe_supervisor.py"
    )
    assert spec is not None and spec.loader is not None
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


class Socket:
    def __init__(self, *, fail_input=False):
        self.incoming = asyncio.Queue()
        self.sent = []
        self.fail_input = fail_input

    async def recv(self):
        return await self.incoming.get()

    async def send(self, payload):
        event = json.loads(payload)
        self.sent.append(event["type"])
        if self.fail_input and event["type"] == "input_audio_buffer.append":
            raise OSError("private message")
        if event["type"] == "response.cancel":
            self.incoming.put_nowait(
                {"type": "response.done", "response": {"id": "current", "status": "cancelled"}}
            )


def audio(data):
    return {
        "type": "response.audio.delta",
        "response_id": "current",
        "delta": base64.b64encode(data).decode(),
    }


def test_audio_limit_stops_feeder_before_cancel_and_waits_for_terminal():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(audio(b"12345"))
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"a" * 6400,
            max_audio_bytes=4,
            timeout_seconds=1,
            chunk_interval=0.001,
        )
        assert result["reader"]["reason"] == "audio_limit"
        assert result["reader"]["response_status"] == "cancelled"
        assert result["feeder_stopped"]
        assert socket.sent == ["response.cancel"]

    asyncio.run(run())


def test_feeder_failure_cancels_reader_and_attempts_remote_cancel():
    async def run():
        socket = Socket(fail_input=True)
        socket.incoming.put_nowait(audio(b"x"))
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"a" * 6400,
            max_audio_bytes=100,
            timeout_seconds=1,
            chunk_interval=0.001,
        )
        assert result["reason"] == "feeder_failed"
        assert result["feeder_stopped"]
        assert socket.sent.count("response.cancel") == 1
        assert "private message" not in repr(result)

    asyncio.run(run())


def test_terminal_before_audio_stops_waiting_feeder_without_cancel():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(
            {"type": "response.done", "response": {"id": "current", "status": "completed"}}
        )
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"a" * 6400,
            max_audio_bytes=100,
            timeout_seconds=1,
            chunk_interval=0.001,
        )
        assert result["reader"]["response_status"] == "completed"
        assert result["feeder_stopped"]
        assert socket.sent == []

    asyncio.run(run())


def test_cancelling_supervisor_stops_input_and_propagates():
    async def run():
        socket = Socket()
        task = asyncio.create_task(
            module().supervise_overlap(
                socket,
                response_id="current",
                pcm=b"a" * 6400,
                max_audio_bytes=100,
                timeout_seconds=1,
                chunk_interval=0.001,
            )
        )
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("Outer cancellation must propagate")
        assert socket.sent == ["response.cancel"]

    asyncio.run(run())


def test_cancelling_supervisor_after_input_finishes_propagates():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(audio(b"x"))
        task = asyncio.create_task(
            module().supervise_overlap(
                socket,
                response_id="current",
                pcm=b"ab",
                max_audio_bytes=100,
                timeout_seconds=1,
                chunk_interval=0.001,
            )
        )
        await asyncio.sleep(0.02)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("Outer cancellation must propagate")
        assert socket.sent == ["input_audio_buffer.append", "response.cancel"]

    asyncio.run(run())


def test_other_response_audio_cannot_start_input():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(
            {"type": "response.audio.delta", "response_id": "other", "delta": "eA=="}
        )
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"ab",
            max_audio_bytes=100,
            timeout_seconds=1,
            chunk_interval=0.001,
        )
        assert result["reader"]["reason"] == "unexpected_response"
        assert socket.sent == ["response.cancel"]
        assert result["feeder_stopped"]

    asyncio.run(run())


def test_overlap_waits_for_speech_stop_and_observes_later_response():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(audio(b"x"))
        socket.incoming.put_nowait(
            {"type": "input_audio_buffer.speech_started", "item_id": "speech"}
        )
        socket.incoming.put_nowait(
            {"type": "response.done", "response": {"id": "current", "status": "completed"}}
        )
        socket.incoming.put_nowait(
            {"type": "input_audio_buffer.speech_stopped", "item_id": "speech"}
        )
        socket.incoming.put_nowait({"type": "response.created", "response": {"id": "unexpected"}})
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"ab",
            max_audio_bytes=100,
            timeout_seconds=1,
            chunk_interval=0.001,
            observe_overlap=True,
            post_speech_seconds=0.02,
        )
        assert result["reader"]["speech_started_before_done"] is True
        assert result["reader"]["speech_stopped"] is True
        assert result["reader"]["reason"] == "unexpected_response_created"
        assert socket.sent.count("response.cancel") == 1

    asyncio.run(run())


def test_overlap_window_finishes_only_after_both_events():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(audio(b"x"))
        socket.incoming.put_nowait(
            {"type": "input_audio_buffer.speech_started", "item_id": "speech"}
        )
        socket.incoming.put_nowait(
            {"type": "input_audio_buffer.speech_stopped", "item_id": "speech"}
        )
        socket.incoming.put_nowait(
            {"type": "response.done", "response": {"id": "current", "status": "completed"}}
        )
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"ab",
            max_audio_bytes=100,
            timeout_seconds=1,
            chunk_interval=0.001,
            observe_overlap=True,
            post_speech_seconds=0.02,
        )
        assert result["reader"]["reason"] == "overlap_window_observed"
        assert result["reader"]["response_status"] == "completed"
        assert result["reader"]["speech_stopped"] is True
        assert "response.cancel" not in socket.sent

    asyncio.run(run())


def test_missing_audio_response_id_stops_before_sending_input():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait({"type": "response.audio.delta", "delta": "eA=="})
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"ab",
            max_audio_bytes=100,
            timeout_seconds=1,
            chunk_interval=0.001,
        )
        assert result["reader"]["reason"] == "unexpected_response"
        assert result["input_chunks_sent"] == 0
        assert socket.sent == ["response.cancel"]

    asyncio.run(run())


def test_missing_speech_stop_cannot_complete_observation():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(audio(b"x"))
        socket.incoming.put_nowait(
            {"type": "response.done", "response": {"id": "current", "status": "completed"}}
        )
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"ab",
            max_audio_bytes=100,
            timeout_seconds=0.03,
            chunk_interval=0.001,
            observe_overlap=True,
            post_speech_seconds=0.01,
        )
        assert result["reader"]["reason"] == "timeout"
        assert not result["reader"]["speech_stopped"]
        assert result["reader"]["response_status"] == "completed"

    asyncio.run(run())


def test_out_of_order_speech_events_cannot_be_valid_overlap():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(audio(b"x"))
        socket.incoming.put_nowait(
            {"type": "input_audio_buffer.speech_stopped", "item_id": "speech"}
        )
        socket.incoming.put_nowait(
            {"type": "input_audio_buffer.speech_started", "item_id": "speech"}
        )
        socket.incoming.put_nowait(
            {
                "type": "response.done",
                "response": {
                    "id": "current",
                    "status": "completed",
                    "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
                },
            }
        )
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"ab",
            max_audio_bytes=100,
            timeout_seconds=1,
            chunk_interval=0.001,
            observe_overlap=True,
            post_speech_seconds=0.02,
        )
        assert not (
            result["reader"]["speech_started_before_done"] is True
            and result["reader"]["speech_stopped"] is True
        )

    asyncio.run(run())


def test_server_error_cannot_be_hidden_by_later_events():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(audio(b"x"))
        socket.incoming.put_nowait({"type": "error", "error": {"message": "private detail"}})
        socket.incoming.put_nowait(
            {"type": "input_audio_buffer.speech_started", "item_id": "speech"}
        )
        socket.incoming.put_nowait(
            {"type": "input_audio_buffer.speech_stopped", "item_id": "speech"}
        )
        socket.incoming.put_nowait(
            {"type": "response.done", "response": {"id": "current", "status": "completed"}}
        )
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"ab",
            max_audio_bytes=100,
            timeout_seconds=1,
            chunk_interval=0.001,
            observe_overlap=True,
            post_speech_seconds=0.02,
        )
        assert result["reader"]["reason"] == "remote_error"
        assert socket.sent.count("response.cancel") == 1
        assert "private detail" not in repr(result)

    asyncio.run(run())


def test_speech_end_must_match_started_item():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(audio(b"x"))
        socket.incoming.put_nowait({"type": "input_audio_buffer.speech_started", "item_id": "one"})
        socket.incoming.put_nowait({"type": "input_audio_buffer.speech_stopped", "item_id": "two"})
        socket.incoming.put_nowait(
            {"type": "response.done", "response": {"id": "current", "status": "completed"}}
        )
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"ab",
            max_audio_bytes=100,
            timeout_seconds=1,
            chunk_interval=0.001,
            observe_overlap=True,
            post_speech_seconds=0.02,
        )
        assert result["reader"]["reason"] == "invalid_speech_item"
        assert socket.sent.count("response.cancel") == 1

    asyncio.run(run())


def test_valid_speech_window_records_matching_item_and_no_remote_error():
    async def run():
        socket = Socket()
        socket.incoming.put_nowait(audio(b"x"))
        socket.incoming.put_nowait(
            {"type": "input_audio_buffer.speech_started", "item_id": "speech"}
        )
        socket.incoming.put_nowait(
            {"type": "input_audio_buffer.speech_stopped", "item_id": "speech"}
        )
        socket.incoming.put_nowait(
            {"type": "response.done", "response": {"id": "current", "status": "completed"}}
        )
        result = await module().supervise_overlap(
            socket,
            response_id="current",
            pcm=b"ab",
            max_audio_bytes=100,
            timeout_seconds=1,
            chunk_interval=0.001,
            observe_overlap=True,
            post_speech_seconds=0.02,
        )
        assert result["reader"]["speech_item_matched"] is True
        assert result["reader"]["remote_error_observed"] is False

    asyncio.run(run())
