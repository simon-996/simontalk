import pytest
from fastapi import Request
from fastapi.testclient import TestClient
from pydantic import ValidationError

from simontalk_api.config import Settings
from simontalk_api.main import create_app


def test_unexpected_failure_has_safe_json_and_request_id(caplog):
    app = create_app()

    @app.get("/test-unexpected-failure")
    def fail(request: Request):
        raise RuntimeError("password=SUPER_PRIVATE_VALUE")

    try:
        with TestClient(app, raise_server_exceptions=False) as client:
            response = client.get("/test-unexpected-failure")
        assert response.status_code == 503
        assert response.json()["code"] == "service_unavailable"
        assert response.json()["request_id"] == response.headers["x-request-id"]
        assert "SUPER_PRIVATE_VALUE" not in response.text
        assert "SUPER_PRIVATE_VALUE" not in caplog.text
    finally:
        app.state.engine.dispose()


@pytest.mark.parametrize("origin", ["https://public.example.com", "http://192.168.1.3:7357"])
def test_development_only_allows_explicit_loopback_origins(origin):
    with pytest.raises(ValidationError):
        Settings(environment="development", allowed_origins=[origin])


def test_rejected_cors_preflight_has_safe_json_and_request_id():
    app = create_app()
    try:
        with TestClient(app) as client:
            response = client.options(
                "/v1/me",
                headers={
                    "Origin": "http://localhost:7357",
                    "Access-Control-Request-Method": "DELETE",
                },
            )
        assert response.status_code == 400
        assert response.headers["content-type"].startswith("application/json")
        assert set(response.json()) == {"code", "message", "request_id"}
        assert response.json()["request_id"] == response.headers["x-request-id"]
        assert response.headers["access-control-allow-origin"] == "http://localhost:7357"
    finally:
        app.state.engine.dispose()
