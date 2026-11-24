"""Single-task, bounded Qwen TTS timestamp probe; no connection at import."""

import asyncio
import json
import time

MODEL = "qwen-audio-3.0-tts-flash"
VOICE = "longanfengyue"
TEXT = "Hello there. What do you like to do on a sunny afternoon?"


def _matches_fixed_text(text, pieces):
    cursor = 0
    for piece in pieces:
        for char in piece:
            if (
                cursor < len(text)
                and text[cursor] != char
                and text[cursor].isspace()
                and not char.isspace()
                and cursor > 0
                and text[cursor - 1] in ".,!?;:"
            ):
                while cursor < len(text) and text[cursor].isspace():
                    cursor += 1
            if cursor >= len(text) or text[cursor] != char:
                return False
            cursor += 1
    return cursor == len(text) or text[cursor:].isspace()


async def probe(
    socket,
    *,
    task_id,
    text,
    timeout_seconds=20,
    max_audio_bytes=960_000,
    cancel_on_first_audio=False,
    post_terminal_seconds=3,
):
    if type(text) is not str or not 0 < len(text) <= 200:
        raise ValueError("Invalid synthetic text")
    if type(task_id) is not str or not task_id:
        raise ValueError("Invalid task ID")
    if type(timeout_seconds) not in (int, float) or not 0 < timeout_seconds <= 30:
        raise ValueError("Invalid timeout")
    if type(max_audio_bytes) is not int or not 0 < max_audio_bytes <= 960_000:
        raise ValueError("Invalid audio limit")
    if (
        type(cancel_on_first_audio) is not bool
        or type(post_terminal_seconds) not in (int, float)
        or not 0 < post_terminal_seconds <= 5
    ):
        raise ValueError("Invalid cancellation observation")

    result = {
        "reason": None,
        "task_started": False,
        "text_send_attempted": False,
        "text_sent": False,
        "audio_bytes": 0,
        "audio_frames": 0,
        "audio_saved": False,
        "cancel_sent": False,
        "task_terminal": False,
        "usage_characters": None,
        "first_audio_ms": None,
        "sentence_end_ms": [],
        "sentences": [],
        "words": [],
        "timestamp_range_valid": None,
        "audio_bytes_after_cancel": 0,
        "post_terminal_audio_bytes": 0,
        "post_terminal_audio_frames": 0,
        "post_terminal_events": 0,
        "post_terminal_window_complete": False,
        "post_terminal_quiet": None,
    }
    started_at = time.monotonic()
    cancel_attempted = False
    expecting_binary = False

    async def send(action, value):
        payload = {
            "header": {"action": action, "task_id": task_id, "streaming": "duplex"},
            "payload": value,
        }
        await asyncio.wait_for(socket.send(json.dumps(payload)), 0.5)

    async def abort(reason):
        nonlocal cancel_attempted
        if result["reason"] is None:
            result["reason"] = reason
        if not cancel_attempted:
            cancel_attempted = True
            try:
                await send("finish-task", {"input": {"directive": "cancel"}})
                result["cancel_sent"] = True
            except Exception:
                pass

    try:
        async with asyncio.timeout(timeout_seconds):
            await send(
                "run-task",
                {
                    "task_group": "audio",
                    "task": "tts",
                    "function": "SpeechSynthesizer",
                    "model": MODEL,
                    "parameters": {
                        "text_type": "PlainText",
                        "voice": VOICE,
                        "format": "pcm",
                        "sample_rate": 16000,
                        "word_timestamp_enabled": True,
                    },
                    "input": {},
                },
            )
            for _ in range(800):
                raw = await socket.recv()
                if isinstance(raw, bytes):
                    if result["reason"] == "cancel_requested":
                        result["audio_bytes_after_cancel"] += len(raw)
                        if (
                            result["audio_bytes"] + result["audio_bytes_after_cancel"]
                            > max_audio_bytes
                        ):
                            result["reason"] = "audio_limit_after_cancel"
                            return result
                        continue
                    if not expecting_binary:
                        await abort("unexpected_audio")
                        continue
                    expecting_binary = False
                    if not raw:
                        await abort("empty_audio_frame")
                        continue
                    result["audio_bytes"] += len(raw)
                    result["audio_frames"] += 1
                    if result["first_audio_ms"] is None:
                        result["first_audio_ms"] = round((time.monotonic() - started_at) * 1000, 1)
                    if result["audio_bytes"] > max_audio_bytes:
                        await abort("audio_limit")
                    elif cancel_on_first_audio and result["reason"] is None:
                        await abort("cancel_requested")
                    continue
                try:
                    event = json.loads(raw)
                    header = event["header"]
                    name = header["event"]
                    if header.get("task_id") != task_id:
                        await abort("foreign_task")
                        continue
                    if result["reason"] is not None and name not in {
                        "task-finished",
                        "task-failed",
                    }:
                        continue
                    if name == "result-generated" and not result["text_sent"]:
                        await abort("invalid_event_order")
                        continue
                    if name == "task-started" and result["task_started"]:
                        await abort("duplicate_task_started")
                        continue
                    if name == "task-started" and not result["task_started"]:
                        result["task_started"] = True
                        result["text_send_attempted"] = True
                        await send("continue-task", {"input": {"text": text}})
                        result["text_sent"] = True
                        if not cancel_on_first_audio:
                            await send("finish-task", {"input": {}})
                    elif name == "result-generated":
                        output = event.get("payload", {}).get("output") or {}
                        kind = output.get("type")
                        if kind == "sentence-synthesis":
                            if expecting_binary:
                                await abort("missing_audio_frame")
                            expecting_binary = True
                        elif kind == "sentence-end":
                            sentence = output.get("sentence") or {}
                            words = sentence.get("words")
                            original = output.get("original_text")
                            index = sentence.get("index")
                            if result["sentences"]:
                                await abort("duplicate_sentence")
                                continue
                            if original != text or type(index) is not int or index != 0:
                                await abort("invalid_sentence")
                                continue
                            if type(words) is not list or not 0 < len(words) <= 200:
                                await abort("invalid_sentence")
                                continue
                            clean_words = []
                            for word in words:
                                keys = ("begin_index", "end_index", "begin_time", "end_time")
                                if (
                                    type(word) is not dict
                                    or type(word.get("text")) is not str
                                    or len(word["text"]) > 100
                                    or any(
                                        type(word.get(k)) is not int or not 0 <= word[k] <= 100_000
                                        for k in keys
                                    )
                                ):
                                    raise ValueError()
                                clean_words.append(
                                    {
                                        "sentence_index": index,
                                        **{key: word[key] for key in ("text", *keys)},
                                    }
                                )
                            if not _matches_fixed_text(
                                text, [word["text"] for word in clean_words]
                            ):
                                await abort("invalid_sentence")
                                continue
                            result["sentences"].append(original)
                            result["sentence_end_ms"].append(
                                round((time.monotonic() - started_at) * 1000, 1)
                            )
                            result["words"] = clean_words
                    elif name == "task-finished":
                        usage = event.get("payload", {}).get("usage") or {}
                        chars = usage.get("characters")
                        if type(chars) is int and 0 <= chars <= 200_000:
                            result["usage_characters"] = chars
                        result["task_terminal"] = True
                        duration_ms = result["audio_bytes"] * 1000 // 32_000
                        last_end = 0
                        range_valid = bool(result["words"]) and result["audio_bytes"] % 2 == 0
                        for word in result["words"]:
                            if not (
                                last_end <= word["begin_time"] < word["end_time"] <= duration_ms
                            ):
                                range_valid = False
                            last_end = word["end_time"]
                        result["timestamp_range_valid"] = range_valid
                        if result["reason"] is None:
                            result["reason"] = (
                                "incomplete_audio_frame"
                                if expecting_binary
                                else "invalid_event_order"
                                if not result["text_sent"]
                                else "task_finished"
                            )
                        if result["reason"] == "cancel_requested":
                            deadline = asyncio.get_running_loop().time() + post_terminal_seconds
                            for _ in range(100):
                                remaining = deadline - asyncio.get_running_loop().time()
                                if remaining <= 0:
                                    result["post_terminal_window_complete"] = True
                                    break
                                try:
                                    later = await asyncio.wait_for(socket.recv(), remaining)
                                except TimeoutError:
                                    result["post_terminal_window_complete"] = True
                                    break
                                if isinstance(later, bytes):
                                    result["post_terminal_audio_frames"] += 1
                                    result["post_terminal_audio_bytes"] += len(later)
                                    if (
                                        result["audio_bytes"]
                                        + result["audio_bytes_after_cancel"]
                                        + result["post_terminal_audio_bytes"]
                                        > max_audio_bytes
                                    ):
                                        break
                                else:
                                    result["post_terminal_events"] += 1
                            result["post_terminal_quiet"] = (
                                result["post_terminal_window_complete"]
                                and result["post_terminal_audio_frames"] == 0
                                and result["post_terminal_events"] == 0
                            )
                        return result
                    elif name == "task-failed":
                        result["task_terminal"] = True
                        result["reason"] = result["reason"] or "task_failed"
                        return result
                except (ValueError, TypeError, KeyError, AttributeError):
                    await abort("invalid_event")
            await abort("event_limit")
    except TimeoutError:
        await abort("timeout")
    except asyncio.CancelledError:
        await abort("cancelled")
        raise
    except Exception:
        await abort("transport_failed")
    return result


