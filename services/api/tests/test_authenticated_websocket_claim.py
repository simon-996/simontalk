"""Real isolated PostgreSQL; synthetic browser proof, no provider connections."""

import asyncio
import json
from threading import Event
from uuid import UUID, uuid4

import pytest
from sqlalchemy import text, update
from starlette.datastructures import Headers
from test_practice_preparation import account as account
from test_qwen_turn_pump import msg
from test_qwen_turn_pump_supervisor import PumpSocket
from test_qwen_websocket_gateway import settings
from test_signalling import connection_row
from test_supervised_pump_session import Downstream
from test_websocket_supervisor_integration import supervisor_scope as supervisor_scope

from simontalk_api.authenticated_websocket_claim import ClaimError, authenticate_and_claim
from simontalk_api.models import AuthSession, RealtimeConnection, TerminationCheck
from simontalk_api.qwen_websocket import QwenWebSocketGateway
from simontalk_api.security import digest, now
from simontalk_api.supervised_pump_session import run_pump_session

SESSION = "s" * 43
CSRF = "c" * 43
ORIGIN = "https://talk.example"


@pytest.fixture
def browser_scope(factory, supervisor_scope):
    prepared, connection, identity, auth_id = supervisor_scope
    with factory.begin() as db:
        db.execute(
            update(AuthSession)
            .where(AuthSession.id == auth_id)
            .values(token_digest=digest(SESSION))
        )
    headers = Headers(
        raw=[
            (b"origin", ORIGIN.encode()),
            (b"cookie", f"simontalk_session={SESSION}; simontalk_csrf={CSRF}".encode()),
        ]
    )
    body = json.dumps(
        {"type": "authenticate", "account_id": str(identity.account_id), "csrf": CSRF}
    )
    return prepared, connection, auth_id, headers, body


def args(factory, app, browser_scope, connector):
    prepared, connection, _, headers, body = browser_scope
    return dict(
        session_factory=factory,
        admission=app.state.practice_admission,
        gateway=QwenWebSocketGateway(settings(), connector=connector),
        headers=headers,
        query=b"",
        body=body,
        allowed_origins=[ORIGIN],
        session_id=UUID(prepared.session["id"]),
        connection_id=UUID(connection["id"]),
        client_instance_id=UUID(connection["client_instance_id"]),
        epoch=connection["epoch"],
    )


def test_valid_proof_claims_once_before_any_provider_open(factory, app, browser_scope):
    async def run():
        opened = []

        async def connector(*args, **kwargs):
            opened.append(1)
            return PumpSocket()

        options = args(factory, app, browser_scope, connector)
        identity, claim = await authenticate_and_claim(**options)
        connection = browser_scope[1]
        row = connection_row(factory, connection)
        assert (row["status"], row["termination_status"]) == ("negotiating", "unknown")
        assert claim.connection_id == UUID(connection["id"])
        assert identity.account_id == claim.user_id and identity.session_digest == digest(SESSION)
        assert SESSION not in repr(identity)
        assert not opened
        with pytest.raises(ClaimError):
            await authenticate_and_claim(**options)
        assert not opened

    asyncio.run(run())


@pytest.mark.parametrize("invalid", ["csrf", "account", "revoked", "instance"])
def test_invalid_proof_or_scope_never_claims(factory, app, browser_scope, invalid):
    async def run():
        opened = []

        async def connector(*args, **kwargs):
            opened.append(1)

        options = args(factory, app, browser_scope, connector)
        if invalid == "csrf":
            options["body"] = options["body"].replace(CSRF, "x" * 43)
        elif invalid == "account":
            body = json.loads(options["body"])
            body["account_id"] = str(uuid4())
            options["body"] = json.dumps(body)
        elif invalid == "revoked":
            with factory.begin() as db:
                db.execute(
                    update(AuthSession)
                    .where(AuthSession.id == browser_scope[2])
                    .values(revoked_at=now())
                )
        else:
            options["client_instance_id"] = uuid4()
        with pytest.raises(ClaimError) as caught:
            await authenticate_and_claim(**options)
        assert SESSION not in str(caught.value) and CSRF not in str(caught.value)
        row = connection_row(factory, browser_scope[1])
        assert row["status"] == "preparing" and row["offer_digest"] is None
        assert not opened

    asyncio.run(run())


@pytest.mark.parametrize("trigger", ["cancel", "timeout"])
def test_late_committed_claim_is_marked_unknown(factory, app, browser_scope, monkeypatch, trigger):
    from simontalk_api import authenticated_websocket_claim as module

    entered, release = Event(), Event()
    original = module.claim_websocket
    opened = []

    def delayed(*args, **kwargs):
        entered.set()
        assert release.wait(5)
        return original(*args, **kwargs)

    async def connector(*args, **kwargs):
        opened.append(1)

    monkeypatch.setattr(module, "claim_websocket", delayed)
    monkeypatch.setattr(module, "_CLAIM_TIMEOUT", 0.03 if trigger == "timeout" else 2.0)

    async def run():
        options = args(factory, app, browser_scope, connector)
        task = asyncio.create_task(authenticate_and_claim(**options))
        try:
            assert await asyncio.to_thread(entered.wait, 2)
            if trigger == "cancel":
                task.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await task
            else:
                with pytest.raises(ClaimError):
                    await asyncio.wait_for(task, 1)
            assert len(module._CLAIMS) == 1
        finally:
            release.set()
        for _ in range(1000):
            if not module._CLAIMS:
                break
            await asyncio.sleep(0.005)
        assert not module._CLAIMS and not opened
        row = connection_row(factory, browser_scope[1])
        assert (row["status"], row["termination_status"]) == ("unknown", "unknown")
        with factory() as db:
            check = db.get(TerminationCheck, UUID(browser_scope[1]["id"]))
            assert check.status == "blocked" and check.attempts == 0

    asyncio.run(run())


