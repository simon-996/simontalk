import uuid

from fastapi.testclient import TestClient
from sqlalchemy import text
from test_connection_reservations import control, path, reserve
from test_connection_reservations import prepared as prepared

from simontalk_api.main import create_app
from simontalk_api.practice import UnavailableAdmission

CURRENT = "/v1/practice-sessions/current"


def test_current_requires_identity_and_is_empty_without_preparation(client, signup):
    assert client.get(CURRENT).status_code == 401
    identity = signup()
    headers = {"Authorization": f"Bearer {identity['access_token']}"}
    response = client.get(CURRENT, headers=headers)
    assert response.status_code == 200
    assert response.json() == {"practice": None, "connection": None}


def test_current_reads_existing_registration_without_readmission_or_mutation(client, app, prepared):
    app.state.practice_admission = UnavailableAdmission()
    response = client.get(CURRENT, headers=prepared.headers)
    assert response.status_code == 200
    assert response.json() == {"practice": prepared.session, "connection": None}
    assert response.headers["Cache-Control"] == "no-store"
    again = client.get(CURRENT, headers=prepared.headers)
    assert again.json() == response.json()


def test_current_returns_latest_attempt_and_does_not_renew_it(client, app, prepared):
    first = reserve(client, prepared).json()
    assert control(client, prepared, first, "cancel-preparation").status_code == 200
    second = reserve(client, prepared, expected_epoch=1).json()
    app.state.practice_admission = UnavailableAdmission()
    response = client.get(CURRENT, headers=prepared.headers)
    assert response.status_code == 200
    assert response.json()["practice"]["connection_epoch"] == 2
    assert response.json()["connection"] == second
    assert "creation_key" not in response.text
    assert client.get(path(prepared, second), headers=prepared.headers).json() == second
    # A new application instance can recover with identity alone, no original key.
    other = create_app(app.state.settings)
    try:
        with TestClient(other) as restored:
            assert restored.get(CURRENT, headers=prepared.headers).json() == response.json()
    finally:
        other.state.engine.dispose()


def test_current_prioritizes_unknown_connection_even_if_parent_incorrectly_terminal(
    client, prepared, factory
):
    saved = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text(
                "UPDATE realtime_connections SET status='unknown',"
                "termination_status='unknown' WHERE id=:id"
            ),
            {"id": saved["id"]},
        )
        db.execute(
            text("UPDATE practice_sessions SET status='completed',ended_at=now() WHERE id=:id"),
            {"id": prepared.session["id"]},
        )
        # Deliberately inconsistent seed: a separate parent must not hide unknown occupancy.
        db.execute(
            text(
                "INSERT INTO practice_sessions "
                "(id,user_id,creation_key,request_digest,mode,configuration) "
                "SELECT :id,user_id,:key,request_digest,mode,configuration "
                "FROM practice_sessions WHERE id=:source"
            ),
            {"id": uuid.uuid4(), "key": uuid.uuid4(), "source": prepared.session["id"]},
        )
    result = client.get(CURRENT, headers=prepared.headers)
    assert result.status_code == 200
    assert result.json()["practice"]["id"] == prepared.session["id"]
    assert result.json()["connection"]["id"] == saved["id"]
    assert result.json()["connection"]["status"] == "unknown"


def test_current_is_scoped_to_identity_and_account_binding(client, prepared, signup):
    second = signup("bob")
    headers = {"Authorization": f"Bearer {second['access_token']}"}
    assert client.get(CURRENT, headers=headers).json() == {"practice": None, "connection": None}
    headers["X-Account-ID"] = prepared.identity["user"]["id"]
    assert client.get(CURRENT, headers=headers).status_code == 409
    with_bad_owner = {**prepared.headers, "X-Account-ID": second["user"]["id"]}
    assert client.get(CURRENT, headers=with_bad_owner).status_code == 409


def test_current_does_not_return_terminal_practice_without_occupied_connection(client, prepared):
    url = f"/v1/practice-sessions/{prepared.session['id']}/cancel-preparation"
    assert client.post(url, headers=prepared.headers).status_code == 200
    assert client.get(CURRENT, headers=prepared.headers).json() == {
        "practice": None,
        "connection": None,
    }
