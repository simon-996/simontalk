from fastapi.testclient import TestClient

from simontalk_api.main import create_app


def test_liveness_is_independent_of_database():
    with TestClient(create_app()) as client:
        response = client.get("/health/live")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_authentication_required():
    with TestClient(create_app()) as client:
        response = client.get("/v1/me")
    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_validation_does_not_echo_secrets():
    with TestClient(create_app()) as client:
        response = client.post(
            "/v1/auth/login",
            json={
                "username": "alice",
                "password": "SECRET!",
                "platform": "mobile",
            },
        )
    assert response.status_code == 422
    assert response.json()["code"] == "validation_error"
    assert "SECRET!" not in response.text


def test_web_requires_csrf():
    with TestClient(create_app()) as client:
        response = client.post(
            "/v1/auth/login",
            json={
                "username": "alice",
                "password": "a long password",
                "platform": "web",
            },
            headers={"Origin": "http://localhost:7357"},
        )
    assert response.status_code == 403
    assert response.json()["code"] == "csrf_invalid"
