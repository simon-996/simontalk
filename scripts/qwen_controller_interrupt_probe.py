"""Run one muted synthetic interruption against the real Dart media controller."""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import qwen_playback_probe as base
from qwen_overlap_probe_synthetic import make_synthetic_pcm
from qwen_webrtc_interrupt_probe import InterruptProbe, pcm_to_wav

from simontalk_api.qwen_webrtc_signalling import QwenWebRtcSettings

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "apps/client/build/web"
PAGE = b"""<!doctype html><meta charset="utf-8"><title>Controller interruption probe</title>
<style>button,pre,h1,p { position: relative; z-index: 10; }</style>
<h1>Controller interruption probe</h1><p>One exchange, synthetic audio, muted output.</p>
<button id="run">Run once</button><pre id="log">Ready</pre>
<script src="/realtime_transport.js"></script><script src="/controller.js"></script>
<script src="/flutter_bootstrap.js" async></script>"""


def make_handler(probe, wav):
    parent = base.make_handler(probe)

    class Handler(parent):
        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/":
                self._send(200, PAGE, "text/html; charset=utf-8")
            elif path == "/controller.js":
                self._send(
                    200,
                    (ROOT / "scripts/qwen_controller_interrupt_page.js").read_bytes(),
                    "text/javascript; charset=utf-8",
                )
            elif path == "/synthetic.wav":
                self._send(200, wav, "audio/wav")
            elif path in ("/realtime_transport.js", "/health"):
                super().do_GET()
            else:
                target = (WEB / path.lstrip("/")).resolve()
                if not target.is_relative_to(WEB.resolve()) or not target.is_file():
                    self._send(404, b"not found", "text/plain")
                    return
                self._send(
                    200,
                    target.read_bytes(),
                    mimetypes.guess_type(target.name)[0] or "application/octet-stream",
                )

    return Handler


def is_controller_bundle(path: Path) -> bool:
    try:
        contents = path.read_bytes()
    except OSError:
        return False
    return b"probe.waitForStart" in contents and b"probe.finished" in contents


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", required=True)
    parser.add_argument("--port", type=int, default=7391)
    parser.add_argument("--evidence", required=True)
    args = parser.parse_args()
    args.max_exchanges = 1
    env = base.load_env(base.ENV_FILE)
    key = os.environ.get("SIMONTALK_QWEN_API_KEY") or env.get("SIMONTALK_QWEN_API_KEY")
    workspace = os.environ.get("SIMONTALK_QWEN_WORKSPACE_ID") or env.get(
        "SIMONTALK_QWEN_WORKSPACE_ID"
    )
    if not key or not workspace or not is_controller_bundle(WEB / "main.dart.js"):
        print("Missing private configuration or compiled controller probe", file=sys.stderr)
        return 2
    try:
        wav = pcm_to_wav(make_synthetic_pcm())
        fd = os.open(args.evidence, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"status": "started_unknown"}, f)
    except (OSError, ValueError):
        print("Cannot prepare synthetic input or exclusive evidence", file=sys.stderr)
        return 2
    settings = QwenWebRtcSettings(
        workspace_id=workspace,
        model="qwen3.8-omni-flash-realtime",
        config_id=base.CONFIG_ID,
        api_key=key,
    )
    probe = InterruptProbe(args, settings)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(probe, wav))
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
