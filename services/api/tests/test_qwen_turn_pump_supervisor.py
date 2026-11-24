"""Local integration: real supervisor and pump, synthetic identity and socket."""

import asyncio
from types import MappingProxyType
from uuid import uuid4

import pytest
from test_qwen_turn_pump import Downstream, deliver, msg, pcm, prepare_response
from test_qwen_websocket_gateway import CONFIG, settings
from test_websocket_pcm_wire import frame
from test_websocket_supervisor_integration import FakeSocket

from simontalk_api.qwen_turn_pump import QwenPumpError, QwenTurnPump
from simontalk_api.qwen_websocket import QwenWebSocketGateway
from simontalk_api.websocket_claim import WebSocketClaim, _fingerprint
from simontalk_api.websocket_handshake import HandshakeIdentity
from simontalk_api.websocket_supervisor import supervise_websocket


class PumpSocket(FakeSocket):
    def __init__(self):
        super().__init__()
        self.incoming = asyncio.Queue()

    async def recv(self):
        if self.calls < 2:
            return await super().recv()
        value = await self.incoming.get()
        if value is None:
            raise ConnectionError("local socket closed")
        return value

    async def close(self, code=1000):
        await super().close(code)
        self.incoming.put_nowait(None)


def scope(socket):
    user, auth, session, connection, instance = (uuid4() for _ in range(5))

    async def connector(url, **kwargs):
        return socket

    gateway = QwenWebSocketGateway(settings(), connector=connector)
    claim = WebSocketClaim(
        user,
        auth,
        session,
        connection,
        instance,
        1,
        _fingerprint(user, session, connection, instance, 1),
        "intermediate",
        "normal",
        MappingProxyType(CONFIG),
        gateway.attempt(CONFIG),
    )
    return HandshakeIdentity(user, "synthetic-digest"), claim


def test_supervisor_and_pump_share_socket_and_close_after_one_turn(monkeypatch):
    from simontalk_api import websocket_supervisor as supervisor

    finalized = []
    monkeypatch.setattr(supervisor, "_revalidate", lambda *args, **kwargs: None)
    monkeypatch.setattr(
        supervisor, "mark_websocket_unknown", lambda *args: finalized.append(args[2])
    )

    async def run():
        socket, downstream = PumpSocket(), Downstream()
        identity, claim = scope(socket)
        async with supervise_websocket(None, identity, claim, None) as connection:
            pump = QwenTurnPump(connection, downstream.send, downstream.close)
            await pump.accept_client('{"kind":"mode","epoch":1,"muted":false}')
            assert await pump.accept_client(frame(1, 1)) == "forwarded"
            await prepare_response(pump, socket)
            await deliver(pump, socket, pcm())
            await deliver(
                pump, socket, msg("input_audio_buffer.speech_started", "e8", item_id="user_b")
            )
            assert [event["type"] for event in socket.sent] == [
                "session.update",
                "input_audio_buffer.append",
                "response.create",
                "response.cancel",
            ]
            assert downstream.sent[-2] == {"kind": "quarantine", "response_id": "response_a"}
            assert downstream.sent[-1]["event"]["item_id"] == "user_b"
            await pump.close()
        assert socket.close_calls == 1 and downstream.closed == 1
        assert finalized == ["disconnected"]

    asyncio.run(run())


def test_supervisor_invalidation_breaks_pending_pump_receive(monkeypatch):
    from simontalk_api import websocket_supervisor as supervisor

    invalidated = False
    finalized = []

    def revalidate(*args, active=False, **kwargs):
        if active and invalidated:
            raise ValueError("synthetic revoked session")

    monkeypatch.setattr(supervisor, "_revalidate", revalidate)
    monkeypatch.setattr(supervisor, "_RECHECK_INTERVAL", 0.01)
    monkeypatch.setattr(
        supervisor, "mark_websocket_unknown", lambda *args: finalized.append(args[2])
    )

    async def run():
        nonlocal invalidated
        socket, downstream = PumpSocket(), Downstream()
        identity, claim = scope(socket)
        async with supervise_websocket(None, identity, claim, None) as connection:
            pump = QwenTurnPump(connection, downstream.send, downstream.close)
            pending = asyncio.create_task(pump.receive_one())
            await asyncio.sleep(0)
            invalidated = True
            with pytest.raises(QwenPumpError):
                await asyncio.wait_for(pending, 1)
            assert downstream.closed == 1
        assert socket.close_calls == 1
        assert finalized == ["auth_lost"]

    asyncio.run(run())
