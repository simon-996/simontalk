"""Local safety tests for the Qwen TTS diagnostic; no provider calls."""

import asyncio
import importlib.util
import json
from pathlib import Path


def module():
    path = Path(__file__).resolve().parents[3] / "scripts" / "qwen_tts_timestamp_probe.py"
    assert path.is_file(), "TTS timestamp probe is missing"
    spec = importlib.util.spec_from_file_location("tts_probe", path)
    assert spec is not None and spec.loader is not None
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class Socket:
    def __init__(self, events):
        self.queue = asyncio.Queue()
        self.sent = []
        for event in events:
            self.queue.put_nowait(event if isinstance(event, bytes) else json.dumps(event))

    async def send(self, raw):
        self.sent.append(json.loads(raw))

    async def recv(self):
        return await self.queue.get()


def event(name, output=None, usage=None, task="target"):
    return {
        "header": {"event": name, "task_id": task},
        "payload": {"output": output, "usage": usage},
    }


def test_single_task_collects_bounded_pcm_word_times_and_usage():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", {"type": "sentence-synthesis"}),
                b"\x00" * 3200,
                event(
                    "result-generated",
                    {
                        "type": "sentence-end",
                        "original_text": "Hello.",
                        "sentence": {
                            "index": 0,
                            "words": [
                                {
                                    "text": "Hello.",
                                    "begin_index": 0,
                                    "end_index": 5,
                                    "begin_time": 0,
                                    "end_time": 90,
                                }
                            ],
                        },
                    },
                ),
                event("task-finished", usage={"characters": 6}),
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hello.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert [x["header"]["action"] for x in socket.sent] == [
            "run-task",
            "continue-task",
            "finish-task",
        ]
        assert result["reason"] == "task_finished"
        assert result["audio_bytes"] == 3200
        assert result["words"][0]["end_time"] == 90
        assert result["usage_characters"] == 6
        assert result["timestamp_range_valid"] is True
        assert result["audio_saved"] is False

    asyncio.run(run())


def test_unexpected_task_id_cancels_once_and_never_accepts_foreign_terminal():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("task-finished", usage={"characters": 6}, task="other"),
                event("task-finished", usage={"characters": 0}),
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hello.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert result["reason"] == "foreign_task"
        assert result["usage_characters"] == 0
        assert [
            x["payload"]["input"].get("directive")
            for x in socket.sent
            if x["header"]["action"] == "finish-task"
        ] == [None, "cancel"]

    asyncio.run(run())


def test_audio_limit_cancels_once_and_usage_stays_unknown_if_no_terminal():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", {"type": "sentence-synthesis"}),
                b"123456",
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hello.", timeout_seconds=0.04, max_audio_bytes=4
        )
        assert result["reason"] == "audio_limit"
        assert result["usage_characters"] is None
        assert (
            sum(
                x["payload"]["input"].get("directive") == "cancel"
                for x in socket.sent
                if x["header"]["action"] == "finish-task"
            )
            == 1
        )

    asyncio.run(run())


def test_external_cancellation_attempts_one_task_cancel():
    async def run():
        socket = Socket([event("task-started")])
        task = asyncio.create_task(
            module().probe(
                socket, task_id="target", text="Hello.", timeout_seconds=1, max_audio_bytes=5000
            )
        )
        while len(socket.sent) < 3:
            await asyncio.sleep(0)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("Cancellation must propagate")
        actions = [
            x
            for x in socket.sent
            if x["header"]["action"] == "finish-task"
            and x["payload"]["input"].get("directive") == "cancel"
        ]
        assert len(actions) == 1

    asyncio.run(run())


def test_duplicate_sentence_results_are_not_merged():
    async def run():
        output = {
            "type": "sentence-end",
            "original_text": "Hi.",
            "sentence": {
                "index": 0,
                "words": [
                    {
                        "text": "Hi.",
                        "begin_index": 0,
                        "end_index": 1,
                        "begin_time": 0,
                        "end_time": 10,
                    }
                ],
            },
        }
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", output),
                event("result-generated", output),
                event("task-finished", usage={"characters": 3}),
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hi.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert result["reason"] == "duplicate_sentence"
        assert len(result["sentences"]) == 1 and len(result["words"]) == 1

    asyncio.run(run())


