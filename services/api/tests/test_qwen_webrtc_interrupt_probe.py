import http.client
import importlib
import io
import json
import subprocess
import sys
import threading
import wave
from argparse import Namespace
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))


def load():
    return importlib.import_module("qwen_webrtc_interrupt_probe")


def test_fixed_synthetic_wav_is_valid_and_bounded():
    module = load()
    wav_data = module.pcm_to_wav(b"\x00\x00\x01\x00" * 8000)
    with wave.open(io.BytesIO(wav_data), "rb") as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 16000)
        assert wav.getnframes() == 16000
    for invalid in (b"", b"x", b"\0" * 320002):
        with pytest.raises(ValueError):
            module.pcm_to_wav(invalid)


def test_one_exchange_is_enforced_and_evidence_never_claims_remote_release(tmp_path):
    module = load()
    from simontalk_api.qwen_webrtc_signalling import QwenWebRtcSettings

    class Gateway:
        calls = 0

        async def exchange_offer(self, configuration, offer):
            self.calls += 1
            return "v=0\r\n"

    gateway = Gateway()
    args = Namespace(max_exchanges=1, evidence=str(tmp_path / "result.json"))
    settings = QwenWebRtcSettings(
        workspace_id="probe-test",
        model="qwen3.8-omni-flash-realtime",
        config_id="test",
        api_key="t" * 32,
    )
    probe = module.InterruptProbe(args, settings, gateway=gateway)
    assert probe.exchange("v=0\r\n")[0] == 200
    assert probe.exchange("v=0\r\n")[0] == 429
    assert gateway.calls == 1
    probe.record({"reason": "response_done", "status": "cancelled"})
    evidence = json.loads(Path(args.evidence).read_text())
    assert evidence["exchanges_used"] == 1
    assert evidence["observations"][0]["status"] == "cancelled"
    assert "does not prove upstream termination" in evidence["boundary"]


def test_page_events_cancel_once_only_after_hold_and_fail_closed():
    module = load()
    result = subprocess.run(
        ["node", str(Path(__file__).with_name("qwen_webrtc_interrupt_harness.cjs"))],
        input=module.PAGE_JS,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr


def test_local_server_serves_synthetic_input_and_limits_exchange(tmp_path):
    module = load()
    from http.server import ThreadingHTTPServer

    from simontalk_api.qwen_webrtc_signalling import QwenWebRtcSettings

    class Gateway:
        async def exchange_offer(self, configuration, offer):
            return "v=0\r\n"

    args = Namespace(max_exchanges=1, evidence=str(tmp_path / "result.json"))
    settings = QwenWebRtcSettings(
        workspace_id="probe-test",
        model="qwen3.8-omni-flash-realtime",
        config_id="test",
        api_key="t" * 32,
    )
    probe = module.InterruptProbe(args, settings, gateway=Gateway())
    wav_data = module.pcm_to_wav(b"\0\0" * 100)
    server = ThreadingHTTPServer(("127.0.0.1", 0), module.make_handler(probe, wav_data))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
    try:
        connection.request("GET", "/synthetic.wav")
        response = connection.getresponse()
        assert response.status == 200 and response.read() == wav_data
        connection.request("GET", "/")
        response = connection.getresponse()
        assert response.status == 200 and b"/interrupt.js" in response.read()
        for expected in (200, 429):
            connection.request("POST", "/exchange", "v=0\r\n", {"Content-Type": "application/sdp"})
            response = connection.getresponse()
            assert response.status == expected
            response.read()
    finally:
        connection.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