def main():
    import argparse
    import os
    import re
    import sys
    from datetime import UTC, datetime
    from pathlib import Path
    from uuid import uuid4

    parser = argparse.ArgumentParser(description="One bounded, billable TTS timestamp experiment")
    parser.add_argument("--run", action="store_true", required=True)
    parser.add_argument("--output", required=True, help="new private result file")
    parser.add_argument("--cancel-after-audio", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(root / "services" / "api" / "src"))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(args.output, flags, 0o600)
    except OSError:
        print("Unable to create diagnostic result", file=sys.stderr)
        return 1
    result = {
        "started_at_utc": datetime.now(UTC).isoformat(),
        "probe_version": "tts-timestamp-v2",
        "model": MODEL,
        "voice": VOICE,
        "sample_rate": 16000,
        "synthetic_text": TEXT,
        "cancel_after_audio": args.cancel_after_audio,
        "connection_attempted": False,
        "connection_opened": False,
        "result": None,
        "close_sent": None,
        "close_received": None,
        "reason": "started_unknown",
    }

    with os.fdopen(descriptor, "w", encoding="utf-8") as report:

        def persist():
            report.seek(0)
            json.dump(result, report, ensure_ascii=False, indent=2)
            report.write("\n")
            report.truncate()
            report.flush()
            os.fsync(report.fileno())

        async def run():
            socket = None
            try:
                from simontalk_api.qwen_config import load_qwen_realtime_settings
                from simontalk_api.qwen_websocket import no_redirect_connect

                settings = load_qwen_realtime_settings(env_file=root / "services" / "api" / ".env")
                if not re.fullmatch(r"llm-[a-z0-9]{1,64}", settings.workspace_id):
                    raise ValueError("Invalid workspace")
                url = f"wss://{settings.workspace_id}.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
                result["connection_attempted"] = True
                persist()
                socket = await no_redirect_connect(
                    url,
                    additional_headers={"Authorization": "Bearer " + settings.api_key},
                    open_timeout=7,
                    close_timeout=5,
                    max_size=128 * 1024,
                    compression=None,
                    proxy=None,
                    ping_interval=None,
                )
                result["connection_opened"] = True
                result["result"] = await probe(
                    socket,
                    task_id=str(uuid4()),
                    text=TEXT,
                    cancel_on_first_audio=args.cancel_after_audio,
                )
                result["reason"] = "probe_returned"
            except Exception:
                result["reason"] = "connection_or_probe_failed"
            finally:
                if socket is not None:
                    try:
                        await asyncio.wait_for(socket.close(code=1000), 6)
                    except Exception:
                        pass
                    for name, field in (
                        ("close_sent", "close_sent"),
                        ("close_received", "close_rcvd"),
                    ):
                        code = getattr(getattr(socket.protocol, field, None), "code", None)
                        if type(code) is int:
                            result[name] = code

        try:
            persist()
            asyncio.run(run())
        finally:
            persist()
    outcome = result["result"] or {}
    ok = (
        outcome.get("reason") == "task_finished"
        and outcome.get("task_started") is True
        and outcome.get("text_sent") is True
        and outcome.get("audio_bytes", 0) > 0
        and bool(outcome.get("words"))
        and outcome.get("timestamp_range_valid") is True
        and outcome.get("usage_characters") is not None
        and result["close_sent"] == result["close_received"] == 1000
    )
    cancellation_observed = (
        args.cancel_after_audio
        and outcome.get("reason") == "cancel_requested"
        and outcome.get("cancel_sent") is True
        and outcome.get("audio_bytes", 0) > 0
        and outcome.get("task_terminal") is True
        and outcome.get("post_terminal_window_complete") is True
        and outcome.get("post_terminal_quiet") is True
        and result["close_sent"] == result["close_received"] == 1000
    )
    print(
        json.dumps(
            {
                "reason": result["reason"],
                "task_status": outcome.get("reason"),
                "basic_observation": ok,
                "cancellation_observed": cancellation_observed,
            }
        )
    )
    return 0 if ok or cancellation_observed else 1


if __name__ == "__main__":
    raise SystemExit(main())
