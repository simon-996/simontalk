import asyncio
from datetime import timedelta
from threading import Event
from uuid import UUID, uuid4

import pytest
from test_connection_reservations import prepared as prepared
from test_practice_deletion import erase, snapshot
from test_saved_transcripts import event, reserve, upload

from simontalk_api import assistance
from simontalk_api.assistance import StarterGeneration, run_assistance_batch
from simontalk_api.models import AssistanceAttempt, AssistanceJob, RealtimeConnection
from simontalk_api.review_gateway import ReviewGatewayError, ReviewUsage
from simontalk_api.security import now


def ready(client, prepared, factory):
    connection = reserve(client, prepared)
    with factory.begin() as db:
        row = db.get(RealtimeConnection, UUID(connection["id"]))
        row.status = "configuring"
        row.termination_status = "unknown"
        row.offer_digest = "a" * 64
        row.signalling_started_at = row.signalling_finished_at = row.created_at
    return connection


def address(prepared):
    return f"/v1/practice-sessions/{prepared.session['id']}/assistance"


def params(connection):
    return {"connection_id": connection["id"], "epoch": connection["epoch"]}


def test_context_is_owner_bound_and_tracks_final_text(client, prepared, factory, signup):
    connection = ready(client, prepared, factory)
    url = address(prepared) + "/context"
    response = client.get(url, params=params(connection), headers=prepared.headers)
    assert response.status_code == 200
    initial = response.json()
    assert initial["can_generate"] is False
    assert len(initial["input_revision"]) == 64
    upload(client, prepared, connection, [event(text="I like reading.")])
    updated = client.get(url, params=params(connection), headers=prepared.headers)
    assert updated.status_code == 200
    assert updated.json()["input_revision"] != initial["input_revision"]
    assert "I like reading." not in updated.text
    other = signup("other")
    outsider = client.get(
        url, params=params(connection), headers={"Authorization": f"Bearer {other['access_token']}"}
    )
    assert outsider.status_code == 404
    post = client.post(
        address(prepared),
        headers=prepared.headers | {"Idempotency-Key": str(uuid4())},
        json=params(connection)
        | {"kind": "english_starter", "input_revision": updated.json()["input_revision"]},
    )
    assert post.status_code == 503


class TestGateway:
    __test__ = False
    assistance_binding = "starter-fixture-v1"
    translation_binding = "translation-fixture-v1"

    def __init__(self):
        self.sources = []
        self.before_response = lambda: None
        self.error = None

    async def english_starter(self, source):
        self.sources.append(source)
        self.before_response()
        if self.error:
            raise self.error
        return StarterGeneration("One thing I like about it is...", ReviewUsage(12, 8))

    async def translate_turn(self, source):
        self.sources.append(source)
        translation = {
            "What will you read?": "你打算读什么？",
            "I like reading novels.": "我喜欢读小说。",
        }[source.text]
        return assistance.TranslationGeneration(translation, ReviewUsage(15, 7))


@pytest.fixture
def live(client, prepared, factory, app):
    app.state.assistance_job_runner.stop()
    gateway = app.state.assistance_gateway = TestGateway()
    connection = ready(client, prepared, factory)
    return connection, gateway


def request_body(client, prepared, connection):
    data = client.get(
        address(prepared) + "/context", params=params(connection), headers=prepared.headers
    ).json()
    return params(connection) | {
        "kind": "english_starter",
        "input_revision": data["input_revision"],
    }


def submit(client, prepared, body, *, key=None, suffix=""):
    return client.post(
        address(prepared) + suffix,
        headers=prepared.headers | {"Idempotency-Key": str(key or uuid4())},
        json=body,
    )


def test_dedupes_and_counts_only_provider_attempts(client, prepared, factory, live):
    connection, gateway = live
    upload(client, prepared, connection, [event(text="I like novels.")])
    body = request_body(client, prepared, connection)
    first_key = uuid4()
    queued = submit(client, prepared, body, key=first_key)
    assert queued.status_code == 202, queued.text
    job = queued.json()
    assert job["status"] == "queued"
    assert submit(client, prepared, body).json()["id"] == job["id"]
    asyncio.run(run_assistance_batch(factory, gateway))
    assert [s.turns for s in gateway.sources] == [("I like novels.",)]
    done = client.get(address(prepared) + "/" + job["id"], headers=prepared.headers)
    assert done.json()["starter"] == "One thing I like about it is..."
    assert submit(client, prepared, body, key=first_key).json() == done.json()
    usage = client.get("/v1/usage?include_assistance=true", headers=prepared.headers).json()
    assert usage["assistance"] == {
        "attempt_count": 1,
        "incomplete_count": 0,
        "known_input_tokens": 12,
        "known_output_tokens": 8,
        "deleted_attempt_count": 0,
    }
    upload(client, prepared, connection, [event(2, text="I prefer poetry.")])
    assert (
        client.get(address(prepared) + "/" + job["id"], headers=prepared.headers).status_code == 409
    )
    assert submit(client, prepared, body).status_code == 409
    changed = request_body(client, prepared, connection)
    assert submit(client, prepared, changed, key=first_key).json()["code"] == "idempotency_conflict"


