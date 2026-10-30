"""API/DB engineering rehearsal. No real speech, device playback or language model."""

from uuid import uuid4

from sqlalchemy import text
from test_connection_reservations import reserve
from test_practice_deletion import erase, snapshot
from test_practice_preparation import account as account
from test_qwen_webrtc_signalling import exchange_factory, settings
from test_qwen_webrtc_signalling_integration import candidate as candidate
from test_qwen_webrtc_signalling_integration import post_offer
from test_review_inputs import create as create_input
from test_review_jobs import create_job, path, retry
from test_review_worker import Gateway, batch
from test_saved_transcripts import base, event, read, seal

from simontalk_api.qwen_webrtc_signalling import QwenWebRtcSignallingGateway


def test_candidate_to_sealed_review_history_deletion_keeps_unknown_and_owner_isolation(
    client,
    app,
    candidate,
    signup,
    factory,
):
    # This fixture really registers A and saves preferences over the API; admission
    # is explicitly replaced only in this test application, never in create_app.
    saved = reserve(client, candidate).json()
    _, calls, _, create = exchange_factory()
    app.state.signalling_gateway = QwenWebRtcSignallingGateway(settings(), client_factory=create)
    assert post_offer(client, candidate, saved).status_code == 200

    # Client-reported sample text, not provider transcription or proof of speech.
    original = event(text="I enjoy coffee. 这是一段隔离测试文字。")
    _, completion = seal(client, candidate, [original], connection=saved, tail_status="unconfirmed")
    assert completion["status"] == "sealed" and completion["coverage"] == "incomplete"
    assert completion["gap_codes"] == ["tail_unconfirmed"]
    detail_url = f"/v1/practice-history/{candidate.session['id']}"
    detail = client.get(detail_url, headers=candidate.headers).json()["item"]
    assert detail["completion_status"] == "sealed" and detail["connection_pending"] is True
    transcript = read(client, candidate, completion).json()
    assert transcript["items"][0]["final_text"] == original["text"]
    assert transcript["coverage"] == "incomplete"

    # Default generation stays blocked; only an explicit fixture gateway plus an
    # explicit retry schedules the production worker and validates exact quotes.
    source = create_input(client, candidate, completion).json()
    blocked = create_job(client, candidate, source).json()
    assert blocked["status"] == "blocked" and blocked["attempt_count"] == 0
    assert batch(factory, app.state.review_gateway) == 0
    gateway = Gateway()
    app.state.review_gateway = gateway
    retry_key = uuid4()
    queued = retry(client, candidate, blocked, key=retry_key)
    assert queued.status_code == 202 and queued.json()["status"] == "queued"
    assert batch(factory, gateway) == 1
    reviewed = client.get(path(candidate), headers=candidate.headers).json()
    assert reviewed["status"] == "succeeded" and reviewed["attempt_count"] == 1
    item = reviewed["result"]["items"][0]
    assert item["exact_quote"] == original["text"] and len(gateway.calls) == 1
    focused = read(client, candidate, completion, review_item_id=item["id"]).json()
    assert focused["focus"]["exact_quote"] == original["text"]
    assert focused["items"][0]["turn_id"] == original["turn_id"]
    assert client.get(path(candidate), headers=candidate.headers).json() == reviewed
    assert batch(factory, gateway) == 0 and len(gateway.calls) == 1

    target_url = base(candidate) + f"/review-items/{item['id']}/rehearsal-target"
    target = client.get(target_url, headers=candidate.headers)
    assert target.status_code == 200 and target.json()["source_text"] == original["text"]
    blocked_child = client.post(
        target_url.replace("/rehearsal-target", "/rehearsals"),
        headers=candidate.headers | {"Idempotency-Key": str(uuid4())},
        json={"target_hash": target.json()["target_hash"]},
    )
    assert blocked_child.status_code == 409
    assert blocked_child.json()["code"] == "practice_in_progress"

    # A separate account cannot read A, and A's unknown connection does not own B.
    other = signup("flow_bob")
    other_headers = {"Authorization": f"Bearer {other['access_token']}"}
    assert client.get(detail_url, headers=other_headers).status_code == 404
    assert (
        read(
            client, type(candidate)(session=candidate.session, headers=other_headers), completion
        ).status_code
        == 404
    )
    assert (
        client.patch(
            "/v1/me/preferences",
            headers=other_headers,
            json={"version": 1, "difficulty": "advanced"},
        ).status_code
        == 200
    )
    other_practice = client.post(
        "/v1/practice-sessions",
        headers=other_headers | {"Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    )
    assert other_practice.status_code == 201
    other_id = other_practice.json()["id"]
    assert (
        client.get("/v1/practice-history", headers=other_headers).json()["items"][0]["id"]
        == other_id
    )
    assert (
        client.get("/v1/practice-history", headers=candidate.headers).json()["items"][0]["id"]
        == candidate.session["id"]
    )

    scope = snapshot(client, candidate.session["id"], candidate.headers)
    assert scope["connection_pending"] is True
    delete_key = uuid4()
    receipt = erase(client, candidate.session["id"], candidate.headers, scope, delete_key)
    assert receipt.status_code == 200 and receipt.json()["connection_pending"] is True
    assert (
        erase(client, candidate.session["id"], candidate.headers, scope, delete_key).json()
        == receipt.json()
    )
    assert client.get("/v1/practice-history", headers=candidate.headers).json()["items"] == []
    for suffix in ["/completion", "/review-input", "/review"]:
        assert client.get(base(candidate) + suffix, headers=candidate.headers).status_code == 404
    assert read(client, candidate, completion).status_code == 404
    assert client.get(detail_url, headers=candidate.headers).status_code == 404
    assert client.get(target_url, headers=candidate.headers).status_code == 404
    assert client.get(f"/v1/practice-history/{other_id}", headers=other_headers).status_code == 200
    current = client.get("/v1/practice-sessions/current", headers=candidate.headers).json()
    assert current["practice"]["state_reason"] == "content_deleted"
    assert current["connection"]["status"] == "unknown"
    refused = client.post(
        "/v1/practice-sessions",
        headers=candidate.headers | {"Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    )
    assert refused.status_code == 409 and refused.json()["code"] == "practice_in_progress"
    assert batch(factory, gateway) == 0 and len(gateway.calls) == 1 and len(calls) == 1
    with factory() as db:
        for table in ["final_transcripts", "review_results", "review_inputs", "review_jobs"]:
            assert db.scalar(text(f"SELECT count(*) FROM {table}")) == 0
        check = db.execute(
            text("SELECT status, attempts FROM termination_checks WHERE connection_id=:id"),
            {"id": saved["id"]},
        ).one()
        assert tuple(check) == ("blocked", 0)
