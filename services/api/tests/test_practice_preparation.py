import uuid
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from time import monotonic, sleep
from types import SimpleNamespace

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError


def start(client, headers, *, key=None, **body):
    return client.post(
        "/v1/practice-sessions",
        headers={**headers, "Idempotency-Key": str(key or uuid.uuid4())},
        json={"mode": "free_chat", **body},
    )


def row_count(factory):
    with factory() as db:
        return db.scalar(text("SELECT count(*) FROM practice_sessions"))


def wait_for_row_lock(factory, table):
    # Observe the real PostgreSQL wait, rather than inferring it from a callback
    # that runs before the SELECT has reached the database.
    deadline = monotonic() + 5
    with factory() as observer:
        while monotonic() < deadline:
            waiting = observer.scalar(
                text(
                    "SELECT EXISTS (SELECT 1 FROM pg_stat_activity "
                    "WHERE datname=current_database() AND pid<>pg_backend_pid() "
                    "AND wait_event_type='Lock' AND query LIKE :query)"
                ),
                {"query": f"%FROM {table}%FOR UPDATE%"},
            )
            observer.rollback()  # Refresh PostgreSQL's statistics snapshot.
            if waiting:
                return
            sleep(0.01)
    raise AssertionError(f"Request did not wait for the {table} row lock")


@pytest.fixture
def account(client, signup):
    identity = signup()
    headers = {"Authorization": f"Bearer {identity['access_token']}"}
    response = client.patch(
        "/v1/me/preferences", headers=headers, json={"version": 1, "difficulty": "beginner"}
    )
    assert response.status_code == 200
    return identity, headers


@pytest.fixture
def admission(app):
    # Only this test application accepts an explicit, non-network test policy.
    class TestAdmission:
        def admit(self, user_id):
            return SimpleNamespace(
                provider="test-only", region="test", model="test-model", config_id="test-v1"
            )

    app.state.practice_admission = TestAdmission()


def test_unconfigured_voice_rejects_without_writing_a_practice(client, account, factory):
    _, headers = account
    response = start(client, headers)
    assert response.status_code == 503
    assert response.json()["code"] == "realtime_unavailable"
    assert row_count(factory) == 0


def test_snapshot_and_idempotent_replay_survive_preference_and_policy_changes(
    client, app, account, admission
):
    _, headers = account
    key = uuid.uuid4()
    first = start(client, headers, key=key)
    assert first.status_code == 201, first.text
    saved = first.json()
    assert saved["status"] == "created"
    assert saved["configuration"]["preferences"]["difficulty"] == "beginner"
    assert saved["configuration"]["provider"]["model"] == "test-model"
    assert (
        client.patch(
            "/v1/me/preferences", headers=headers, json={"version": 2, "difficulty": "advanced"}
        ).status_code
        == 200
    )
    from simontalk_api.practice import UnavailableAdmission

    app.state.practice_admission = UnavailableAdmission()
    replay = start(client, headers, key=key)
    assert replay.status_code == 201
    assert replay.json() == saved
    detail = client.get(f"/v1/practice-sessions/{saved['id']}", headers=headers)
    assert detail.json() == saved


def test_same_key_different_input_conflicts(client, account, admission, factory):
    _, headers = account
    key = uuid.uuid4()
    assert start(client, headers, key=key).status_code == 201
    conflict = start(client, headers, key=key, difficulty_override="advanced")
    assert conflict.status_code == 409
    assert conflict.json()["code"] == "idempotency_conflict"
    assert row_count(factory) == 1


def test_daily_topic_is_validated_frozen_and_owner_scoped(client, account, signup, admission):
    _, headers = account
    key = uuid.uuid4()
    first = start(client, headers, key=key, mode="daily_topic", topic_id="weekend_plans")
    assert first.status_code == 201, first.text
    saved = first.json()
    assert saved["mode"] == "daily_topic" and saved["kind"] == "ordinary"
    assert saved["configuration"]["topic"]["title"] == "周末计划"
    assert (
        start(client, headers, key=key, mode="daily_topic", topic_id="weekend_plans").json()
        == saved
    )
    assert start(client, headers, key=key, mode="daily_topic", topic_id="food").status_code == 409
    assert start(client, headers, key=key).status_code == 409
    assert client.get("/v1/practice-sessions/current", headers=headers).json()["practice"] == saved
    history = f"/v1/practice-history/{saved['id']}"
    detail = client.get(history, headers=headers).json()["item"]
    assert detail["topic"] == {
        "id": "weekend_plans",
        "title": "周末计划",
        "goal": "分享一个周末安排",
    }
    stranger = {"Authorization": f"Bearer {signup(username='other')['access_token']}"}
    assert client.get(history, headers=stranger).status_code == 404