def test_cancel_during_real_connection_lock_finalizes_late_commit(factory, app, browser_scope):
    from simontalk_api import authenticated_websocket_claim as module

    async def run():
        async def connector(*args, **kwargs):
            pytest.fail("must never open")

        options = args(factory, app, browser_scope, connector)
        with factory.begin() as locked:
            locked.get(RealtimeConnection, UUID(browser_scope[1]["id"]), with_for_update=True)
            task = asyncio.create_task(authenticate_and_claim(**options))
            for _ in range(200):
                with factory() as probe:
                    waiting = probe.scalar(
                        text(
                            "SELECT count(*) FROM pg_stat_activity "
                            "WHERE datname = current_database() AND wait_event_type = 'Lock'"
                        )
                    )
                if waiting:
                    break
                await asyncio.sleep(0.005)
            else:
                pytest.fail("claim did not wait on the real database lock")
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
            assert len(module._CLAIMS) == 1
        for _ in range(1000):
            if not module._CLAIMS:
                break
            await asyncio.sleep(0.005)
        assert not module._CLAIMS
        row = connection_row(factory, browser_scope[1])
        assert (row["status"], row["termination_status"]) == ("unknown", "unknown")
        with factory() as db:
            check = db.get(TerminationCheck, UUID(browser_scope[1]["id"]))
            assert check.status == "blocked" and check.attempts == 0

    asyncio.run(run())


def test_real_handshake_claim_and_supervised_pump_stop(factory, app, browser_scope):
    async def run():
        socket, down = PumpSocket(), Downstream()

        async def connector(*args, **kwargs):
            return socket

        options = args(factory, app, browser_scope, connector)
        identity, claim = await authenticate_and_claim(**options)
        task = asyncio.create_task(
            run_pump_session(factory, identity, claim, app.state.practice_admission, down)
        )
        await socket.incoming.put(msg("input_audio_buffer.speech_started", "e1", item_id="user"))
        event = await asyncio.wait_for(down.output.get(), 3)
        assert event["event"]["item_id"] == "user"
        await down.incoming.put('{"kind":"stop"}')
        assert await asyncio.wait_for(task, 3) == "stopped"
        assert socket.close_calls == down.closed == 1
        row = connection_row(factory, browser_scope[1])
        assert (row["status"], row["termination_status"]) == ("unknown", "unknown")
        with factory() as db:
            check = db.get(TerminationCheck, UUID(browser_scope[1]["id"]))
            assert check.status == "blocked" and check.attempts == 0

    asyncio.run(run())


def test_cancelled_claim_keeps_capacity_until_late_finalization(
    factory, app, browser_scope, monkeypatch
):
    from simontalk_api import authenticated_websocket_claim as module

    entered, release = Event(), Event()
    original = module.mark_websocket_unknown

    def delayed_finish(*args):
        entered.set()
        assert release.wait(5)
        return original(*args)

    monkeypatch.setattr(module, "mark_websocket_unknown", delayed_finish)
    monkeypatch.setattr(module, "_MAX_CLAIMS", 1)

    async def run():
        async def connector(*args, **kwargs):
            pytest.fail("must never open")

        options = args(factory, app, browser_scope, connector)
        # Wait until the actual database commit, then abandon the result before
        # the async task can transfer ownership to the caller.
        committed, resume = Event(), Event()
        real_claim = module.claim_websocket

        def pause_after_commit(*args, **kwargs):
            claim = real_claim(*args, **kwargs)
            committed.set()
            assert resume.wait(5)
            return claim

        monkeypatch.setattr(module, "claim_websocket", pause_after_commit)
        task = asyncio.create_task(authenticate_and_claim(**options))
        try:
            assert await asyncio.to_thread(committed.wait, 3)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
            resume.set()
            assert await asyncio.to_thread(entered.wait, 3)
            with pytest.raises(ClaimError):
                await authenticate_and_claim(**options)
            assert len(module._CLAIMS) == 1
        finally:
            resume.set()
            release.set()
        for _ in range(1000):
            if not module._CLAIMS:
                break
            await asyncio.sleep(0.005)
        assert not module._CLAIMS
        row = connection_row(factory, browser_scope[1])
        assert row["status"] == "unknown"

    asyncio.run(run())


def test_real_identity_revocation_closes_composed_session(factory, app, browser_scope, monkeypatch):
    from simontalk_api import websocket_supervisor as supervisor

    monkeypatch.setattr(supervisor, "_RECHECK_INTERVAL", 0.01)

    async def run():
        socket, down = PumpSocket(), Downstream()

        async def connector(*args, **kwargs):
            return socket

        options = args(factory, app, browser_scope, connector)
        identity, claim = await authenticate_and_claim(**options)
        task = asyncio.create_task(
            run_pump_session(factory, identity, claim, app.state.practice_admission, down)
        )
        await socket.incoming.put(msg("input_audio_buffer.speech_started", "e1", item_id="user"))
        await asyncio.wait_for(down.output.get(), 3)
        with factory.begin() as db:
            db.execute(
                update(AuthSession)
                .where(AuthSession.id == browser_scope[2])
                .values(revoked_at=now())
            )
        from simontalk_api.supervised_pump_session import SessionError

        with pytest.raises(SessionError):
            await asyncio.wait_for(task, 3)
        assert socket.close_calls == down.closed == 1
        row = connection_row(factory, browser_scope[1])
        assert row["status"] == "unknown" and row["state_reason"] == "websocket_auth_lost"
        with factory() as db:
            check = db.get(TerminationCheck, UUID(browser_scope[1]["id"]))
            assert check.status == "blocked" and check.attempts == 0

    asyncio.run(run())
