from uuid import uuid4

from test_connection_reservations import prepared as prepared
from test_final_transcripts import event
from test_review_inputs import create as create_input
from test_review_inputs import seal


def path(prepared):
    return f"/v1/practice-sessions/{prepared.session['id']}/review"


def ready(client, prepared, events=None):
    _, completion = seal(client, prepared, [event()] if events is None else events)
    response = create_input(client, prepared, completion)
    assert response.status_code == 200, response.text
    return response.json()


def create_job(client, prepared, source, *, key=None, **changes):
    return client.post(
        path(prepared),
        headers={**prepared.headers, "Idempotency-Key": str(key or uuid4())},
        json={
            key: source[key]
            for key in (
                "input_revision",
                "practice_input_hash",
                "review_input_hash",
                "policy_version",
            )
        }
        | changes,
    )


def test_ready_review_defaults_to_blocked_without_scheduling(client, prepared):
    result = create_job(client, prepared, ready(client, prepared))
    assert result.status_code == 202, result.text
    assert result.json()["status"] == "blocked"
    assert result.json()["error_code"] == "capability_unavailable"
    assert result.json()["attempt_count"] == 0


def retry(client, prepared, job, *, key=None, expected=None):
    return client.post(
        path(prepared) + "/retry",
        headers={**prepared.headers, "Idempotency-Key": str(key or uuid4())},
        json={
            "job_id": job["id"],
            "expected_attempts": (job["attempt_count"] if expected is None else expected),
        },
    )


def test_read_is_pure_and_action_aliases_are_durable(client, prepared, factory):
    from sqlalchemy import text

    source = ready(client, prepared)
    assert (
        client.get(path(prepared), headers=prepared.headers).json()["code"]
        == "review_job_not_found"
    )
    key = uuid4()
    first = create_job(client, prepared, source, key=key)
    assert first.status_code == 202
    assert create_job(client, prepared, source, key=key).json() == first.json()
    assert create_job(client, prepared, source).json() == first.json()
    assert client.get(path(prepared), headers=prepared.headers).json() == first.json()
    assert first.headers["Cache-Control"] == "no-store"
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_jobs")) == 1
        assert db.scalar(text("SELECT count(*) FROM review_actions")) == 2
        assert db.scalar(text("SELECT count(*) FROM review_attempts")) == 0
    assert (
        create_job(client, prepared, source, key=key, input_revision=2).json()["code"]
        == "idempotency_conflict"
    )
    assert retry(client, prepared, first.json(), key=key).json()["code"] == "idempotency_conflict"


def test_empty_input_terminal_and_unavailable_retry_remains_zero(client, prepared):
    job = create_job(client, prepared, ready(client, prepared, [])).json()
    assert job["status"] == "no_evaluable_content" and job["attempt_count"] == 0
    assert retry(client, prepared, job).json() == job


def test_retry_requires_expected_count_and_replays_actions(client, prepared):
    source = ready(client, prepared)
    job = create_job(client, prepared, source).json()
    assert retry(client, prepared, job, expected=1).json()["code"] == "review_retry_changed"
    key = uuid4()
    assert retry(client, prepared, job, key=key).status_code == 202
    assert retry(client, prepared, job, key=key).json()["attempt_count"] == 0


def test_missing_input_and_foreign_access_fail_closed(client, prepared, signup):
    from types import SimpleNamespace

    source = ready(client, prepared)
    assert (
        create_job(client, prepared, source, review_input_hash="b" * 64).json()["code"]
        == "review_input_changed"
    )
    other = signup("bob")
    foreign = SimpleNamespace(
        session=prepared.session, headers={"Authorization": f"Bearer {other['access_token']}"}
    )
    assert create_job(client, foreign, source).json()["code"] == "practice_not_found"
    assert client.get(path(foreign), headers=foreign.headers).status_code == 404
    assert client.get(path(prepared)).status_code == 401


def test_both_post_bodies_are_bounded_before_json(client, prepared):
    for suffix in ("", "/retry"):
        result = client.post(path(prepared) + suffix, headers=prepared.headers, content=b"x" * 8193)
        assert result.status_code == 413


def test_concurrent_creation_serializes_aliases(client, prepared, factory):
    from concurrent.futures import ThreadPoolExecutor

    from sqlalchemy import text

    source = ready(client, prepared)
    with ThreadPoolExecutor(max_workers=2) as pool:
        replies = list(pool.map(lambda _: create_job(client, prepared, source), range(2)))
    assert all(r.status_code == 202 for r in replies)
    assert replies[0].json() == replies[1].json()
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_actions")) == 2


def test_waiting_owner_lock_revalidates_revoked_session(client, prepared, factory):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    from sqlalchemy import text

    source = ready(client, prepared)
    started = Event()

    def request():
        started.set()
        return create_job(client, prepared, source)

    with ThreadPoolExecutor(max_workers=1) as pool:
        with factory.begin() as db:
            db.execute(text("SELECT id FROM users FOR UPDATE"))
            pending = pool.submit(request)
            assert started.wait(1)
            # Wait until the request really reached its owner lock, avoiding timing guesses.
            import time

            for _ in range(100):
                with factory() as observer:
                    waiting = observer.scalar(
                        text(
                            "SELECT count(*) FROM pg_stat_activity "
                            "WHERE datname=current_database() AND wait_event_type='Lock'"
                        )
                    )
                if waiting:
                    break
                time.sleep(0.01)
            assert waiting
            db.execute(text("UPDATE auth_sessions SET revoked_at=now()"))
        result = pending.result(timeout=3)
    assert result.status_code == 401
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM review_jobs")) == 0


def test_job_writes_require_web_csrf_account_binding(client, app, signup):
    from types import SimpleNamespace

    from test_connection_reservations import TestAdmission

    headers = {"Origin": "http://localhost:7357"}
    headers["X-CSRF-Token"] = client.get("/v1/auth/csrf", headers=headers).json()["csrf_token"]
    identity = signup(platform="web", headers=headers)
    headers["X-Account-ID"] = identity["user"]["id"]
    client.patch(
        "/v1/me/preferences", headers=headers, json={"version": 1, "difficulty": "beginner"}
    )
    app.state.practice_admission = TestAdmission()
    session = client.post(
        "/v1/practice-sessions",
        headers=headers | {"Idempotency-Key": str(uuid4())},
        json={"mode": "free_chat"},
    ).json()
    scope = SimpleNamespace(session=session, headers=headers, identity=identity)
    source = ready(client, scope)
    for missing, expected in [("Origin", 403), ("X-CSRF-Token", 403), ("X-Account-ID", 409)]:
        scope.headers = {k: v for k, v in headers.items() if k != missing}
        assert create_job(client, scope, source).status_code == expected
    scope.headers = headers
    job = create_job(client, scope, source).json()
    for missing, expected in [("Origin", 403), ("X-CSRF-Token", 403), ("X-Account-ID", 409)]:
        scope.headers = {k: v for k, v in headers.items() if k != missing}
        assert retry(client, scope, job).status_code == expected
