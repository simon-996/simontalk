"""Durable WebSocket claim checks on isolated PostgreSQL, never contacting a vendor."""

from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import update
from test_connection_reservations import prepared as prepared
from test_connection_reservations import reserve
from test_signalling import TestGateway, connection_row, offer

from simontalk_api.errors import APIError
from simontalk_api.models import AuthSession, RealtimeConnection, TerminationCheck
from simontalk_api.practice import UnavailableAdmission
from simontalk_api.security import digest, now
from simontalk_api.websocket_claim import claim_websocket
from simontalk_api.websocket_handshake import HandshakeError, HandshakeIdentity


class Gateway:
    def __init__(self):
        self.attempts = 0
        self.open_calls = 0

    def attempt(self, configuration):
        assert configuration == {
            "provider": "test-only",
            "region": "test",
            "model": "test-model",
            "config_id": "test-v1",
        }
        self.attempts += 1
        return self

    async def open(self):
        self.open_calls += 1
        raise AssertionError("claim must not open the provider")


@pytest.fixture
def scope(client, prepared, factory):
    connection = reserve(client, prepared).json()
    user_id = UUID(prepared.identity["user"]["id"])
    token_digest = digest("test-only-web-session-token")
    auth_id = uuid4()
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
    return connection, HandshakeIdentity(user_id, token_digest), auth_id


def claim(factory, prepared, scope, gateway, admission, **changes):
    connection, identity, _ = scope
    args = {
        "session_id": UUID(prepared.session["id"]),
        "connection_id": UUID(connection["id"]),
        "client_instance_id": UUID(connection["client_instance_id"]),
        "epoch": connection["epoch"],
    }
    args.update(changes)
    return claim_websocket(factory, identity, admission, gateway, **args)


def test_claim_is_durable_single_attempt_and_blocks_webrtc(client, app, prepared, factory, scope):
    gateway = Gateway()
    attempt = claim(factory, prepared, scope, gateway, app.state.practice_admission)
    connection, identity, auth_id = scope
    row = connection_row(factory, connection)
    assert (row["status"], row["termination_status"], row["state_reason"]) == (
        "negotiating",
        "unknown",
        "websocket_started",
    )
    assert len(row["offer_digest"]) == 64 and row["signalling_started_at"] is not None
    assert attempt.user_id == identity.account_id and attempt.auth_id == auth_id
    assert attempt.connection_id == UUID(connection["id"])
    assert gateway.attempts == 1 and gateway.open_calls == 0
    with pytest.raises(APIError):
        claim(factory, prepared, scope, gateway, app.state.practice_admission)
    app.state.signalling_gateway = TestGateway()
    assert offer(client, prepared, connection).status_code == 409
    assert gateway.attempts == 1 and gateway.open_calls == 0


@pytest.mark.parametrize(
    "change", ["account", "instance", "epoch", "admission", "revoked", "expired_lease"]
)
def test_claim_rejects_invalid_or_expired_scope_without_provider(
    factory, app, prepared, scope, change
):
    connection, identity, auth_id = scope
    gateway = Gateway()
    kwargs = {}
    admission = app.state.practice_admission
    if change == "account":
        scope = (connection, HandshakeIdentity(uuid4(), identity.session_digest), auth_id)
    elif change == "instance":
        kwargs["client_instance_id"] = uuid4()
    elif change == "epoch":
        kwargs["epoch"] = connection["epoch"] + 1
    elif change == "admission":
        admission = UnavailableAdmission()
    elif change == "revoked":
        with factory.begin() as db:
            db.execute(
                update(AuthSession).where(AuthSession.id == auth_id).values(revoked_at=now())
            )
    elif change == "expired_lease":
        with factory.begin() as db:
            db.execute(
                update(RealtimeConnection)
                .where(RealtimeConnection.id == UUID(connection["id"]))
                .values(lease_expires_at=now() - timedelta(seconds=1))
            )
    with pytest.raises((HandshakeError, APIError)):
        claim(factory, prepared, scope, gateway, admission, **kwargs)
    row = connection_row(factory, connection)
    assert row["offer_digest"] is None and gateway.open_calls == 0
    assert gateway.attempts == 0


