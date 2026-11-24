"""PostgreSQL identity checks; no vendor and no public websocket route."""

from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Event
from uuid import uuid4

import pytest
from sqlalchemy import update

from simontalk_api.models import AuthSession, User
from simontalk_api.security import digest, now
from simontalk_api.websocket_handshake import HandshakeError, HandshakeIdentity
from simontalk_api.websocket_identity import lock_websocket_identity


@pytest.fixture
def identity_case(factory):
    user_id, auth_id = uuid4(), uuid4()
    secret = "test-session-secret-" + "X" * 40
    with factory.begin() as db:
        db.add(User(id=user_id, username="ws_test", display_name="Test", password_hash="fake"))
        db.flush()
        db.add(
            AuthSession(
                id=auth_id,
                user_id=user_id,
                token_digest=digest(secret),
                platform="web",
                expires_at=now() + timedelta(hours=1),
            )
        )
    return HandshakeIdentity(user_id, digest(secret)), auth_id


def test_valid_prechecked_session_is_locked_without_committing(factory, identity_case):
    identity, auth_id = identity_case
    with factory() as db:
        result = lock_websocket_identity(db, identity)
        assert result.user_id == identity.account_id and result.auth_id == auth_id
        assert db.in_transaction()
        db.rollback()


@pytest.mark.parametrize("mode", ["revoked", "expired", "mobile", "disabled", "account", "token"])
def test_invalid_session_account_or_user_rejected(factory, identity_case, mode):
    identity, auth_id = identity_case
    with factory.begin() as db:
        if mode in {"revoked", "expired", "mobile"}:
            values = {
                "revoked": {"revoked_at": now()},
                "expired": {"expires_at": now() - timedelta(seconds=1)},
                "mobile": {"platform": "mobile"},
            }[mode]
            db.execute(update(AuthSession).where(AuthSession.id == auth_id).values(**values))
        elif mode == "disabled":
            db.execute(update(User).where(User.id == identity.account_id).values(disabled_at=now()))
    if mode == "account":
        identity = HandshakeIdentity(uuid4(), identity.session_digest)
    elif mode == "token":
        identity = HandshakeIdentity(identity.account_id, digest("wrong"))
    with factory() as db:
        with pytest.raises(HandshakeError) as caught:
            lock_websocket_identity(db, identity)
        assert identity.session_digest not in str(caught.value)
        db.rollback()


def test_revocation_waits_for_authentication_transaction(factory, identity_case):
    identity, auth_id = identity_case
    held, release, revocation_started, revoked = Event(), Event(), Event(), Event()

    def hold():
        with factory.begin() as db:
            lock_websocket_identity(db, identity)
            held.set()
            assert release.wait(5)

    def revoke():
        with factory.begin() as db:
            revocation_started.set()
            db.execute(
                update(AuthSession).where(AuthSession.id == auth_id).values(revoked_at=now())
            )
        revoked.set()

    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(hold)
        assert held.wait(5)
        second = pool.submit(revoke)
        try:
            assert revocation_started.wait(5)
            assert not revoked.wait(0.2)
        finally:
            release.set()
        first.result(timeout=5)
        second.result(timeout=5)
    with factory() as db:
        with pytest.raises(HandshakeError):
            lock_websocket_identity(db, identity)


def test_revocation_between_precheck_and_locks_is_rechecked(factory, identity_case):
    identity, auth_id = identity_case
    first_query_done, continue_check = Event(), Event()

    class PausedSession:
        def __init__(self, db):
            self.db = db
            self.calls = 0

        def scalar(self, query):
            result = self.db.scalar(query)
            self.calls += 1
            if self.calls == 1:
                first_query_done.set()
                assert continue_check.wait(5)
            return result

    def check():
        with factory() as db:
            with pytest.raises(HandshakeError):
                lock_websocket_identity(PausedSession(db), identity)
            db.rollback()

    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(check)
        try:
            assert first_query_done.wait(5)
            with factory.begin() as db:
                db.execute(
                    update(AuthSession).where(AuthSession.id == auth_id).values(revoked_at=now())
                )
        finally:
            continue_check.set()
        pending.result(timeout=5)


def test_expiry_while_waiting_for_session_lock_is_rechecked(factory, identity_case):
    from sqlalchemy import select

    identity, auth_id = identity_case
    lock_query_entered = Event()

    class ObservedSession:
        def __init__(self, db):
            self.db = db
            self.calls = 0

        def scalar(self, query):
            self.calls += 1
            if self.calls == 3:
                lock_query_entered.set()
            return self.db.scalar(query)

    def check():
        with factory() as db:
            with pytest.raises(HandshakeError):
                lock_websocket_identity(ObservedSession(db), identity)
            db.rollback()

    with factory.begin() as db:
        db.execute(
            update(AuthSession)
            .where(AuthSession.id == auth_id)
            .values(expires_at=now() + timedelta(seconds=2))
        )
    with factory() as blocker, ThreadPoolExecutor(max_workers=1) as pool:
        blocker.scalar(select(AuthSession.id).where(AuthSession.id == auth_id).with_for_update())
        pending = pool.submit(check)
        try:
            assert lock_query_entered.wait(5)
            Event().wait(2.1)
        finally:
            blocker.rollback()
        pending.result(timeout=5)
