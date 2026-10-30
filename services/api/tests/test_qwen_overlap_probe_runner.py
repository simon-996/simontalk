"""Locally test the one-shot diagnostic runner; all transport is fake."""

import asyncio
import importlib.util
import json
from pathlib import Path


def module():
    script = Path(__file__).resolve().parents[3] / "scripts" / "qwen_overlap_probe_runner.py"
    assert script.is_file(), "One-shot runner is missing"
    spec = importlib.util.spec_from_file_location("overlap_runner", script)
    assert spec is not None and spec.loader is not None
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def test_runner_creates_private_result_and_runs_only_once(tmp_path):
    async def run():
        path = tmp_path / "result.json"
        events = []

        async def connect():
            events.append("connect")
            return object()

        async def execute(socket, *, pcm):
            events.append("execute")
            assert pcm == b"ab"
            return {"reason": "test_result", "close_received": None}

        result = await module().run_once(
            path, synthesize=lambda: b"ab", connect=connect, execute=execute
        )
        assert events == ["connect", "execute"]
        assert result["reason"] == "session_returned"
        assert json.loads(path.read_text()) == result
        assert path.stat().st_mode & 0o777 == 0o600

    asyncio.run(run())


def test_existing_result_prevents_synthesis_and_connection(tmp_path):
    async def run():
        path = tmp_path / "result.json"
        path.write_text("existing")
        events = []

        async def connect():
            events.append("connect")

        try:
            await module().run_once(
                path, synthesize=lambda: events.append("audio"), connect=connect, execute=None
            )
        except FileExistsError:
            pass
        else:
            raise AssertionError("existing result must not be overwritten")
        assert not events and path.read_text() == "existing"

    asyncio.run(run())


def test_connection_failure_is_sanitized_and_not_retried(tmp_path):
    async def run():
        events = []

        async def connect():
            events.append("connect")
            raise OSError("private credential detail")

        path = tmp_path / "result.json"
        result = await module().run_once(
            path, synthesize=lambda: b"ab", connect=connect, execute=None
        )
        assert result["reason"] == "connect_failed"
        assert events == ["connect"]
        assert "private credential detail" not in path.read_text()
        assert result["session"] is None

    asyncio.run(run())


def test_cli_requires_explicit_run_and_exclusive_output():
    import subprocess
    import sys

    script = Path(__file__).resolve().parents[3] / "scripts" / "qwen_overlap_probe_runner.py"
    result = subprocess.run([sys.executable, str(script)], capture_output=True, timeout=5)
    assert result.returncode != 0
    assert b"--run" in result.stderr and b"--output" in result.stderr


def test_observation_valid_requires_overlap_complete_and_peer_close():
    assess = module().observation_valid
    good = {
        "reason": "supervision_returned",
        "close_sent": 1000,
        "close_received": 1000,
        "overlap": {
            "reason": "reader_finished",
            "feeder_stopped": True,
            "input_complete": True,
            "input_chunks_sent": 1,
            "reader": {
                "reason": "overlap_window_observed",
                "response_status": "completed",
                "speech_started_before_done": True,
                "speech_stopped": True,
                "speech_item_matched": True,
                "remote_error_observed": False,
                "cancel_sent": False,
                "stop_feeding_failed": False,
                "usage": {"input_tokens": 12, "output_tokens": 5, "total_tokens": 17},
            },
        },
    }
    assert assess(good)
    good["close_received"] = None
    assert not assess(good)
    good["close_received"] = 1000
    good["overlap"]["input_complete"] = False
    assert not assess(good)
    good["overlap"]["input_complete"] = True
    good["overlap"]["reader"]["speech_started_before_done"] = False
    assert not assess(good)
    assert not assess(None)


def test_external_cancellation_closes_acquired_socket_and_keeps_unknown(tmp_path):
    async def run():
        started = asyncio.Event()
        closed = []

        class Socket:
            async def close(self, *, code):
                closed.append(code)

        async def connect():
            return Socket()

        async def execute(socket, *, pcm):
            started.set()
            await asyncio.Event().wait()

        output = tmp_path / "unknown.json"
        task = asyncio.create_task(
            module().run_once(output, synthesize=lambda: b"ab", connect=connect, execute=execute)
        )
        await started.wait()
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("Cancellation must propagate")
        assert closed == [1000]
        assert json.loads(output.read_text())["reason"] == "started_unknown"

    asyncio.run(run())