@pytest.mark.parametrize(
    "body",
    [
        {"mode": "daily_topic"},
        {"mode": "daily_topic", "topic_id": "made_up"},
        {"mode": "free_chat", "topic_id": "food"},
        {"mode": "daily_topic", "topic_id": "food", "prompt": "user instructions"},
    ],
)
def test_invalid_topic_preparation_writes_nothing(client, account, admission, factory, body):
    assert start(client, account[1], **body).status_code == 422
    assert row_count(factory) == 0


def test_different_keys_cannot_open_two_preparations(client, account, admission):
    _, headers = account
    assert start(client, headers).status_code == 201
    response = start(client, headers)
    assert response.status_code == 409
    assert response.json()["code"] == "practice_in_progress"


def test_initial_difficulty_is_required_even_with_override(client, signup, admission, factory):
    identity = signup()
    response = start(
        client,
        {"Authorization": f"Bearer {identity['access_token']}"},
        difficulty_override="advanced",
    )
    assert response.status_code == 409
    assert response.json()["code"] == "preferences_required"
    assert row_count(factory) == 0


def test_other_account_cannot_read_or_cancel_and_keys_are_user_scoped(
    client, account, signup, admission, factory
):
    _, first_headers = account
    key = uuid.uuid4()
    first = start(client, first_headers, key=key).json()
    second = signup("bob")
    second_headers = {"Authorization": f"Bearer {second['access_token']}"}
    assert (
        client.patch(
            "/v1/me/preferences",
            headers=second_headers,
            json={"version": 1, "difficulty": "advanced"},
        ).status_code
        == 200
    )
    for method, suffix in [("GET", ""), ("POST", "/cancel-preparation")]:
        response = client.request(
            method, f"/v1/practice-sessions/{first['id']}{suffix}", headers=second_headers
        )
        assert response.status_code == 404
    assert start(client, second_headers, key=key).status_code == 201
    assert row_count(factory) == 2


def test_preparation_cancel_is_idempotent_and_allows_a_new_registration(client, account, admission):
    _, headers = account
    key = uuid.uuid4()
    created = start(client, headers, key=key).json()
    path = f"/v1/practice-sessions/{created['id']}/cancel-preparation"
    cancelled = client.post(path, headers=headers)
    assert cancelled.status_code == 200
    assert cancelled.json()["status"] == "cancelled"
    assert cancelled.json()["ended_at"] is not None
    assert client.post(path, headers=headers).json() == cancelled.json()
    assert start(client, headers, key=key).json() == cancelled.json()
    assert start(client, headers).status_code == 201


def test_connecting_is_not_misreported_as_upstream_terminated(client, account, admission, factory):
    _, headers = account
    created = start(client, headers).json()
    with factory.begin() as db:
        db.execute(
            text("UPDATE practice_sessions SET status='connecting' WHERE id=:id"),
            {"id": created["id"]},
        )
    response = client.post(
        f"/v1/practice-sessions/{created['id']}/cancel-preparation", headers=headers
    )
    assert response.status_code == 409
    assert response.json()["code"] == "preparation_not_cancellable"
    assert start(client, headers).status_code == 409


def test_concurrent_different_keys_create_at_most_one_practice(client, account, admission, factory):
    _, headers = account
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda _: start(client, headers), range(2)))
    assert sorted(response.status_code for response in responses) == [201, 409]
    assert row_count(factory) == 1


def test_request_cannot_supply_owner_or_provider_config(client, account, admission, factory):
    _, headers = account
    assert start(client, headers, user_id=str(uuid.uuid4())).status_code == 422
    assert start(client, headers, provider={"url": "https://example.invalid"}).status_code == 422
    assert row_count(factory) == 0


def test_web_creation_keeps_csrf_and_account_binding(client, signup, admission):
    origin = {"Origin": "http://localhost:7357"}
    csrf = client.get("/v1/auth/csrf", headers=origin).json()["csrf_token"]
    headers = {**origin, "X-CSRF-Token": csrf}
    identity = signup(platform="web", headers=headers)
    headers["X-Account-ID"] = identity["user"]["id"]
    assert (
        client.patch(
            "/v1/me/preferences", headers=headers, json={"version": 1, "difficulty": "beginner"}
        ).status_code
        == 200
    )
    assert (
        start(client, {k: v for k, v in headers.items() if k != "X-CSRF-Token"}).status_code == 403
    )
    assert (
        start(client, {k: v for k, v in headers.items() if k != "X-Account-ID"}).status_code == 409
    )
    assert start(client, headers).status_code == 201


def test_web_preflight_accepts_only_the_added_idempotency_header(client):
    response = client.options(
        "/v1/practice-sessions",
        headers={
            "Origin": "http://localhost:7357",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": (
                "content-type,x-csrf-token,x-account-id,idempotency-key"
            ),
        },
    )
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "http://localhost:7357"