def test_cli_never_connects_without_explicit_run_and_new_output():
    import subprocess
    import sys

    path = Path(__file__).resolve().parents[3] / "scripts" / "qwen_tts_timestamp_probe.py"
    result = subprocess.run([sys.executable, str(path)], capture_output=True, timeout=5)
    assert result.returncode != 0
    assert b"--run" in result.stderr and b"--output" in result.stderr


def test_aborted_task_never_sends_text_after_late_task_started():
    async def run():
        socket = Socket(
            [
                event("task-started", task="other"),
                event("task-started"),
                event("task-finished", usage={"characters": 0}),
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hello.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert result["reason"] == "foreign_task"
        assert result["text_sent"] is False
        assert [x["header"]["action"] for x in socket.sent] == ["run-task", "finish-task"]
        assert socket.sent[-1]["payload"]["input"]["directive"] == "cancel"

    asyncio.run(run())


def test_result_before_task_started_is_never_sent_text():
    async def run():
        socket = Socket(
            [
                event("result-generated", {"type": "sentence-synthesis"}),
                event("task-started"),
                event("task-finished", usage={"characters": 0}),
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hello.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert result["reason"] == "invalid_event_order"
        assert result["text_sent"] is False
        assert not any(x["header"]["action"] == "continue-task" for x in socket.sent)

    asyncio.run(run())


def test_finished_with_pending_binary_is_not_a_valid_result():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", {"type": "sentence-synthesis"}),
                event("task-finished", usage={"characters": 6}),
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hello.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert result["reason"] == "incomplete_audio_frame"
        assert result["task_terminal"] is True

    asyncio.run(run())


def test_unexpected_provider_text_never_enters_result():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event(
                    "result-generated",
                    {
                        "type": "sentence-end",
                        "original_text": "private-value",
                        "sentence": {
                            "index": 0,
                            "words": [
                                {
                                    "text": "private-value",
                                    "begin_index": 0,
                                    "end_index": 1,
                                    "begin_time": 0,
                                    "end_time": 10,
                                }
                            ],
                        },
                    },
                ),
                event("task-finished", usage={"characters": 6}),
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hello.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert result["reason"] == "invalid_sentence"
        assert "private-value" not in repr(result)
        assert result["words"] == [] and result["sentences"] == []

    asyncio.run(run())


def test_unexpected_word_text_never_enters_result():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event(
                    "result-generated",
                    {
                        "type": "sentence-end",
                        "original_text": "Hello.",
                        "sentence": {
                            "index": 0,
                            "words": [
                                {
                                    "text": "private-value",
                                    "begin_index": 0,
                                    "end_index": 1,
                                    "begin_time": 0,
                                    "end_time": 10,
                                }
                            ],
                        },
                    },
                ),
                event("task-finished", usage={"characters": 6}),
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hello.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert result["reason"] == "invalid_sentence"
        assert "private-value" not in repr(result)
        assert result["words"] == []

    asyncio.run(run())


def test_duplicate_task_started_does_not_produce_a_valid_observation():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("task-started"),
                event("task-finished", usage={"characters": 6}),
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hello.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert result["reason"] == "duplicate_task_started"
        assert sum(x["header"]["action"] == "continue-task" for x in socket.sent) == 1
        assert (
            sum(
                x["payload"]["input"].get("directive") == "cancel"
                for x in socket.sent
                if x["header"]["action"] == "finish-task"
            )
            == 1
        )

    asyncio.run(run())


def test_word_timestamps_must_fit_received_pcm_duration():
    async def run():
        ending = {
            "type": "sentence-end",
            "original_text": "Hi.",
            "sentence": {
                "index": 0,
                "words": [
                    {
                        "text": "Hi.",
                        "begin_index": 0,
                        "end_index": 1,
                        "begin_time": 0,
                        "end_time": 10,
                    }
                ],
            },
        }
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", {"type": "sentence-synthesis"}),
                b"\0\0",
                event("result-generated", ending),
                event("task-finished", usage={"characters": 3}),
            ]
        )
        result = await module().probe(
            socket, task_id="target", text="Hi.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert result["reason"] == "task_finished"
        assert result["timestamp_range_valid"] is False

    asyncio.run(run())


def test_failed_text_send_is_recorded_as_attempted_and_unknown():
    async def run():
        class UncertainSend(Socket):
            async def send(self, raw):
                item = json.loads(raw)
                if item["header"]["action"] == "continue-task":
                    raise OSError("private detail")
                await super().send(raw)

        socket = UncertainSend([event("task-started")])
        result = await module().probe(
            socket, task_id="target", text="Hello.", timeout_seconds=1, max_audio_bytes=5000
        )
        assert result["reason"] == "transport_failed"
        assert result["text_send_attempted"] is True
        assert result["text_sent"] is False
        assert result["usage_characters"] is None
        assert "private detail" not in repr(result)

    asyncio.run(run())


def test_cancels_after_first_audio_and_waits_for_terminal_and_quiet_window():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", {"type": "sentence-synthesis"}),
                b"\0" * 3200,
                event("task-finished", usage={"characters": 6}),
            ]
        )
        result = await module().probe(
            socket,
            task_id="target",
            text="Hello.",
            timeout_seconds=1,
            max_audio_bytes=5000,
            cancel_on_first_audio=True,
            post_terminal_seconds=0.02,
        )
        actions = [x["header"]["action"] for x in socket.sent]
        assert actions == ["run-task", "continue-task", "finish-task"]
        assert socket.sent[-1]["payload"]["input"]["directive"] == "cancel"
        assert result["reason"] == "cancel_requested" and result["cancel_sent"] is True
        assert result["task_terminal"] is True and result["usage_characters"] == 6
        assert result["post_terminal_window_complete"] is True
        assert result["post_terminal_audio_bytes"] == 0

    asyncio.run(run())


def test_audio_after_terminal_is_recorded_not_treated_as_quiet():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", {"type": "sentence-synthesis"}),
                b"\0" * 3200,
                event("task-finished", usage={"characters": 6}),
                b"late",
            ]
        )
        result = await module().probe(
            socket,
            task_id="target",
            text="Hello.",
            timeout_seconds=1,
            max_audio_bytes=5000,
            cancel_on_first_audio=True,
            post_terminal_seconds=0.02,
        )
        assert result["post_terminal_audio_bytes"] == 4
        assert result["post_terminal_window_complete"] is True
        assert result["post_terminal_quiet"] is False

    asyncio.run(run())