def test_concurrent_claims_commit_once(factory, app, prepared, scope):
    gateway = Gateway()

    def run():
        try:
            claim(factory, prepared, scope, gateway, app.state.practice_admission)
            return True
        except APIError:
            return False

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(lambda _: run(), range(2))) == [False, True]
    assert gateway.attempts == 1 and gateway.open_calls == 0


def test_unknown_claim_gets_existing_termination_evidence(factory, app, prepared, scope):
    from simontalk_api.termination_checks import ensure_termination_check

    connection, _, _ = scope
    attempt = claim(factory, prepared, scope, Gateway(), app.state.practice_admission)
    with factory.begin() as db:
        row = db.get(RealtimeConnection, UUID(connection["id"]))
        row.status, row.state_reason = "unknown", "websocket_unknown"
        assert ensure_termination_check(db, row)
    with factory() as db:
        check = db.get(TerminationCheck, UUID(connection["id"]))
        assert check.attempt_digest == attempt.fingerprint
        assert check.status == "blocked" and check.attempts == 0


def test_failed_commit_never_returns_attempt_or_persists_claim(factory, app, prepared, scope):
    gateway = Gateway()

    def failing_factory():
        db = factory()

        def fail_commit():
            raise RuntimeError("synthetic commit failure")

        db.commit = fail_commit
        return db

    with pytest.raises(RuntimeError, match="synthetic commit failure"):
        claim(failing_factory, prepared, scope, gateway, app.state.practice_admission)
    row = connection_row(factory, scope[0])
    assert row["offer_digest"] is None and row["status"] == "preparing"
    assert gateway.attempts == 1 and gateway.open_calls == 0


def test_webrtc_attempt_blocks_later_websocket_claim(client, app, prepared, factory, scope):
    connection, _, _ = scope
    app.state.signalling_gateway = TestGateway()
    assert offer(client, prepared, connection).status_code == 200
    original = connection_row(factory, connection)["offer_digest"]
    gateway = Gateway()
    with pytest.raises(APIError):
        claim(factory, prepared, scope, gateway, app.state.practice_admission)
    assert connection_row(factory, connection)["offer_digest"] == original
    assert gateway.attempts == 0 and gateway.open_calls == 0


def test_expired_claim_stays_unknown_and_enqueues_blocked_termination(
    factory, app, prepared, scope
):
    from simontalk_api.connections import _expire
    from simontalk_api.models import PracticeSession

    connection, _, _ = scope
    attempt = claim(factory, prepared, scope, Gateway(), app.state.practice_admission)
    with factory.begin() as db:
        practice = db.get(PracticeSession, UUID(prepared.session["id"]))
        row = db.get(RealtimeConnection, UUID(connection["id"]))
        _expire(db, practice, row, now())
    row = connection_row(factory, connection)
    assert (row["status"], row["termination_status"]) == ("unknown", "unknown")
    with factory() as db:
        check = db.get(TerminationCheck, UUID(connection["id"]))
        assert check.attempt_digest == attempt.fingerprint
        assert check.status == "blocked" and check.attempts == 0


def test_login_expiring_during_claim_rolls_back_before_network(factory, app, prepared, scope):
    from threading import Event

    connection, _, auth_id = scope
    with factory.begin() as db:
        db.execute(
            update(AuthSession)
            .where(AuthSession.id == auth_id)
            .values(expires_at=now() + timedelta(seconds=0.3))
        )

    class SlowGateway(Gateway):
        def attempt(self, configuration):
            result = super().attempt(configuration)
            Event().wait(0.5)
            return result

    gateway = SlowGateway()
    with pytest.raises(HandshakeError):
        claim(factory, prepared, scope, gateway, app.state.practice_admission)
    row = connection_row(factory, connection)
    assert row["status"] == "preparing" and row["offer_digest"] is None
    assert gateway.attempts == 1 and gateway.open_calls == 0


