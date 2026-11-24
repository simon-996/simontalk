import http.client
import importlib
import sys
import threading
from argparse import Namespace
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))


def test_controller_probe_limits_one_exchange_and_serves_local_inputs(tmp_path):
    module = importlib.import_module("qwen_controller_interrupt_probe")
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
        config_id=module.base.CONFIG_ID,
        api_key="t" * 32,
    )
    probe = module.InterruptProbe(args, settings, gateway=gateway)
    wav = module.pcm_to_wav(b"\0\0" * 100)
    server = ThreadingHTTPServer(("127.0.0.1", 0), module.make_handler(probe, wav))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
    try:
        for path, expected in [
            ("/", b"/controller.js"),
            ("/synthetic.wav", wav),
            ("/realtime_transport.js", b"simontalkRealtime"),
        ]:
            connection.request("GET", path)
            result = connection.getresponse()
            assert result.status == 200 and expected in result.read()
        connection.request("GET", "/../../services/api/.env")
        result = connection.getresponse()
        assert result.status == 404
        result.read()
        for expected in (200, 429):
            connection.request("POST", "/exchange", "v=0\r\n", {"Content-Type": "application/sdp"})
            result = connection.getresponse()
            assert result.status == expected
            result.read()
        assert gateway.calls == 1
    finally:
        connection.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


def test_probe_rejects_missing_or_non_probe_bundle(tmp_path):
    module = importlib.import_module("qwen_controller_interrupt_probe")
    bundle = tmp_path / "main.dart.js"
    assert not module.is_controller_bundle(bundle)
    bundle.write_text("ordinary production app", encoding="utf-8")
    assert not module.is_controller_bundle(bundle)
    bundle.write_text("probe.waitForStart probe.finished", encoding="utf-8")
    assert module.is_controller_bundle(bundle)
