"""Full local protocol simulation; no network access or billable calls."""

import asyncio
import base64
import importlib.util
import json
import sys
from pathlib import Path
from types import SimpleNamespace


def module():
    scripts = Path(__file__).resolve().parents[3] / "scripts"
    sys.path.insert(0, str(scripts))
    spec = importlib.util.spec_from_file_location(
        "overlap_session", scripts / "qwen_overlap_probe_session.py"
    )
    assert spec is not None and spec.loader is not None
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class Socket:
    def __init__(self, *, echo_config=True, acknowledge_close=True):
        self.events = asyncio.Queue()
        self.events.put_nowait({"type": "session.created"})
        self.sent = []
        self.echo_config = echo_config
        self.acknowledge_close = acknowledge_close
        self.protocol = SimpleNamespace(close_sent=None, close_rcvd=None)

    async def recv(self):
        return await self.events.get()

    async def send(self, payload):
        item = json.loads(payload)
        kind = item["type"]
        self.sent.append(kind)
        if kind == "session.update":
            vad = item["session"]["turn_detection"].copy()
            if not self.echo_config:
                vad["create_response"] = True
            self.events.put_nowait(
                {"type": "session.updated", "session": {"turn_detection": vad, "max_tokens": 128}}
            )
        elif kind == "conversation.item.create":
            self.events.put_nowait({"type": "conversation.item.created", "item": item["item"]})
        elif kind == "response.create":
            self.events.put_nowait({"type": "response.created", "response": {"id": "r1"}})
            self.events.put_nowait(
                {
                    "type": "response.audio.delta",
                    "response_id": "r1",
                    "delta": base64.b64encode(b"ab").decode(),
                }
            )
        elif kind == "input_audio_buffer.append":
            self.events.put_nowait(
                {"type": "input_audio_buffer.speech_started", "item_id": "speech"}
            )
            self.events.put_nowait(
                {"type": "input_audio_buffer.speech_stopped", "item_id": "speech"}
            )
            self.events.put_nowait(
                {"type": "response.done", "response": {"id": "r1", "status": "completed"}}
            )

    async def close(self, code):
        self.protocol.close_sent = SimpleNamespace(code=code)
        if self.acknowledge_close:
            self.protocol.close_rcvd = SimpleNamespace(code=1000)


def test_full_session_requires_confirmation_and_closes():
    async def run():
        socket = Socket()
        result = await module().execute_session(
            socket, pcm=b"abcd", timeout_seconds=1, post_speech_seconds=0.01
        )
        assert result["configured"] is True
        assert result["response_requested"] is True
        assert result["overlap"]["reader"]["speech_started_before_done"] is True
        assert result["overlap"]["reader"]["speech_stopped"] is True
        assert result["overlap"]["reader"]["response_status"] == "completed"
        assert result["close_sent"] == 1000 and result["close_received"] == 1000
        assert socket.sent.count("response.create") == 1

    asyncio.run(run())


def test_wrong_configuration_fails_before_response_request():
    async def run():
        socket = Socket(echo_config=False)
        result = await module().execute_session(
            socket, pcm=b"abcd", timeout_seconds=1, post_speech_seconds=0.01
        )
        assert result["reason"] == "configuration_unconfirmed"
        assert not result["response_requested"]
        assert "response.create" not in socket.sent
        assert result["close_received"] == 1000

    asyncio.run(run())


def test_local_close_does_not_invent_remote_confirmation():
    async def run():
        socket = Socket(acknowledge_close=False)
        result = await module().execute_session(
            socket, pcm=b"abcd", timeout_seconds=1, post_speech_seconds=0.01
        )
        assert result["close_sent"] == 1000 and result["close_received"] is None

    asyncio.run(run())


def test_unconfirmed_response_creation_cancels_once_and_keeps_status_unknown():
    async def run():
        class NoCreated(Socket):
            async def send(self, payload):
                kind = json.loads(payload)["type"]
                if kind == "response.create":
                    self.sent.append(kind)
                else:
                    await super().send(payload)

        socket = NoCreated()
        result = await module().execute_session(
            socket, pcm=b"abcd", timeout_seconds=0.03, post_speech_seconds=0.01
        )
        assert result["reason"] == "timeout"
        assert result["response_requested"]
        assert result["cancel_attempted_before_supervision"]
        assert result["overlap"] is None
        assert socket.sent.count("response.cancel") == 1
        assert result["close_received"] == 1000

    asyncio.run(run())


def test_mismatched_created_item_does_not_request_response():
    async def run():
        class OtherItem(Socket):
            async def send(self, payload):
                kind = json.loads(payload)["type"]
                if kind == "conversation.item.create":
                    self.sent.append(kind)
                    self.events.put_nowait(
                        {"type": "conversation.item.created", "item": {"role": "assistant"}}
                    )
                else:
                    await super().send(payload)

        socket = OtherItem()
        result = await module().execute_session(
            socket, pcm=b"abcd", timeout_seconds=1, post_speech_seconds=0.01
        )
        assert result["reason"] == "protocol_failed"
        assert not result["response_requested"]
        assert "response.create" not in socket.sent

    asyncio.run(run())


def test_invalid_audio_still_closes_the_owned_socket():
    async def run():
        socket = Socket()
        result = await module().execute_session(socket, pcm=b"x", timeout_seconds=1)
        assert result["reason"] == "protocol_failed"
        assert socket.sent == []
        assert result["close_received"] == 1000

    asyncio.run(run())


def test_close_waits_for_delayed_peer_ack_within_transport_limit():
    async def run():
        class DelayedClose(Socket):
            async def close(self, code):
                self.protocol.close_sent = SimpleNamespace(code=code)
                await asyncio.sleep(1.1)
                self.protocol.close_rcvd = SimpleNamespace(code=1000)

        socket = DelayedClose(echo_config=False)
        result = await module().execute_session(socket, pcm=b"abcd", timeout_seconds=1)
        assert result["close_sent"] == 1000
        assert result["close_received"] == 1000

    asyncio.run(run())
