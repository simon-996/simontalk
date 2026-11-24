"""Unknown finalization uses PostgreSQL, no real vendor or websocket endpoint."""

from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import update
from test_connection_reservations import prepared as prepared
from test_websocket_claim_integration import Gateway, claim
from test_websocket_claim_integration import scope as scope

from simontalk_api.errors import APIError
from simontalk_api.models import AuthSession, PracticeSession, RealtimeConnection, TerminationCheck
from simontalk_api.security import now
from simontalk_api.websocket_unknown import mark_websocket_unknown


def state(factory, prepared, connection):
    with factory() as db:
        practice = db.get(PracticeSession, UUID(prepared.session["id"]))
        row = db.get(RealtimeConnection, UUID(connection["id"]))
        check = db.get(TerminationCheck, row.id)
        return (
            practice.status,
            row.status,
            row.termination_status,
            row.state_reason,
            row.signalling_finished_at,
            check,
        )


def test_logout_cannot_prevent_unknown_finalization(factory, app, prepared, scope):
    connection, _, auth_id = scope
    attempt = claim(factory, prepared, scope, Gateway(), app.state.practice_admission)
    with factory.begin() as db:
        db.execute(update(AuthSession).where(AuthSession.id == auth_id).values(revoked_at=now()))
    assert mark_websocket_unknown(factory, attempt, "auth_lost") is True
    practice, status, termination, reason, finished, check = state(factory, prepared, connection)
    assert (practice, status, termination, reason) == (
        "interrupted",
        "unknown",
        "unknown",
        "websocket_auth_lost",
    )
    assert (
        finished is not None
        and check.status == "blocked"
        and check.attempt_digest == attempt.fingerprint
    )
    assert mark_websocket_unknown(factory, attempt, "network_failed") is False
    again = state(factory, prepared, connection)
    assert again[3:5] == (reason, finished)


def test_concurrent_finalization_is_idempotent(factory, app, prepared, scope):
    attempt = claim(factory, prepared, scope, Gateway(), app.state.practice_admission)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(
            pool.map(lambda _: mark_websocket_unknown(factory, attempt, "disconnected"), range(2))
        )
    assert sorted(results) == [False, True]
    assert state(factory, prepared, scope[0])[5].status == "blocked"


def test_wrong_fingerprint_or_identity_cannot_change_connection(factory, app, prepared, scope):
    attempt = claim(factory, prepared, scope, Gateway(), app.state.practice_admission)
    for forged in (
        replace(attempt, fingerprint="a" * 64),
        replace(attempt, client_instance_id=uuid4()),
    ):
        with pytest.raises(APIError):
            mark_websocket_unknown(factory, forged, "cancelled")
    assert state(factory, prepared, scope[0])[1:4] == (
        "negotiating",
        "unknown",
        "websocket_started",
    )
    assert state(factory, prepared, scope[0])[5] is None


def test_invalid_reason_and_confirmed_terminal_state_are_not_overwritten(
    factory, app, prepared, scope
):
    attempt = claim(factory, prepared, scope, Gateway(), app.state.practice_admission)
    with pytest.raises(APIError):
        mark_websocket_unknown(factory, attempt, "arbitrary user message")
    connection = scope[0]
    with factory.begin() as db:
        row = db.get(RealtimeConnection, UUID(connection["id"]))
        row.status = "closed"
        row.termination_status = "confirmed"
        row.ended_at = now()
    with pytest.raises(APIError):
        mark_websocket_unknown(factory, attempt, "cancelled")
    assert state(factory, prepared, connection)[1:3] == ("closed", "confirmed")


def test_recomputed_but_stale_epoch_and_bad_reason_do_not_mutate(factory, app, prepared, scope):
    from simontalk_api.websocket_claim import _fingerprint

    attempt = claim(factory, prepared, scope, Gateway(), app.state.practice_admission)
    stale_epoch = attempt.epoch + 1
    stale = replace(
        attempt,
        epoch=stale_epoch,
        fingerprint=_fingerprint(
            attempt.user_id,
            attempt.session_id,
            attempt.connection_id,
            attempt.client_instance_id,
            stale_epoch,
        ),
    )
    with pytest.raises(APIError):
        mark_websocket_unknown(factory, stale, "cancelled")
    with pytest.raises(APIError):
        mark_websocket_unknown(factory, attempt, [])
    assert state(factory, prepared, scope[0])[1:4] == (
        "negotiating",
        "unknown",
        "websocket_started",
    )


def test_conflicting_termination_evidence_is_never_overwritten(factory, app, prepared, scope):
    attempt = claim(factory, prepared, scope, Gateway(), app.state.practice_admission)
    with factory.begin() as db:
        db.add(
            TerminationCheck(
                connection_id=attempt.connection_id,
                client_instance_id=attempt.client_instance_id,
                epoch=attempt.epoch,
                attempt_digest="a" * 64,
                status="blocked",
                reason="capability_unavailable",
                attempts=0,
                created_at=now(),
            )
        )
    with pytest.raises(APIError):
        mark_websocket_unknown(factory, attempt, "network_failed")
    observed = state(factory, prepared, scope[0])
    assert observed[1] == "negotiating" and observed[5].attempt_digest == "a" * 64
