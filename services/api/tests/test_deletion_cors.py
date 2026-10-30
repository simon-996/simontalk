"""Exercise the real CORS middleware before cookie-authenticated deletion."""

from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event

from simontalk_api.config import Settings
from simontalk_api.main import create_app


@pytest.fixture
def preflight_client():
    app = create_app(
        Settings(
            environment="test",
            database_url="postgresql+psycopg://unused:unused@127.0.0.1:1/cors_test",
        )
    )
    connections = []

    @event.listens_for(app.state.engine, "do_connect")
    def forbid_database_connection(*args):
        connections.append(True)
        raise AssertionError("Preflight must not access the database")

    # No lifespan: preflight must work without the background workers or database.
    client = TestClient(app)
    try:
        yield client
    finally:
        client.close()
        app.state.engine.dispose()
        assert connections == []


def preflight(client, **overrides):
    return client.options(
        f"/v1/practice-history/{uuid4()}",
        headers={
            "Origin": "http://localhost:7357",
            "Access-Control-Request-Method": "DELETE",
            "Access-Control-Request-Headers": (
                "content-type,x-csrf-token,x-account-id,idempotency-key"
            ),
            **overrides,
        },
    )


@pytest.mark.parametrize("origin", ["http://localhost:7357", "http://127.0.0.1:7357"])
def test_web_delete_preflight_accepts_exact_origin_and_required_headers(preflight_client, origin):
    response = preflight(preflight_client, Origin=origin)
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == origin
    assert response.headers["access-control-allow-credentials"] == "true"
    assert "DELETE" in response.headers["access-control-allow-methods"].split(", ")
    allowed_headers = response.headers["access-control-allow-headers"].lower().split(", ")
    for name in ("content-type", "x-csrf-token", "x-account-id", "idempotency-key"):
        assert name in allowed_headers
    assert "origin" in response.headers["vary"].lower()
    assert response.headers["x-request-id"]


@pytest.mark.parametrize(
    ("overrides", "status", "code"),
    [
        ({"Origin": "http://localhost:7357.evil.example"}, 403, "origin_forbidden"),
        ({"Access-Control-Request-Method": "PUT"}, 400, "request_error"),
        ({"Access-Control-Request-Headers": "x-admin-secret"}, 400, "request_error"),
    ],
)
def test_web_delete_preflight_keeps_origin_method_and_header_restrictions(
    preflight_client, overrides, status, code
):
    response = preflight(preflight_client, **overrides)
    assert response.status_code == status
    assert response.json()["code"] == code
    assert response.json()["request_id"] == response.headers["x-request-id"]
    if "Origin" in overrides:
        assert "access-control-allow-origin" not in response.headers
    else:
        assert response.headers["access-control-allow-origin"] == "http://localhost:7357"
