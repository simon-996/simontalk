"""One bounded WebRTC interruption experiment with synthetic speech and muted output."""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import wave
from datetime import UTC, datetime
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import qwen_playback_probe as base
from qwen_overlap_probe_synthetic import make_synthetic_pcm
from simontalk_api.qwen_webrtc_signalling import QwenWebRtcSettings

PAGE_JS = (Path(__file__).parent / "qwen_webrtc_interrupt_page.js").read_text()
PAGE = """<!doctype html><meta charset="utf-8"><title>千问 WebRTC 插话实验</title>
<h1>千问 WebRTC 插话实验</h1><p>一次真实交换和回复。输入为固定合成语音，输出静音；不使用物理麦克风。</p>
<button id="run">运行一次</button><pre id="log">尚未运行</pre>
<script src="/realtime_transport.js"></script><script src="/interrupt.js"></script>"""


def pcm_to_wav(pcm: bytes) -> bytes:
    if type(pcm) is not bytes or not pcm or len(pcm) > 320_000 or len(pcm) % 2:
        raise ValueError("Invalid synthetic input")
    stream = io.BytesIO()
    with wave.open(stream, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(pcm)
    return stream.getvalue()


class InterruptProbe(base.Probe):
    def record(self, payload: dict) -> None:
        with self.lock:
            self.observations.append(
                {"received_at": datetime.now(UTC).isoformat(), **payload}
            )
            document = {
                "tool": "qwen-webrtc-interrupt-probe",
                "started_at": self.started_at,
                "model": self.settings.model,
                "transport_sha256": self.transport_sha,
                "exchanges_used": self.exchanges,
                "observations": self.observations,
                "boundary": "Synthetic speech, muted output, one exchange and no automatic retry; local close does not prove upstream termination or billing stop.",
            }
            self.evidence_path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n"
            )


def make_handler(probe: InterruptProbe, synthetic_wav: bytes):
    parent = base.make_handler(probe)

    class Handler(parent):
        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/":
                self._send(200, PAGE.encode(), "text/html; charset=utf-8")
            elif path == "/synthetic.wav":
                self._send(200, synthetic_wav, "audio/wav")
            elif path == "/interrupt.js":
                self._send(200, PAGE_JS.encode(), "text/javascript; charset=utf-8")
            else:
                super().do_GET()

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", required=True)
    parser.add_argument("--port", type=int, default=7391)
    parser.add_argument("--evidence", required=True)
    args = parser.parse_args()
    args.max_exchanges = 1
    args.model = "qwen3.8-omni-flash-realtime"
    env = base.load_env(base.ENV_FILE)
    key = os.environ.get("SIMONTALK_QWEN_API_KEY") or env.get("SIMONTALK_QWEN_API_KEY")
    workspace = os.environ.get("SIMONTALK_QWEN_WORKSPACE_ID") or env.get(
        "SIMONTALK_QWEN_WORKSPACE_ID"
    )
    if not key or not workspace:
        print("Missing private Qwen configuration", file=sys.stderr)
        return 2
    try:
        audio = pcm_to_wav(make_synthetic_pcm())
        path = Path(args.evidence)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as file:
            file.write('{"status":"started_unknown"}\n')
    except (OSError, ValueError):
        print("Cannot prepare synthetic input or exclusive evidence", file=sys.stderr)
        return 2
    settings = QwenWebRtcSettings(
        workspace_id=workspace, model=args.model, config_id=base.CONFIG_ID, api_key=key
    )
    probe = InterruptProbe(args, settings)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(probe, audio))
    print(f"transport sha256: {probe.transport_sha}", flush=True)
    print(f"open http://127.0.0.1:{args.port}/ (one exchange)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