def test_concurrent_same_key_replays_one_persistent_registration(
    client, account, admission, factory
):
    _, headers = account
    key = uuid.uuid4()
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda _: start(client, headers, key=key), range(2)))
    assert [response.status_code for response in responses] == [201, 201]
    assert responses[0].json() == responses[1].json()
    assert row_count(factory) == 1


def test_database_constraint_also_rejects_a_second_open_record(client, account, admission, factory):
    _, headers = account
    created = start(client, headers).json()
    with pytest.raises(IntegrityError) as caught, factory.begin() as db:
        db.execute(
            text(
                "INSERT INTO practice_sessions "
                "(id,user_id,creation_key,request_digest,mode,status,configuration) "
                "SELECT :new_id,user_id,:key,request_digest,mode,status,configuration "
                "FROM practice_sessions WHERE id=:source"
            ),
            {"new_id": uuid.uuid4(), "key": uuid.uuid4(), "source": uuid.UUID(created["id"])},
        )
    assert caught.value.orig.diag.constraint_name == "one_open_practice_per_user"
    assert row_count(factory) == 1


def test_override_is_effective_without_rewriting_saved_preferences(client, account, admission):
    _, headers = account
    created = start(client, headers, difficulty_override="advanced").json()
    assert created["configuration"]["effective_difficulty"] == "advanced"
    assert created["configuration"]["preferences"]["difficulty"] == "beginner"
    assert client.get("/v1/me/preferences", headers=headers).json()["difficulty"] == "beginner"


def test_authentication_and_uuid_key_remain_required(client, account):
    assert start(client, {}).status_code == 401
    _, headers = account
    assert (
        client.post(
            "/v1/practice-sessions", headers=headers, json={"mode": "free_chat"}
        ).status_code
        == 422
    )
    assert start(client, headers, key="not-a-uuid").status_code == 422


@pytest.mark.parametrize("action", ["revoke", "disable"])
def test_authentication_is_rechecked_after_owner_lock_wait(
    client, account, admission, factory, monkeypatch, action
):
    from simontalk_api import practice_routes

    identity, headers = account
    checked = Event()
    original = practice_routes.session_identity

    def observed(request, db):
        result = original(request, db)
        checked.set()
        return result

    monkeypatch.setattr(practice_routes, "session_identity", observed)
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        user_id = uuid.UUID(identity["user"]["id"])
        holder.execute(text("SELECT id FROM users WHERE id=:id FOR UPDATE"), {"id": user_id})
        pending = pool.submit(start, client, headers)
        assert checked.wait(5), "Request did not reach its first identity check"
        wait_for_row_lock(factory, "users")
        if action == "disable":
            holder.execute(text("UPDATE users SET disabled_at=now() WHERE id=:id"), {"id": user_id})
        else:
            holder.execute(
                text("UPDATE auth_sessions SET revoked_at=now() WHERE user_id=:id"), {"id": user_id}
            )
        holder.commit()
        assert pending.result(timeout=5).status_code == 401
    assert row_count(factory) == 0


def test_a_new_application_instance_replays_persistent_registration(
    client, app, account, admission
):
    from fastapi.testclient import TestClient

    from simontalk_api.config import Settings
    from simontalk_api.main import create_app

    _, headers = account
    key = uuid.uuid4()
    saved = start(client, headers, key=key).json()
    another = create_app(Settings(database_url=app.state.settings.database_url, environment="test"))
    try:
        with TestClient(another) as second:
            # The new instance has the default closed policy, not the test permit.
            assert start(second, headers, key=key).json() == saved
            assert (
                second.get(f"/v1/practice-sessions/{saved['id']}", headers=headers).json() == saved
            )
    finally:
        another.state.engine.dispose()


def test_cancel_cannot_overwrite_a_connection_transition_while_waiting_for_its_row(
    client, account, admission, factory, monkeypatch
):
    from simontalk_api import practice

    _, headers = account
    created = start(client, headers).json()
    reached = Event()
    original = practice.own_preparation

    def observed(*args, **kwargs):
        reached.set()
        return original(*args, **kwargs)

    monkeypatch.setattr(practice, "own_preparation", observed)
    with ThreadPoolExecutor(max_workers=1) as pool, factory() as holder:
        holder.execute(
            text("SELECT id FROM practice_sessions WHERE id=:id FOR UPDATE"), {"id": created["id"]}
        )
        pending = pool.submit(
            client.post,
            f"/v1/practice-sessions/{created['id']}/cancel-preparation",
            headers=headers,
        )
        assert reached.wait(5)
        wait_for_row_lock(factory, "practice_sessions")
        holder.execute(
            text("UPDATE practice_sessions SET status='connecting' WHERE id=:id"),
            {"id": created["id"]},
        )
        holder.commit()
        response = pending.result(timeout=5)
        assert response.status_code == 409
    assert (
        client.get(f"/v1/practice-sessions/{created['id']}", headers=headers).json()["status"]
        == "connecting"
    )
