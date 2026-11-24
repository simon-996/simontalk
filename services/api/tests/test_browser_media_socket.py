"""Exercise the opt-in ASGI WebSocket with durable PostgreSQL claims."""

import asyncio
from types import SimpleNamespace
from uuid import UUID

import pytest
from starlette.websockets import WebSocket
from test_authenticated_websocket_claim import ORIGIN
from test_authenticated_websocket_claim import browser_scope as browser_scope
from test_practice_preparation import account as account
from test_qwen_turn_pump_supervisor import PumpSocket
from test_qwen_websocket_gateway import settings
from test_signalling import connection_row
from test_websocket_pcm_wire import frame
from test_websocket_supervisor_integration import (
    check_unknown,
)
from test_websocket_supervisor_integration import (
    supervisor_scope as supervisor_scope,
)

from simontalk_api import browser_media_socket as entry
from simontalk_api.qwen_websocket import QwenWebSocketGateway


class Peer:
    def __init__(self, factory, app, scope):
        prepared, connection, _, headers, self.proof = scope
        self.row = connection
        self.up = PumpSocket()
        self.opens = 0
        self.inbox, self.outbox = asyncio.Queue(), asyncio.Queue()

        async def connect(*args, **kwargs):
            self.opens += 1
            return self.up

        self.gateway = QwenWebSocketGateway(settings(), connector=connect)
        self.socket = WebSocket(
            {
                "type": "websocket",
                "query_string": b"",
                "headers": headers.raw,
                "app": SimpleNamespace(
                    state=SimpleNamespace(
                        session_factory=factory,
                        settings=SimpleNamespace(allowed_origins=[ORIGIN]),
                        practice_admission=app.state.practice_admission,
                    )
                ),
            },
            self.inbox.get,
            self.outbox.put,
        )
        self.target = dict(
            session_id=UUID(prepared.session["id"]),
            connection_id=UUID(connection["id"]),
            client_instance_id=UUID(connection["client_instance_id"]),
            epoch=connection["epoch"],
        )

    async def start(self):
        self.inbox.put_nowait({"type": "websocket.connect"})
        self.task = asyncio.create_task(
            entry.serve_browser_media(self.socket, self.gateway, **self.target)
        )
        assert (await asyncio.wait_for(self.outbox.get(), 2))["type"] == "websocket.accept"

    def send(self, value):
        key = "bytes" if isinstance(value, bytes) else "text"
        self.inbox.put_nowait({"type": "websocket.receive", key: value})

    def disconnect(self):
        self.inbox.put_nowait({"type": "websocket.disconnect", "code": 1001})


@pytest.mark.parametrize("kind", ["timeout", "oversize", "binary", "disconnected"])
def test_first_message_is_required_before_claim(factory, app, browser_scope, kind, monkeypatch):
    monkeypatch.setattr(entry, "_PROOF_TIMEOUT", 0.05)

    async def run():
        p = Peer(factory, app, browser_scope)
        await p.start()
        if kind == "disconnected":
            p.disconnect()
        elif kind != "timeout":
            p.send(b"abc" if kind == "binary" else "a" * 1025)
        await asyncio.wait_for(p.task, 2)
        assert p.opens == 0
        assert connection_row(factory, p.row)["offer_digest"] is None

    asyncio.run(run())


def test_claim_rejected_by_full_session_capacity_is_finalized(
    factory, app, browser_scope, monkeypatch
):
    from simontalk_api import supervised_pump_session

    monkeypatch.setattr(supervised_pump_session, "_MAX_SESSIONS", 0)

    async def run():
        p = Peer(factory, app, browser_scope)
        await p.start()
        p.send(p.proof)
        await asyncio.wait_for(p.task, 2)
        assert p.opens == 0
        check_unknown(factory, p.row)

    asyncio.run(run())


def test_disconnect_during_provider_configuration(factory, app, browser_scope):
    async def run():
        p = Peer(factory, app, browser_scope)
        p.up.stall = True
        await p.start()
        p.send(p.proof)
        await asyncio.wait_for(p.up.created.wait(), 2)
        p.disconnect()
        await asyncio.wait_for(p.task, 2)
        assert p.opens == p.up.close_calls == 1
        check_unknown(factory, p.row)

    asyncio.run(run())


