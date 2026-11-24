#!/usr/bin/env python3
"""Bounded, local-only playback probe for the production WebRTC transport.

The browser cannot call Aliyun with the API key, so this helper keeps the key on
the server, performs exactly one SDP exchange per click through the same gateway
class the API uses, and records only the observations the page reports.

It is a controlled experiment, not product code and not acceptance evidence on
its own: the page uses a synthetic silent microphone, mutes the audio element,
and never claims a human heard anything.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import sys
import threading
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services/api/src"))

from simontalk_api.errors import APIError
from simontalk_api.qwen_webrtc_signalling import (
    QwenWebRtcSettings,
    QwenWebRtcSignallingGateway,
)

TRANSPORT = ROOT / "apps/client/web/realtime_transport.js"
ENV_FILE = ROOT / "services/api/.env"
CONFIG_ID = "qwen-playback-probe-v1"
MAX_BODY = 262144


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Probe:
    def __init__(
        self,
        args: argparse.Namespace,
        settings: QwenWebRtcSettings,
        gateway: QwenWebRtcSignallingGateway | None = None,
    ):
        self.args = args
        self.settings = settings
        self.gateway = gateway or QwenWebRtcSignallingGateway(settings)
        self.lock = threading.Lock()
        self.exchanges = 0
        self.transport_sha = digest(TRANSPORT)
        self.started_at = datetime.now(UTC).isoformat()
        self.evidence_path = Path(args.evidence)
        self.observations: list[dict] = []

    def configuration(self) -> dict:
        return {
            "provider": "dashscope",
            "region": "cn-beijing",
            "model": self.settings.model,
            "config_id": self.settings.config_id,
        }

    def exchange(self, offer: str) -> tuple[int, dict]:
        with self.lock:
            if self.exchanges >= self.args.max_exchanges:
                return 429, {"error": "probe_exchange_limit_reached"}
            self.exchanges += 1
            sequence = self.exchanges
        try:
            answer = asyncio.run(
                self.gateway.exchange_offer(self.configuration(), offer)
            )
        except APIError as error:
            return error.status, {"error": error.code}
        except Exception:  # noqa: BLE001 - provider detail must never reach the page
            # No SDP, credentials or upstream body is echoed back to the page.
            return 502, {"error": "signalling_failed"}
        return 200, {"answer": answer, "exchange": sequence}

    def record(self, payload: dict) -> None:
        entry = {
            "received_at": datetime.now(UTC).isoformat(),
            "exchange_limit": self.args.max_exchanges,
            **payload,
        }
        with self.lock:
            self.observations.append(entry)
            document = {
                "tool": "qwen-playback-probe",
                "started_at": self.started_at,
                "model": self.settings.model,
                "transport_sha256": self.transport_sha,
                "exchanges_used": self.exchanges,
                "observations": self.observations,
                "boundary": (
                    "Synthetic silent microphone, muted output element, one "
                    "SDP exchange per run. Playing observations are the "
                    "transport's own reports and do not prove audible output."
                ),
            }
            self.evidence_path.parent.mkdir(parents=True, exist_ok=True)
            self.evidence_path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )


def make_handler(probe: Probe):
    class Handler(BaseHTTPRequestHandler):
        server_version = "simontalk-probe"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # keep terminal clean, no SDP in logs
            sys.stderr.write("[probe] %s\n" % (fmt % args))

        def _send(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _read(self) -> bytes | None:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return None
            if length < 0 or length > MAX_BODY:
                return None
            return self.rfile.read(length)

        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/":
                self._send(200, PAGE.encode("utf-8"), "text/html; charset=utf-8")
            elif path == "/realtime_transport.js":
                self._send(
                    200, TRANSPORT.read_bytes(), "text/javascript; charset=utf-8"
                )
            elif path == "/health":
                self._send(200, b'{"ok":true}', "application/json")
            else:
                self._send(404, b"not found", "text/plain; charset=utf-8")

        def do_POST(self):
            path = urlsplit(self.path).path
            body = self._read()
            if body is None:
                self._send(413, b'{"error":"body_too_large"}', "application/json")
                return
            if path == "/exchange":
                offer = body.decode("utf-8", errors="strict") if body else ""
                if not offer.startswith(("v=0\r\n", "v=0\n")):
                    self._send(422, b'{"error":"invalid_offer"}', "application/json")
                    return
                status, payload = probe.exchange(offer)
                self._send(
                    status,
                    json.dumps(payload).encode("utf-8"),
                    "application/json",
                )
            elif path == "/evidence":
                try:
                    payload = json.loads(body.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    self._send(422, b'{"error":"invalid_evidence"}', "application/json")
                    return
                if not isinstance(payload, dict):
                    self._send(422, b'{"error":"invalid_evidence"}', "application/json")
                    return
                probe.record(payload)
                self._send(204, b"", "text/plain; charset=utf-8")
            else:
                self._send(404, b"not found", "text/plain; charset=utf-8")

    return Handler


PAGE = r"""<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<title>SimonTalk 千问播放复测</title>
<style>
  body { max-width: 820px; margin: 32px auto; padding: 0 20px; font: 16px/1.7 system-ui; }
  button { min-height: 48px; padding: 8px 22px; font: inherit; }
  pre { white-space: pre-wrap; overflow-wrap: anywhere; background: #111; color: #ddd; padding: 12px; border-radius: 8px; }
</style>
<h1>千问 WebRTC 播放复测</h1>
<p>用途：用仓库里<strong>当前生产传输脚本</strong>连接一次真实千问，观察远端音轨到达后播放器是否真的进入播放。
输入为合成静音，不申请物理麦克风，输出元素静音；一次点击最多一次 SDP 交换。</p>
<p>这不证明人耳听见、也不证明文字与音频对齐。</p>
<button id="run">运行一次</button>
<pre id="log">尚未运行</pre>
<script src="/realtime_transport.js"></script>
<script>
(() => {
  const log0 = document.getElementById('log');
  const transportReady = () => window.simontalkRealtime && window.simontalkRealtime.supported
    ? '浏览器传输支持：是'
    : '浏览器传输支持：否（需支持 WebRTC 的桌面浏览器）';
  window.addEventListener('simontalk-realtime-ready', () => {
    if (log0.textContent === '尚未运行') log0.textContent = transportReady();
  });
  if (window.simontalkRealtime) log0.textContent = transportReady();
})();
</script>
<script>
(() => {
  const run = document.getElementById('run');
  const log = document.getElementById('log');
  const started = [];
  const events = [];
  let transport, context, oscillator, input, peer, signalSource, analyser, silentGain, signalTimer;
  let inboundAudioBytes = null;
  let responseStatus = null, usage = null, signalPhase = 'before_response';
  const signal = {
    threshold_rms: 0.001,
    before_response: { samples: 0, over_threshold: 0, peak_rms: 0 },
    during_response: { samples: 0, over_threshold: 0, peak_rms: 0 },
    after_response: { samples: 0, over_threshold: 0, peak_rms: 0 },
    error: null,
  };
  const originalCreateElement = document.createElement;
  const originalGetUserMedia = navigator.mediaDevices.getUserMedia;
  const originalPeerConnection = window.RTCPeerConnection;
  let done = false;
  let deadline;
  let finish;
  const finished = new Promise((resolve) => { finish = resolve; });
  const startedAt = () => Math.round(performance.now());
  const note = (code, detail) => {
    started.push({ at: startedAt(), code, detail: detail ?? null });
    log.textContent = started.map((e) => `${e.at}ms  ${e.code}${e.detail ? '  ' + e.detail : ''}`).join('\n');
  };

  async function post(path, body, type) {
    const response = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': type },
      body,
    });
    return { status: response.status, body: response.status === 204 ? null : await response.json().catch(() => null) };
  }

  function configuration() {
    return {
      type: 'session.update',
      session: {
        modalities: ['text', 'audio'],
        max_tokens: 128,
        enable_search: false,
        voice: 'Tina',
        instructions: 'You are a friendly English conversation partner. Reply with one short spoken sentence.',
        input_audio_transcription: { model: 'qwen3-asr-flash-realtime' },
        turn_detection: {
          type: 'server_vad',
          threshold: 0.2,
          silence_duration_ms: 600,
          create_response: false,
          interrupt_response: false,
        },
      },
    };
  }

  function observeRemoteAudio(track) {
    if (signalSource || track.kind !== 'audio' || done) return;
    try {
      signalSource = context.createMediaStreamSource(new window.MediaStream([track]));
      analyser = context.createAnalyser();
      analyser.fftSize = 2048;
      silentGain = context.createGain();
      silentGain.gain.value = 0;
      signalSource.connect(analyser);
      analyser.connect(silentGain);
      silentGain.connect(context.destination);
      const data = new Float32Array(analyser.fftSize);
      signalTimer = setInterval(() => {
        try {
          analyser.getFloatTimeDomainData(data);
          let sum = 0;
          for (const value of data) sum += value * value;
          const rms = Math.sqrt(sum / data.length);
          const sample = signal[signalPhase];
          sample.samples++;
          sample.peak_rms = Math.max(sample.peak_rms, rms);
          if (rms >= signal.threshold_rms) sample.over_threshold++;
        } catch (_) { signal.error = 'sampling_failed'; clearInterval(signalTimer); }
      }, 50);
    } catch (_) { signal.error = 'analysis_unavailable'; }
  }

  function safeUsage(value) {
    if (!value || typeof value !== 'object') return null;
    const clean = {};
    for (const key of ['input_tokens', 'output_tokens', 'total_tokens']) {
      if (Number.isSafeInteger(value[key]) && value[key] >= 0) clean[key] = value[key];
    }
    for (const key of ['input_tokens_details', 'output_tokens_details']) {
      const details = value[key];
      if (!details || typeof details !== 'object') continue;
      const part = {};
      for (const field of ['text_tokens', 'audio_tokens']) {
        if (Number.isSafeInteger(details[field]) && details[field] >= 0) part[field] = details[field];
      }
      if (Object.keys(part).length) clean[key] = part;
    }
    return Object.keys(clean).length ? clean : null;
  }

  async function finishRun(reason) {
    if (done) return;
    done = true;
    clearTimeout(deadline);
    const observations = started.slice();
    const inbound = observations.filter((e) => e.code === 'playback_playing').length;
    const waiting = observations.filter((e) => e.code === 'playback_waiting').length;
    const failed = observations.filter((e) => e.code.startsWith('playback_failed')).length;
    // Release media before doing any I/O: evidence persistence can fail or hang.
    clearInterval(signalTimer);
    try { signalSource?.disconnect(); analyser?.disconnect(); silentGain?.disconnect(); } catch (_) {}
    try { transport?.stop(); } catch (_) {}
    try { input?.getTracks().forEach((track) => track.stop()); } catch (_) {}
    try { if (oscillator) { oscillator.stop(); oscillator.disconnect(); } } catch (_) {}
    document.createElement = originalCreateElement;
    navigator.mediaDevices.getUserMedia = originalGetUserMedia;
    window.RTCPeerConnection = originalPeerConnection;
    if (context) await context.close().catch(() => {});
    try {
      const result = await post('/evidence', JSON.stringify({
      reason,
      script_sha_loaded: true,
      playback: { playing: inbound, waiting, failed },
      inbound_audio_bytes: inboundAudioBytes,
      audio_signal: signal,
      response_status: responseStatus,
      usage,
      observations,
      protocol_events: events.slice(-40),
      }), 'application/json');
      if (result.status !== 204) throw new Error('evidence_failed');
      log.textContent += `\n结束：${reason}（playing ${inbound} / waiting ${waiting} / failed ${failed}）`;
    } catch (_) {
      log.textContent += '\n结束：证据写入失败，媒体已关闭';
    } finally { finish(); }
  }

  run.addEventListener('click', async () => {
    run.disabled = true;
    note('probe_started');
    deadline = setTimeout(() => finishRun('probe_timeout'), 45000);
    let channel;
    let configured = false;
    let activated = false;
    try {
      context = new AudioContext();
      await context.resume();
      const destination = context.createMediaStreamDestination();
      oscillator = context.createConstantSource();
      oscillator.offset.value = 0;
      oscillator.connect(destination);
      oscillator.start();
      input = destination.stream;
      navigator.mediaDevices.getUserMedia = async () => input;
      document.createElement = function (tag, ...args) {
        const element = originalCreateElement.call(document, tag, ...args);
        if (String(tag).toLowerCase() === 'audio') element.muted = true;
        return element;
      };
      window.RTCPeerConnection = new Proxy(originalPeerConnection, {
        construct(target, args) {
          peer = Reflect.construct(target, args);
          peer.addEventListener('track', ({ track }) => observeRemoteAudio(track));
          return peer;
        },
      });

      transport = window.simontalkRealtime.create();
      const startedResult = await transport.start(async (offer) => {
        note('exchange_requested');
        const result = await post('/exchange', offer, 'application/sdp');
        if (result.status !== 200) {
          note('exchange_rejected', String(result.status) + ' ' + (result.body?.error ?? ''));
          throw new Error('exchange_failed');
        }
        note('exchange_ok');
        return result.body.answer;
      }, (code, detail) => {
        note(code, detail);
      }, (json, channelId) => {
        let event;
        try { event = JSON.parse(json); } catch (_) { note('invalid_event'); return; }
        events.push({ at: startedAt(), type: event.type ?? null });
        if (event.type === 'session.created') {
          channel = channelId;
          const error = transport.send(JSON.stringify(configuration()), channelId);
          note('session_update_sent', error ?? undefined);
        } else if (event.type === 'session.updated') {
          configured = true;
          transport.activate(channelId).then((error) => {
            if (error) { note('activate_rejected', String(error)); return; }
            activated = true;
            note('activated');
            transport.send(JSON.stringify({
              type: 'conversation.item.create',
              item: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Say hello in one short sentence.' }] },
            }), channelId);
            transport.send('{"type":"response.create"}', channelId);
            note('response_requested');
          });
        } else if (event.type === 'response.created') {
          signalPhase = 'during_response';
        } else if (event.type === 'response.done') {
          signalPhase = 'after_response';
          if (['completed', 'cancelled', 'failed', 'incomplete'].includes(event.response?.status)) {
            responseStatus = event.response.status;
          }
          usage = safeUsage(event.response?.usage);
          note('response_done');
          if (peer) void peer.getStats().then((reports) => {
            let total = 0;
            for (const report of reports.values()) {
              if (report.type === 'inbound-rtp' && (report.kind ?? report.mediaType) === 'audio' &&
                  Number.isSafeInteger(report.bytesReceived) && report.bytesReceived >= 0) {
                total += report.bytesReceived;
              }
            }
            inboundAudioBytes = total;
          }).catch(() => {});
          setTimeout(() => finishRun('response_done'), 2000);
        } else if (event.type === 'error') {
          note('upstream_error', JSON.stringify(event.error?.code ?? null));
        }
      }, () => note('cancelled'));

      if (startedResult !== null) {
        note('start_failed', String(startedResult));
        await finishRun('start_failed');
        return;
      }
    } catch (error) {
      note('probe_error', error?.message ?? 'unknown');
      await finishRun('probe_error');
    }
  });

  window.addEventListener('pagehide', () => { if (!done) void finishRun('page_hidden'); });
})();
</script>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=7391)
    parser.add_argument("--model", default="qwen3.8-omni-flash-realtime")
    parser.add_argument("--max-exchanges", type=int, default=1, choices=range(1, 4))
    parser.add_argument(
        "--evidence",
        default=str(
            ROOT
            / "docs/development/evidence"
            / f"{datetime.now(UTC):%Y-%m-%d}-qwen-playback-probe.json"
        ),
    )
    args = parser.parse_args()

    env = load_env(ENV_FILE)
    key = os.environ.get("SIMONTALK_QWEN_API_KEY") or env.get("SIMONTALK_QWEN_API_KEY")
    workspace = os.environ.get("SIMONTALK_QWEN_WORKSPACE_ID") or env.get(
        "SIMONTALK_QWEN_WORKSPACE_ID"
    )
    if not key or not workspace:
        print(
            "缺少 SIMONTALK_QWEN_API_KEY / SIMONTALK_QWEN_WORKSPACE_ID；"
            "请在 services/api/.env 配置后再运行。",
            file=sys.stderr,
        )
        return 2
    settings = QwenWebRtcSettings(
        workspace_id=workspace, model=args.model, config_id=CONFIG_ID, api_key=key
    )
    probe = Probe(args, settings)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(probe))
    print(f"transport sha256: {probe.transport_sha}")
    print(f"model: {args.model}  max exchanges: {args.max_exchanges}")
    print(f"evidence: {probe.evidence_path}")
    print(f"open: http://127.0.0.1:{args.port}/")
    print("Ctrl+C 结束。")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
