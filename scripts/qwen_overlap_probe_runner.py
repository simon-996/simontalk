"""Single-attempt orchestration; importing this module never connects to Qwen."""

import asyncio
import json
import os
from datetime import UTC, datetime


def observation_valid(session):
    if not isinstance(session, dict) or session.get("reason") != "supervision_returned":
        return False
    overlap = session.get("overlap")
    if not isinstance(overlap, dict):
        return False
    reader = overlap.get("reader")
    if not isinstance(reader, dict):
        return False
    usage = reader.get("usage")
    return (
        session.get("close_sent") == 1000
        and session.get("close_received") == 1000
        and overlap.get("reason") == "reader_finished"
        and overlap.get("feeder_stopped") is True
        and overlap.get("input_complete") is True
        and type(overlap.get("input_chunks_sent")) is int
        and overlap["input_chunks_sent"] > 0
        and reader.get("reason") == "overlap_window_observed"
        and reader.get("response_status") == "completed"
        and reader.get("speech_started_before_done") is True
        and reader.get("speech_stopped") is True
        and reader.get("speech_item_matched") is True
        and reader.get("remote_error_observed") is False
        and reader.get("cancel_sent") is False
        and reader.get("stop_feeding_failed") is False
        and isinstance(usage, dict)
        and all(
            type(usage.get(key)) is int and usage[key] >= 0
            for key in ("input_tokens", "output_tokens", "total_tokens")
        )
    )


async def run_once(output, *, synthesize, connect, execute):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(output, flags, 0o600)
    result = {
        "started_at_utc": datetime.now(UTC).isoformat(),
        "reason": "started_unknown",
        "connection_attempted": False,
        "session": None,
    }
    socket = None

    with os.fdopen(fd, "w", encoding="utf-8") as report:

        def persist():
            report.seek(0)
            json.dump(result, report, ensure_ascii=False, indent=2)
            report.write("\n")
            report.truncate()
            report.flush()
            os.fsync(report.fileno())

        persist()
        try:
            try:
                pcm = await asyncio.to_thread(synthesize)
                if type(pcm) is not bytes or not pcm or len(pcm) > 320_000 or len(pcm) % 2:
                    raise ValueError("Invalid synthetic input")
            except Exception:
                result["reason"] = "synthetic_input_failed"
                return result
            result["connection_attempted"] = True
            persist()
            try:
                socket = await asyncio.wait_for(connect(), timeout=8)
            except Exception:
                result["reason"] = "connect_failed"
                return result
            try:
                result["session"] = await execute(socket, pcm=pcm)
            except asyncio.CancelledError:
                try:
                    await asyncio.wait_for(socket.close(code=1000), 6)
                except Exception:
                    pass
                raise
            except Exception:
                result["reason"] = "session_failed_unknown"
                try:
                    await asyncio.wait_for(socket.close(code=1000), 6)
                except Exception:
                    pass
                return result
            result["reason"] = "session_returned"
            return result
        finally:
            persist()


def main():
    import argparse
    import re
    import sys
    from pathlib import Path

    parser = argparse.ArgumentParser(description="One bounded, billable Qwen overlap experiment")
    parser.add_argument("--run", action="store_true", required=True, help="start one experiment")
    parser.add_argument("--output", required=True, help="new private JSON result file")
    args = parser.parse_args()

    from qwen_overlap_probe_session import execute_session
    from qwen_overlap_probe_synthetic import make_synthetic_pcm

    root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(root / "services" / "api" / "src"))

    async def open_socket():
        from simontalk_api.qwen_config import load_qwen_realtime_settings
        from simontalk_api.qwen_websocket import no_redirect_connect

        settings = load_qwen_realtime_settings(env_file=root / "services" / "api" / ".env")
        if not re.fullmatch(r"llm-[a-z0-9]{1,64}", settings.workspace_id):
            raise ValueError("Invalid workspace")
        url = (
            f"wss://{settings.workspace_id}.cn-beijing.maas.aliyuncs.com"
            "/api-ws/v1/realtime?model=qwen3.8-omni-flash-realtime"
        )
        return await no_redirect_connect(
            url,
            additional_headers={"Authorization": "Bearer " + settings.api_key},
            open_timeout=7,
            close_timeout=5,
            max_size=128 * 1024,
            compression=None,
            proxy=None,
            ping_interval=None,
        )

    try:
        outcome = asyncio.run(
            run_once(
                args.output,
                synthesize=make_synthetic_pcm,
                connect=open_socket,
                execute=execute_session,
            )
        )
    except (OSError, ValueError):
        print("Unable to create or write diagnostic result", file=sys.stderr)
        return 1
    valid = observation_valid(outcome["session"])
    print(
        json.dumps(
            {
                "reason": outcome["reason"],
                "connection_attempted": outcome["connection_attempted"],
                "observation_valid": valid,
            }
        )
    )
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