@pytest.mark.parametrize("abort", ["disconnect", "early_media"])
def test_loss_while_claim_waits_on_database_lock(factory, app, browser_scope, abort):
    from sqlalchemy import text

    from simontalk_api.models import RealtimeConnection

    async def run():
        p = Peer(factory, app, browser_scope)
        with factory.begin() as db:
            db.get(RealtimeConnection, p.target["connection_id"], with_for_update=True)
            await p.start()
            p.send(p.proof)
            async with asyncio.timeout(3):
                while True:
                    with factory() as probe:
                        if probe.scalar(
                            text(
                                "SELECT count(*) FROM pg_stat_activity"
                                " WHERE datname=current_database()"
                                " AND wait_event_type='Lock'"
                            )
                        ):
                            break
                    await asyncio.sleep(0.01)
            if abort == "disconnect":
                p.disconnect()
            else:
                p.send(b"\0" * 3213)
            await asyncio.wait_for(p.task, 2)
            assert p.opens == 0
        async with asyncio.timeout(3):
            while connection_row(factory, p.row)["status"] != "unknown":
                await asyncio.sleep(0.01)
        check_unknown(factory, p.row)
        assert p.opens == 0

    asyncio.run(run())


def test_forbidden_origin_rejected_before_upgrade(factory, app, browser_scope):
    async def run():
        peer = Peer(factory, app, browser_scope)
        peer.socket.scope["headers"] = [(b"origin", b"https://other.example")]
        peer.inbox.put_nowait({"type": "websocket.connect"})
        await asyncio.wait_for(
            entry.serve_browser_media(peer.socket, peer.gateway, **peer.target), 2
        )
        assert (await peer.outbox.get())["type"] == "websocket.close"
        assert peer.opens == 0 and connection_row(factory, peer.row)["offer_digest"] is None

    asyncio.run(run())


def test_full_ready_queue_closes_without_sending_more_pcm(factory, app, browser_scope):
    async def run():
        peer = Peer(factory, app, browser_scope)
        await peer.start()
        peer.send(peer.proof)
        assert (await asyncio.wait_for(peer.outbox.get(), 2))["text"] == '{"kind":"ready"}'
        peer.send('{"kind":"mode","epoch":1,"muted":false}')
        for sequence in range(1, 5):
            peer.send(frame(1, sequence))
        await asyncio.wait_for(peer.task, 2)
        assert (await peer.outbox.get())["code"] == 1008
        assert peer.up.close_calls == 1
        assert [ev["type"] for ev in peer.up.sent] == ["session.update"]
        check_unknown(factory, peer.row)

    asyncio.run(run())


def test_late_unknown_write_keeps_entry_capacity_until_commit(
    factory, app, browser_scope, monkeypatch
):
    from threading import Event

    from simontalk_api import supervised_pump_session

    entered, release = Event(), Event()
    mark_unknown = entry.mark_websocket_unknown

    def delayed(*args):
        entered.set()
        assert release.wait(5)
        return mark_unknown(*args)

    monkeypatch.setattr(entry, "mark_websocket_unknown", delayed)
    monkeypatch.setattr(entry, "_WRITE_TIMEOUT", 0.03)
    monkeypatch.setattr(entry, "_MAX_ENTRIES", 1)
    monkeypatch.setattr(supervised_pump_session, "_MAX_SESSIONS", 0)

    async def run():
        peer = Peer(factory, app, browser_scope)
        await peer.start()
        peer.send(peer.proof)
        try:
            assert await asyncio.to_thread(entered.wait, 2)
            await asyncio.wait_for(peer.task, 2)
            other = Peer(factory, app, browser_scope)
            await entry.serve_browser_media(other.socket, other.gateway, **other.target)
            assert (await other.outbox.get())["code"] == 1013
            assert peer.opens == other.opens == 0
        finally:
            release.set()
        async with asyncio.timeout(2):
            while entry._ENTRIES:
                await asyncio.sleep(0.005)
        check_unknown(factory, peer.row)

    asyncio.run(run())
