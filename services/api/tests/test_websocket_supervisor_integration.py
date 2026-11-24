"""Supervisor against PostgreSQL and fake sockets; no external provider."""

import asyncio
import json
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import update
from test_connection_reservations import reserve
from test_practice_preparation import account as account
from test_qwen_websocket_gateway import CONFIG, settings
from test_signalling import connection_row

from simontalk_api.models import AuthSession, RealtimeConnection, TerminationCheck
from simontalk_api.qwen_websocket import QwenWebSocketGateway
from simontalk_api.security import digest, now
from simontalk_api.websocket_claim import claim_websocket
from simontalk_api.websocket_handshake import HandshakeIdentity
from simontalk_api.websocket_supervisor import QwenSupervisorError, supervise_websocket


class FakeSocket:
    def __init__(self, *, bad_update=False, stall=False, on_send=None):
        self.bad_update = bad_update
        self.stall = stall
        self.on_send = on_send
        self.calls = 0
        self.close_calls = 0
        self.aborts = 0
        self.sent = []
        self.transport = self
        self.created = asyncio.Event()

    async def send(self, value):
        self.sent.append(json.loads(value))
        if self.on_send:
            self.on_send()

    async def recv(self):
        self.calls += 1
        self.created.set()
        if self.stall:
            await asyncio.Future()
        if self.calls == 1:
            return json.dumps(
                {
                    "event_id": "event_created",
                    "type": "session.created",
                    "session": {
                        "id": "sess_test",
                        "object": "realtime.session",
                        "model": CONFIG["model"],
                    },
                }
            )
        session = dict(self.sent[0]["session"])
        session.update(
            {
                "id": "sess_other" if self.bad_update else "sess_test",
                "object": "realtime.session",
                "model": CONFIG["model"],
                "input_audio_format": "pcm",
                "output_audio_format": "pcm",
            }
        )
        return json.dumps(
            {"event_id": "event_updated", "type": "session.updated", "session": session}
        )

    async def close(self, code=1000):
        self.close_calls += 1

    def abort(self):
        self.aborts += 1