@pytest.mark.parametrize("known", [True, False])
def test_retry_requires_a_known_failure(client, prepared, factory, live, known):
    connection, gateway = live
    gateway.error = ReviewGatewayError() if known else TimeoutError()
    body = request_body(client, prepared, connection)
    job = submit(client, prepared, body).json()
    asyncio.run(run_assistance_batch(factory, gateway))
    done = client.get(address(prepared) + "/" + job["id"], headers=prepared.headers).json()
    assert done["status"] == ("failed" if known else "unknown")
    assert done["can_retry"] is known
    response = submit(client, prepared, body | {"attempt_count": 1}, suffix=f"/{job['id']}/retry")
    assert response.status_code == (202 if known else 409)
    gateway.error = None
    asyncio.run(run_assistance_batch(factory, gateway))
    assert len(gateway.sources) == (2 if known else 1)


def test_deletion_in_flight_erases_text_but_counts_usage(client, prepared, factory, live):
    connection, gateway = live
    job = submit(client, prepared, request_body(client, prepared, connection)).json()
    sid, headers = prepared.session["id"], prepared.headers
    deletion_scope = snapshot(client, sid, headers)

    def delete_practice():
        assert erase(client, sid, headers, deletion_scope).status_code == 200

    gateway.before_response = delete_practice
    asyncio.run(run_assistance_batch(factory, gateway))
    with factory() as db:
        stored = db.get(AssistanceJob, UUID(job["id"]))
        attempt = db.get(AssistanceAttempt, (stored.id, 1))
        assert stored.result is None and stored.status == "expired"
        assert attempt.input_tokens == 12
    assert client.get(address(prepared) + "/" + job["id"], headers=headers).status_code == 404
    usage = client.get("/v1/usage?include_assistance=true", headers=headers).json()
    assert usage["assistance"]["deleted_attempt_count"] == 1


def test_ending_during_generation_keeps_usage_and_rejects_late_text(
    client, prepared, factory, live
):
    connection, gateway = live
    job = submit(client, prepared, request_body(client, prepared, connection)).json()
    call_path = f"/v1/practice-sessions/{prepared.session['id']}/connections/{connection['id']}"

    def end_practice():
        result = client.post(
            call_path + "/end",
            headers=prepared.headers | {"Idempotency-Key": str(uuid4())},
            json={
                "client_instance_id": connection["client_instance_id"],
                "epoch": connection["epoch"],
            },
        )
        assert result.status_code == 200, result.text

    gateway.before_response = end_practice
    asyncio.run(run_assistance_batch(factory, gateway))
    with factory() as db:
        stored = db.get(AssistanceJob, UUID(job["id"]))
        attempt = db.get(AssistanceAttempt, (stored.id, 1))
        assert stored.status == "expired" and stored.result is None
        assert (attempt.input_tokens, attempt.output_tokens) == (12, 8)
    read = client.get(address(prepared) + "/" + job["id"], headers=prepared.headers)
    assert read.status_code == 409


def test_expired_running_job_never_dispatches_again(client, prepared, factory, live):
    connection, gateway = live
    job = submit(client, prepared, request_body(client, prepared, connection)).json()
    with factory.begin() as db:
        row = db.get(AssistanceJob, UUID(job["id"]))
        row.status, row.attempt_count, row.deadline = "running", 1, now() - timedelta(seconds=1)
        db.add(AssistanceAttempt(job_id=row.id, number=1, started_at=row.deadline))
    asyncio.run(run_assistance_batch(factory, gateway))
    assert gateway.sources == []
    done = client.get(address(prepared) + "/" + job["id"], headers=prepared.headers).json()
    assert done["status"] == "unknown" and not done["can_retry"]


def test_shutdown_after_the_db_claim_prevents_provider_dispatch(
    client,
    prepared,
    factory,
    live,
    monkeypatch,
):
    connection, gateway = live
    job = submit(client, prepared, request_body(client, prepared, connection)).json()
    stop = Event()
    original = assistance._claim

    def stopped_after_claim(*args):
        result = original(*args)
        stop.set()
        return result

    monkeypatch.setattr(assistance, "_claim", stopped_after_claim)
    asyncio.run(run_assistance_batch(factory, gateway, stop=stop))
    assert gateway.sources == []
    with factory() as db:
        assert db.get(AssistanceAttempt, (UUID(job["id"]), 1)) is None


def test_logout_between_claim_and_dispatch_keeps_content_from_the_provider(
    client,
    prepared,
    factory,
    live,
    monkeypatch,
):
    connection, gateway = live
    job = submit(client, prepared, request_body(client, prepared, connection)).json()
    original = assistance._claim

    def revoke_after_claim(*args):
        result = original(*args)
        if result is not None:
            assert client.post("/v1/auth/logout", headers=prepared.headers).status_code == 204
        return result

    monkeypatch.setattr(assistance, "_claim", revoke_after_claim)
    asyncio.run(run_assistance_batch(factory, gateway))
    assert gateway.sources == []
    with factory() as db:
        assert db.get(AssistanceAttempt, (UUID(job["id"]), 1)) is None
        assert db.get(AssistanceJob, UUID(job["id"])).status == "expired"


def test_action_keys_are_bounded_but_old_keys_replay(client, prepared, live, monkeypatch):
    connection, _ = live
    monkeypatch.setattr(assistance, "_MAX_ACTION_KEYS", 2)
    body = request_body(client, prepared, connection)
    original_key = uuid4()
    assert submit(client, prepared, body, key=original_key).status_code == 202
    assert submit(client, prepared, body).status_code == 202
    assert submit(client, prepared, body).status_code == 429
    assert submit(client, prepared, body, key=original_key).status_code == 202


def test_queue_expiry_before_dispatch_can_retry_the_same_source(client, prepared, factory, live):
    connection, gateway = live
    body = request_body(client, prepared, connection)
    job = submit(client, prepared, body).json()
    with factory.begin() as db:
        row = db.get(AssistanceJob, UUID(job["id"]))
        row.deadline = now() - timedelta(seconds=1)
    asyncio.run(run_assistance_batch(factory, gateway))
    assert gateway.sources == []
    failed = client.get(address(prepared) + "/" + job["id"], headers=prepared.headers).json()
    assert failed["status"] == "failed" and failed["can_retry"] and failed["attempt_count"] == 0
    retry = submit(client, prepared, body | {"attempt_count": 0}, suffix=f"/{job['id']}/retry")
    assert retry.status_code == 202
    asyncio.run(run_assistance_batch(factory, gateway))
    assert len(gateway.sources) == 1


def test_translation_binds_the_selected_final_revision(client, prepared, factory, live):
    connection, gateway = live
    selected = event(text="I like reading novels.")
    upload(client, prepared, connection, [selected, event(2, text="Another unrelated turn.")])
    selection = {
        "kind": "translation",
        "source_turn_id": selected["turn_id"],
        "source_turn_revision": selected["revision"],
    }
    scope = params(connection) | selection
    result = client.get(address(prepared) + "/context", params=scope, headers=prepared.headers)
    assert result.status_code == 200, result.text
    assert result.json()["kind"] == "translation"
    body = scope | {"input_revision": result.json()["input_revision"]}
    job = submit(client, prepared, body).json()
    asyncio.run(run_assistance_batch(factory, gateway))
    assert [item.text for item in gateway.sources] == ["I like reading novels."]
    done = client.get(address(prepared) + "/" + job["id"], headers=prepared.headers).json()
    assert done["translation"] == "我喜欢读小说。"
    assert done["source_turn_id"] == selected["turn_id"]
    reused = client.get(address(prepared) + "/context", params=scope, headers=prepared.headers)
    assert reused.json()["job_id"] == job["id"]
    # A new unrelated final turn does not invalidate a pointed translation.
    upload(client, prepared, connection, [event(3, text="Unrelated.")])
    assert (
        client.get(address(prepared) + "/" + job["id"], headers=prepared.headers).status_code == 200
    )
    upload(
        client,
        prepared,
        connection,
        [
            event(
                4,
                turn_id=selected["turn_id"],
                turn_index=selected["turn_index"],
                revision=2,
                text="I like reading poems.",
            )
        ],
    )
    assert (
        client.get(address(prepared) + "/" + job["id"], headers=prepared.headers).status_code == 409
    )
