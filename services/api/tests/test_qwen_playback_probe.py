import json
import subprocess
import sys
from argparse import Namespace
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

import qwen_playback_probe as probe_module  # noqa: E402

from simontalk_api.errors import APIError  # noqa: E402
from simontalk_api.qwen_webrtc_signalling import QwenWebRtcSettings  # noqa: E402

SETTINGS = QwenWebRtcSettings(
    workspace_id="probe-test",
    model="qwen3.8-omni-flash-realtime",
    config_id=probe_module.CONFIG_ID,
    api_key="t" * 32,
)


class FakeGateway:
    def __init__(self, failure=None):
        self.failure = failure
        self.calls = 0

    async def exchange_offer(self, configuration, offer):
        self.calls += 1
        if self.failure is not None:
            raise self.failure
        return "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n"


def make_probe(tmp_path, gateway, limit=1):
    args = Namespace(
        max_exchanges=limit,
        evidence=str(tmp_path / "evidence.json"),
        model=SETTINGS.model,
    )
    return probe_module.Probe(args, SETTINGS, gateway=gateway)


def test_one_exchange_is_the_default_bound(tmp_path):
    gateway = FakeGateway()
    probe = make_probe(tmp_path, gateway)
    status, payload = probe.exchange("v=0\r\n")
    assert status == 200
    assert payload["exchange"] == 1
    assert payload["answer"].startswith("v=0")
    status, payload = probe.exchange("v=0\r\n")
    assert status == 429
    assert payload == {"error": "probe_exchange_limit_reached"}
    assert gateway.calls == 1


def test_upstream_failure_never_echoes_provider_detail(tmp_path):
    probe = make_probe(tmp_path, FakeGateway(RuntimeError("secret upstream body")))
    status, payload = probe.exchange("v=0\r\n")
    assert status == 502
    assert payload == {"error": "signalling_failed"}

    probe = make_probe(tmp_path, FakeGateway(APIError(422, "invalid_offer", "bad")))
    status, payload = probe.exchange("v=0\r\n")
    assert status == 422
    assert payload == {"error": "invalid_offer"}


def test_evidence_records_the_script_hash_and_boundary(tmp_path):
    probe = make_probe(tmp_path, FakeGateway())
    probe.record({"reason": "smoke", "observations": [{"code": "probe_started"}]})
    document = json.loads((tmp_path / "evidence.json").read_text(encoding="utf-8"))
    assert document["tool"] == "qwen-playback-probe"
    assert document["transport_sha256"] == probe_module.digest(probe_module.TRANSPORT)
    assert "do not prove audible output" in document["boundary"]
    assert document["observations"][0]["reason"] == "smoke"


def test_the_page_uses_the_production_transport_script():
    page = probe_module.PAGE
    assert '<script src="/realtime_transport.js"></script>' in page
    assert "window.simontalkRealtime.create()" in page
    assert "getUserMedia = async () => input" in page


def test_inline_page_script_parses(tmp_path):
    page = probe_module.PAGE
    scripts = [
        chunk.split("</script>", 1)[0] for chunk in page.split("<script>")[1:] if chunk.strip()
    ]
    assert len(scripts) == 2
    node = subprocess.run(["node", "--version"], capture_output=True, text=True, check=False)
    if node.returncode != 0:
        pytest.skip("node is unavailable")
    for index, script in enumerate(scripts):
        path = tmp_path / f"inline-{index}.js"
        path.write_text(script, encoding="utf-8")
        result = subprocess.run(
            ["node", "--check", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr
