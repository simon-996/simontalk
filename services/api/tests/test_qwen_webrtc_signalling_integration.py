"""Real application/SQL composition; only the upstream HTTP transport is replaced."""

from types import SimpleNamespace
from uuid import uuid4

import httpx
import pytest
from conftest import TEST_URL
from fastapi.testclient import TestClient
from sqlalchemy import text
from test_connection_reservations import path, reserve
from test_practice_preparation import account as account
from test_qwen_webrtc_signalling import ANSWER, OFFER, Body, config, exchange_factory, settings
from test_signalling import connection_row

from simontalk_api import qwen_webrtc_signalling as qwen
from simontalk_api.config import Settings
from simontalk_api.main import create_app
from simontalk_api.practice import AdmissionPermit


class CandidateTestAdmission:
    """Explicit test injection, never a production admission implementation."""

    def admit(self, user_id):
        return AdmissionPermit(**config())


@pytest.fixture
def candidate(client, app, account):
    identity, headers = account
    app.state.practice_admission = CandidateTestAdmission()
    response = client.post(
        "/v1/practice-sessions",
        headers={**headers, "Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    )
    assert response.status_code == 201
    return SimpleNamespace(identity=identity, headers=headers, session=response.json())


def post_offer(client, candidate, connection):
    return client.post(
        path(candidate, connection, "/offer"),
        headers=candidate.headers,
        json={
            "client_instance_id": connection["client_instance_id"],
            "epoch": connection["epoch"],
            "offer": OFFER,
        },
    )


def check_unknown(factory, saved, reason):
    row = connection_row(factory, saved)
    assert (row["status"], row["termination_status"], row["state_reason"]) == (
        "unknown",
        "unknown",
        reason,
    )
    with factory() as db:
        check = db.execute(
            text("SELECT status, reason, attempts FROM termination_checks WHERE connection_id=:id"),
            {"id": saved["id"]},
        ).one()
    assert tuple(check) == ("blocked", "capability_unavailable", 0)


def test_candidate_success_binds_original_claim_and_duplicate_survives_restart(
    client,
    app,
    candidate,
    factory,
):
    saved = reserve(client, candidate).json()
    inspected = []

    async def dispatch(request):
        assert request.content == OFFER.encode()
        with factory.begin() as db:
            db.execute(text("SET LOCAL lock_timeout = '100ms'"))
            db.execute(
                text("SELECT id FROM realtime_connections WHERE id=:id FOR UPDATE"),
                {"id": saved["id"]},
            )
            row = db.execute(
                text(
                    "SELECT status, termination_status, offer_digest "
                    "FROM realtime_connections WHERE id=:id"
                ),
                {"id": saved["id"]},
            ).one()
            assert row[0:2] == ("negotiating", "unknown") and row[2] is not None
        inspected.append(True)

        return httpx.Response(
            200, headers={"Content-Type": "application/sdp"}, stream=Body([ANSWER])
        )

    body, calls, _, create = exchange_factory(handler=dispatch)
    app.state.signalling_gateway = qwen.QwenWebRtcSignallingGateway(
        settings(), client_factory=create
    )
    response = post_offer(client, candidate, saved)
    assert response.status_code == 200 and response.json()["answer"] == ANSWER.decode()
    row = connection_row(factory, saved)
    assert (row["status"], row["termination_status"]) == ("configuring", "unknown")
    assert "private-offer-marker" not in str(dict(row))
    assert inspected == [True]
    assert post_offer(client, candidate, saved).json()["code"] == "signalling_already_attempted"
    restarted = create_app(Settings(database_url=TEST_URL, environment="test"))
    restarted.state.practice_admission = CandidateTestAdmission()
    restarted.state.signalling_gateway = qwen.QwenWebRtcSignallingGateway(
        settings(), client_factory=create
    )
    try:
        with TestClient(restarted) as restarted_client:
            replay = post_offer(restarted_client, candidate, saved)
            assert (
                replay.status_code == 409
                and replay.json()["code"] == "signalling_already_attempted"
            )
    finally:
        restarted.state.engine.dispose()
    assert len(calls) == 1


@pytest.mark.parametrize(
    "change", [{"model": "qwen3.5-omni-plus-realtime"}, {"config_id": "candidate-v2"}]
)
def test_candidate_configuration_rejected_before_durable_claim(
    client, app, candidate, factory, change
):
    saved = reserve(client, candidate).json()
    app.state.signalling_gateway = qwen.QwenWebRtcSignallingGateway(
        settings(**change), client_factory=lambda: pytest.fail("No upstream client allowed")
    )
    rejected = post_offer(client, candidate, saved)
    assert rejected.status_code == 503 and rejected.json()["code"] == "realtime_unavailable"
    row = connection_row(factory, saved)
    assert row["offer_digest"] is None and row["signalling_started_at"] is None
    assert (row["status"], row["termination_status"]) == ("preparing", "not_started")
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM termination_checks")) == 0


@pytest.mark.parametrize("fault", ["rejected", "redirect", "invalid-answer", "oversized"])
def test_candidate_failed_exchange_stays_unknown_and_cannot_repeat(
    client, app, candidate, factory, fault
):
    saved = reserve(client, candidate).json()
    raw = b"v=0\n" + b"x" * 65536 if fault == "oversized" else b"invalid private-provider-body"
    body, calls, clients, create = exchange_factory(
        Body([raw]),
        status=503 if fault == "rejected" else 307 if fault == "redirect" else 200,
        headers={"Location": "https://other.invalid"},
    )
    app.state.signalling_gateway = qwen.QwenWebRtcSignallingGateway(
        settings(), client_factory=create
    )
    rejected = post_offer(client, candidate, saved)
    assert rejected.status_code == 502 and rejected.json()["code"] == "signalling_failed"
    assert "private-provider-body" not in rejected.text
    check_unknown(factory, saved, "signalling_failed")
    assert post_offer(client, candidate, saved).status_code == 409
    assert len(calls) == 1 and body.closed and clients[0].is_closed
    if fault in {"rejected", "redirect"}:
        assert body.reads == 0


def test_candidate_deadline_becomes_timeout_with_blocked_unknown(
    client, app, candidate, factory, monkeypatch
):
    saved = reserve(client, candidate).json()
    monkeypatch.setattr(qwen, "_EXCHANGE_TIMEOUT_SECONDS", 0.01)
    body, calls, clients, create = exchange_factory(Body([], stall=True))
    app.state.signalling_gateway = qwen.QwenWebRtcSignallingGateway(
        settings(), client_factory=create
    )
    result = post_offer(client, candidate, saved)
    assert result.status_code == 504 and result.json()["code"] == "signalling_timeout"
    check_unknown(factory, saved, "signalling_timeout")
    assert len(calls) == 1 and body.closed and clients[0].is_closed