def test_audio_after_cancel_still_obeys_receive_limit():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", {"type": "sentence-synthesis"}),
                b"1234",
                b"5678",
            ]
        )
        result = await module().probe(
            socket,
            task_id="target",
            text="Hello.",
            timeout_seconds=1,
            max_audio_bytes=6,
            cancel_on_first_audio=True,
            post_terminal_seconds=0.02,
        )
        assert result["reason"] == "audio_limit_after_cancel"
        assert result["task_terminal"] is False and result["usage_characters"] is None
        assert (
            sum(
                x["payload"]["input"].get("directive") == "cancel"
                for x in socket.sent
                if x["header"]["action"] == "finish-task"
            )
            == 1
        )

    asyncio.run(run())


def test_post_terminal_audio_limit_counts_all_previously_received_bytes():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", {"type": "sentence-synthesis"}),
                b"1234",
                event("task-finished", usage={"characters": 6}),
                b"567",
            ]
        )
        result = await module().probe(
            socket,
            task_id="target",
            text="Hello.",
            timeout_seconds=1,
            max_audio_bytes=6,
            cancel_on_first_audio=True,
            post_terminal_seconds=0.02,
        )
        assert result["post_terminal_audio_bytes"] == 3
        assert result["post_terminal_window_complete"] is False
        assert result["post_terminal_quiet"] is False

    asyncio.run(run())


def test_empty_audio_does_not_count_as_first_audio_for_cancellation():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", {"type": "sentence-synthesis"}),
                b"",
                event("task-finished", usage={"characters": 0}),
            ]
        )
        result = await module().probe(
            socket,
            task_id="target",
            text="Hello.",
            timeout_seconds=1,
            max_audio_bytes=6,
            cancel_on_first_audio=True,
            post_terminal_seconds=0.02,
        )
        assert result["reason"] == "empty_audio_frame"
        assert result["audio_bytes"] == 0

    asyncio.run(run())


def test_empty_post_terminal_frame_is_activity_not_quiet():
    async def run():
        socket = Socket(
            [
                event("task-started"),
                event("result-generated", {"type": "sentence-synthesis"}),
                b"1234",
                event("task-finished", usage={"characters": 6}),
                b"",
            ]
        )
        result = await module().probe(
            socket,
            task_id="target",
            text="Hello.",
            timeout_seconds=1,
            max_audio_bytes=6,
            cancel_on_first_audio=True,
            post_terminal_seconds=0.02,
        )
        assert result["post_terminal_audio_frames"] == 1
        assert result["post_terminal_quiet"] is False

    asyncio.run(run())
