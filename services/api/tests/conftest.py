import hashlib
import os
import secrets
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.engine import make_url

from alembic import command
from simontalk_api.config import Settings
from simontalk_api.db import create_database
from simontalk_api.main import create_app
from simontalk_api.models import Invite

TEST_URL = os.environ.get(
    "SIMONTALK_TEST_DATABASE_URL",
    "postgresql+psycopg://simontalk:simontalk@127.0.0.1:54329/simontalk_test",
)


@pytest.fixture(scope="session")
def database():
    assert make_url(TEST_URL).database.endswith("_test"), "Refusing non-test database"
    config = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    config.attributes["database_url"] = TEST_URL
    command.upgrade(config, "head")
    engine, factory = create_database(TEST_URL)
    with engine.connect() as connection:
        assert int(connection.scalar(text("SHOW server_version_num"))) >= 170000
    yield engine, factory
    engine.dispose()


@pytest.fixture(autouse=True)
def clean_database(request):
    if "database" not in request.fixturenames:
        return
    engine, _ = request.getfixturevalue("database")
    with engine.begin() as connection:
        connection.execute(
            text(
                "TRUNCATE users, invites, auth_sessions, password_reset_grants, "
                "user_preferences, rate_limit_buckets CASCADE"
            )
        )


@pytest.fixture
def factory(database):
    return database[1]


@pytest.fixture
def app(database):
    application = create_app(Settings(database_url=TEST_URL, environment="test"))
    yield application
    application.state.engine.dispose()


@pytest.fixture
def client(app):
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def invitation(factory):
    def create(*, expired=False):
        token = secrets.token_urlsafe(32)
        with factory.begin() as db:
            db.add(
                Invite(
                    token_digest=hashlib.sha256(token.encode()).hexdigest(),
                    expires_at=datetime.now(UTC) + timedelta(hours=-1 if expired else 72),
                )
            )
        return token

    return create


@pytest.fixture
def signup(client, invitation):
    def create(username="alice", *, platform="mobile", headers=None):
        response = client.post(
            "/v1/auth/register",
            json={
                "invite_code": invitation(),
                "username": username,
                "password": "a long test password",
                "display_name": username,
                "platform": platform,
            },
            headers=headers or {},
        )
        assert response.status_code == 201, response.text
        return response.json()

    return create