def test_changed_provider_configuration_never_starts_attempt(factory, app, prepared, scope):
    from types import SimpleNamespace

    class ChangedAdmission:
        def admit(self, _):
            return SimpleNamespace(
                provider="different", region="test", model="test-model", config_id="test-v1"
            )

    gateway = Gateway()
    with pytest.raises(APIError):
        claim(factory, prepared, scope, gateway, ChangedAdmission())
    assert connection_row(factory, scope[0])["offer_digest"] is None
    assert gateway.attempts == 0 and gateway.open_calls == 0


def test_claim_binds_difficulty_and_pace_from_persisted_snapshot(factory, app, prepared, scope):
    attempt = claim(factory, prepared, scope, Gateway(), app.state.practice_admission)
    assert attempt.difficulty == "beginner"
    assert attempt.speech_pace == "normal"


def test_corrupt_snapshot_cannot_start_websocket_attempt(factory, app, prepared, scope):
    from simontalk_api.models import PracticeSession

    with factory.begin() as db:
        practice = db.get(PracticeSession, UUID(prepared.session["id"]))
        practice.configuration = {**practice.configuration, "effective_difficulty": "injected"}
    gateway = Gateway()
    with pytest.raises(APIError):
        claim(factory, prepared, scope, gateway, app.state.practice_admission)
    assert gateway.attempts == 0 and gateway.open_calls == 0
    assert connection_row(factory, scope[0])["offer_digest"] is None


def test_rehearsal_claim_binds_verified_frozen_target_and_rejects_tampering(
    client, app, prepared, factory
):
    from types import SimpleNamespace

    from sqlalchemy import select
    from test_rehearsal_preparations import create, release
    from test_saved_transcripts import base, event, seal, successful_review

    original = event(text="I enjoy English. 我喜欢英语。")
    _, completion = seal(client, prepared, [original])
    job = successful_review(client, prepared, completion, factory)
    item = job["result"]["items"][0]
    source = SimpleNamespace(
        scope=prepared,
        item=item,
        path=base(prepared) + f"/review-items/{item['id']}/rehearsal-target",
    )
    release(factory, source)
    target = client.get(source.path, headers=source.scope.headers).json()
    created = create(client, source, target["target_hash"], difficulty_override="advanced").json()
    rehearsal_session = created["practice"]
    rehearsal_prepared = SimpleNamespace(
        identity=source.scope.identity,
        headers=source.scope.headers,
        session=rehearsal_session,
    )
    connection = reserve(client, rehearsal_prepared).json()
    user_id = UUID(source.scope.identity["user"]["id"])
    token_digest = digest("rehearsal-claim-web-session")
    auth_id = uuid4()
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
    rehearsal_scope = (connection, HandshakeIdentity(user_id, token_digest), auth_id)

    from simontalk_api.models import PracticeSession

    with factory.begin() as db:
        child = db.get(PracticeSession, UUID(rehearsal_session["id"]))
        original_hash = child.rehearsal_target_hash
        child.rehearsal_target_hash = "f" * 64
    tampered_gateway = Gateway()
    with pytest.raises(APIError) as exc:
        claim(
            factory,
            rehearsal_prepared,
            rehearsal_scope,
            tampered_gateway,
            app.state.practice_admission,
        )
    assert exc.value.code == "practice_configuration_changed"
    assert tampered_gateway.attempts == 0
    assert connection_row(factory, connection)["offer_digest"] is None

    with factory.begin() as db:
        child = db.get(PracticeSession, UUID(rehearsal_session["id"]))
        child.rehearsal_target_hash = original_hash
        assert db.scalar(select(PracticeSession.kind).where(PracticeSession.id == child.id)) == (
            "rehearsal"
        )
    gateway = Gateway()
    attempt = claim(
        factory, rehearsal_prepared, rehearsal_scope, gateway, app.state.practice_admission
    )
    assert attempt.difficulty == "advanced"
    assert attempt.rehearsal is not None
    assert attempt.rehearsal.target_hash == target["target_hash"]
    assert attempt.rehearsal.exact_quote == target["exact_quote"]
    assert attempt.rehearsal.suggestion == target["suggestion"]
    assert gateway.attempts == 1 and gateway.open_calls == 0