@pytest.fixture
def supervisor_scope(client, app, account, factory):
    identity, headers = account

    class Admission:
        def admit(self, user_id):
            return SimpleNamespace(**CONFIG)

    app.state.practice_admission = Admission()
    response = client.post(
        "/v1/practice-sessions",
        headers={**headers, "Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    )
    assert response.status_code == 201
    prepared = SimpleNamespace(identity=identity, headers=headers, session=response.json())
    connection = reserve(client, prepared).json()
    user_id = UUID(identity["user"]["id"])
    auth_id, token_digest = uuid4(), digest("supervisor-test-web-session")
    from datetime import timedelta

    with factory.begin() as db:
        db.add(
            AuthSession(
                id=auth_id,
                user_id=user_id,
                token_digest=token_digest,
                platform="web",
                expires_at=now() + timedelta(hours=1),
            )
        )
    return prepared, connection, HandshakeIdentity(user_id, token_digest), auth_id


def make_claim(factory, app, supervisor_scope, socket):
    prepared, connection, identity, _ = supervisor_scope
    calls = []

    async def connector(url, **kwargs):
        calls.append(url)
        return socket

    gateway = QwenWebSocketGateway(settings(), connector=connector)
    claim = claim_websocket(
        factory,
        identity,
        app.state.practice_admission,
        gateway,
        session_id=UUID(prepared.session["id"]),
        connection_id=UUID(connection["id"]),
        client_instance_id=UUID(connection["client_instance_id"]),
        epoch=connection["epoch"],
    )
    return claim, calls


def check_unknown(factory, connection):
    row = connection_row(factory, connection)
    assert (row["status"], row["termination_status"]) == ("unknown", "unknown")
    with factory() as db:
        check = db.get(TerminationCheck, UUID(connection["id"]))
        assert check.status == "blocked" and check.attempts == 0


def test_same_socket_configured_then_exit_closes_and_marks_unknown(factory, app, supervisor_scope):
    async def run():
        prepared, connection, identity, _ = supervisor_scope
        socket = FakeSocket()
        claim, calls = make_claim(factory, app, supervisor_scope, socket)
        async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
            row = connection_row(factory, connection)
            assert row["status"] == "configuring" and row["termination_status"] == "unknown"
            assert row["signalling_finished_at"] is not None
            assert len(calls) == 1 and len(socket.sent) == 1
            with pytest.raises(QwenSupervisorError):
                async with supervise_websocket(
                    factory, identity, claim, app.state.practice_admission
                ):
                    pass
        assert socket.close_calls == 1
        check_unknown(factory, connection)

    asyncio.run(run())


def test_bad_echo_never_configures_and_closes(factory, app, supervisor_scope):
    async def run():
        _, connection, identity, _ = supervisor_scope
        socket = FakeSocket(bad_update=True)
        claim, calls = make_claim(factory, app, supervisor_scope, socket)
        with pytest.raises(QwenSupervisorError):
            async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
                pytest.fail("must not yield")
        assert len(calls) == 1 and socket.close_calls == 1
        check_unknown(factory, connection)

    asyncio.run(run())


def test_revocation_before_echo_fails_closed(factory, app, supervisor_scope):
    async def run():
        _, connection, identity, auth_id = supervisor_scope

        def revoke():
            with factory.begin() as db:
                db.execute(
                    update(AuthSession).where(AuthSession.id == auth_id).values(revoked_at=now())
                )

        socket = FakeSocket(on_send=revoke)
        claim, _ = make_claim(factory, app, supervisor_scope, socket)
        with pytest.raises(QwenSupervisorError):
            async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
                pytest.fail("must not yield")
        assert socket.close_calls == 1
        check_unknown(factory, connection)

    asyncio.run(run())


def test_cancellation_during_receive_closes_and_records_unknown(factory, app, supervisor_scope):
    async def run():
        _, connection, identity, _ = supervisor_scope
        socket = FakeSocket(stall=True)
        claim, _ = make_claim(factory, app, supervisor_scope, socket)

        async def run_session():
            async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
                pytest.fail("must not yield")

        task = asyncio.create_task(run_session())
        await socket.created.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert socket.close_calls == 1 and socket.aborts == 1
        check_unknown(factory, connection)

    asyncio.run(run())


def test_revoked_before_open_never_dials_upstream(factory, app, supervisor_scope):
    async def run():
        _, connection, identity, auth_id = supervisor_scope
        socket = FakeSocket()
        claim, calls = make_claim(factory, app, supervisor_scope, socket)
        with factory.begin() as db:
            db.execute(
                update(AuthSession).where(AuthSession.id == auth_id).values(revoked_at=now())
            )
        with pytest.raises(QwenSupervisorError):
            async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
                pytest.fail("must not yield")
        assert calls == [] and socket.close_calls == 0
        check_unknown(factory, connection)

    asyncio.run(run())


def test_stalled_cleanup_is_bounded_and_retains_ownership(
    factory, app, supervisor_scope, monkeypatch
):
    from threading import Event

    from simontalk_api import websocket_supervisor as module

    entered, release, finished = Event(), Event(), Event()
    original = module.mark_websocket_unknown

    def slow_finish(*args):
        entered.set()
        try:
            assert release.wait(5)
            return original(*args)
        finally:
            finished.set()

    monkeypatch.setattr(module, "mark_websocket_unknown", slow_finish)
    monkeypatch.setattr(module, "_CLEANUP_WAIT", 0.05)

    async def run():
        _, connection, identity, _ = supervisor_scope
        socket = FakeSocket()
        claim, _ = make_claim(factory, app, supervisor_scope, socket)
        try:
            async with asyncio.timeout(2):
                async with supervise_websocket(
                    factory, identity, claim, app.state.practice_admission
                ):
                    pass
            assert entered.is_set() and socket.close_calls == 1
            assert claim.fingerprint in module._ACTIVE
        finally:
            release.set()
        assert await asyncio.to_thread(finished.wait, 5)
        await asyncio.sleep(0)
        check_unknown(factory, connection)

    asyncio.run(run())


def test_late_socket_after_startup_timeout_is_closed(factory, app, supervisor_scope, monkeypatch):
    from simontalk_api import websocket_supervisor as module

    monkeypatch.setattr(module, "_STARTUP_TIMEOUT", 0.05)

    async def run():
        prepared, connection, identity, _ = supervisor_scope
        late_release, closed = asyncio.Event(), asyncio.Event()

        class LateSocket(FakeSocket):
            async def close(self, code=1000):
                await super().close(code)
                closed.set()

        socket = LateSocket()

        async def connector(url, **kwargs):
            try:
                await asyncio.Future()
            except asyncio.CancelledError:
                await late_release.wait()
            return socket

        gateway = QwenWebSocketGateway(settings(), connector=connector)
        claim = claim_websocket(
            factory,
            identity,
            app.state.practice_admission,
            gateway,
            session_id=UUID(prepared.session["id"]),
            connection_id=UUID(connection["id"]),
            client_instance_id=UUID(connection["client_instance_id"]),
            epoch=connection["epoch"],
        )
        with pytest.raises(QwenSupervisorError):
            async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
                pytest.fail("must not yield")
        check_unknown(factory, connection)
        late_release.set()
        await asyncio.wait_for(closed.wait(), timeout=2)
        assert socket.close_calls == 1

    asyncio.run(run())


def test_body_exception_propagates_after_conservative_cleanup(factory, app, supervisor_scope):
    async def run():
        _, connection, identity, _ = supervisor_scope
        socket = FakeSocket()
        claim, _ = make_claim(factory, app, supervisor_scope, socket)
        with pytest.raises(RuntimeError, match="controlled body failure"):
            async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
                raise RuntimeError("controlled body failure")
        assert socket.close_calls == 1
        check_unknown(factory, connection)

    asyncio.run(run())


def test_malformed_claim_is_sanitized_and_never_opens(factory, app, supervisor_scope):
    from dataclasses import replace

    async def run():
        _, connection, identity, _ = supervisor_scope
        socket = FakeSocket()
        claim, calls = make_claim(factory, app, supervisor_scope, socket)
        malformed = replace(claim, session_id="private-secret")
        with pytest.raises(QwenSupervisorError) as caught:
            async with supervise_websocket(
                factory, identity, malformed, app.state.practice_admission
            ):
                pytest.fail("must not yield")
        assert "private-secret" not in str(caught.value)
        assert calls == [] and connection_row(factory, connection)["status"] == "negotiating"

    asyncio.run(run())


def test_late_database_confirmation_cannot_revive_cancelled_claim(
    factory, app, supervisor_scope, monkeypatch
):
    from threading import Event

    from simontalk_api import websocket_supervisor as module

    entered, release, finished = Event(), Event(), Event()
    original = module._revalidate

    def delayed(*args, confirm):
        if confirm:
            entered.set()
            assert release.wait(5)
        try:
            return original(*args, confirm=confirm)
        finally:
            if confirm:
                finished.set()

    monkeypatch.setattr(module, "_revalidate", delayed)

    async def run():
        _, connection, identity, _ = supervisor_scope
        socket = FakeSocket()
        claim, _ = make_claim(factory, app, supervisor_scope, socket)

        async def start():
            async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
                pytest.fail("cancelled startup must not yield")

        task = asyncio.create_task(start())
        try:
            assert await asyncio.to_thread(entered.wait, 5)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
            check_unknown(factory, connection)
        finally:
            release.set()
        assert await asyncio.to_thread(finished.wait, 5)
        check_unknown(factory, connection)
        assert socket.close_calls == 1

    asyncio.run(run())


@pytest.mark.parametrize("invalidation", ["revoke", "expire_lease"])
def test_running_session_is_closed_after_authorization_or_lease_loss(
    factory, app, supervisor_scope, invalidation
):
    from datetime import timedelta

    async def run():
        _, connection, identity, auth_id = supervisor_scope
        closed = asyncio.Event()

        class ObservableSocket(FakeSocket):
            async def close(self, code=1000):
                await super().close(code)
                closed.set()

        socket = ObservableSocket()
        claim, _ = make_claim(factory, app, supervisor_scope, socket)
        async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
            with factory.begin() as db:
                if invalidation == "revoke":
                    db.execute(
                        update(AuthSession)
                        .where(AuthSession.id == auth_id)
                        .values(revoked_at=now())
                    )
                else:
                    db.execute(
                        update(RealtimeConnection)
                        .where(RealtimeConnection.id == UUID(connection["id"]))
                        .values(lease_expires_at=now() - timedelta(seconds=1))
                    )
            await asyncio.wait_for(closed.wait(), timeout=4)
        check_unknown(factory, connection)
        assert socket.close_calls == 1

    asyncio.run(run())


def test_stalled_runtime_database_fails_closed_without_repeated_checks(
    factory, app, supervisor_scope, monkeypatch
):
    from threading import Event

    from simontalk_api import websocket_supervisor as module

    entered, release, exited = Event(), Event(), Event()
    original = module._revalidate
    active_calls = []

    def slow(*args, confirm, active=False):
        if active:
            active_calls.append(1)
            entered.set()
            try:
                assert release.wait(5)
            finally:
                exited.set()
        return original(*args, confirm=confirm, active=active)

    monkeypatch.setattr(module, "_revalidate", slow)
    monkeypatch.setattr(module, "_RECHECK_INTERVAL", 0.01)
    monkeypatch.setattr(module, "_RECHECK_TIMEOUT", 0.05)

    async def run():
        _, connection, identity, _ = supervisor_scope
        closed = asyncio.Event()

        class ObservableSocket(FakeSocket):
            async def close(self, code=1000):
                await super().close(code)
                closed.set()

        socket = ObservableSocket()
        claim, _ = make_claim(factory, app, supervisor_scope, socket)
        try:
            async with supervise_websocket(factory, identity, claim, app.state.practice_admission):
                assert await asyncio.to_thread(entered.wait, 5)
                await asyncio.wait_for(closed.wait(), timeout=2)
                assert len(active_calls) == 1
            check_unknown(factory, connection)
        finally:
            release.set()
        assert await asyncio.to_thread(exited.wait, 5)
        check_unknown(factory, connection)

    asyncio.run(run())
