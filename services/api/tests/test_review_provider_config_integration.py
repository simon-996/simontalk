"""Standard app composition and real SQL/worker; upstream remains MockTransport."""

import asyncio
import json

import httpx
import pytest
from conftest import TEST_URL
from fastapi.testclient import TestClient
from sqlalchemy import text
from test_qwen_config import config
from test_qwen_review_gateway import Parts, envelope
from test_qwen_review_gateway_integration import input_source
from test_review_jobs import create_job, path, retry
from test_review_worker import batch
from test_saved_transcripts import scope as scope

from simontalk_api.config import Settings
from simontalk_api.main import create_app
from simontalk_api.qwen_review_gateway import QwenReviewGateway
from simontalk_api.review_providers import create_review_gateway
from simontalk_api.review_worker import claim_review_job, execute_review_job


@pytest.fixture
def supplier(monkeypatch):
    from simontalk_api import qwen_review_gateway

    state = {"calls": [], "status": 200}

    async def send(request):
        state["calls"].append(request)
        return httpx.Response(
            state["status"],
            headers={"Content-Type": "application/json"},
            stream=Parts(json.dumps(envelope(model="qwen3.8-flash")).encode()),
        )

    monkeypatch.setattr(
        qwen_review_gateway,
        "_client",
        lambda: httpx.AsyncClient(transport=httpx.MockTransport(send), trust_env=False),
    )
    return state


@pytest.fixture
def app(database, tmp_path, monkeypatch, supplier):
    for name in (
        "API_KEY",
        "WORKSPACE_ID",
        "REVIEW_MODEL",
        "REVIEW_CONFIG_ID",
    ):
        monkeypatch.delenv("SIMONTALK_QWEN_" + name, raising=False)
    private_file = config(tmp_path)
    application = create_app(
        Settings(
            _env_file=None,
            database_url=TEST_URL,
            environment="test",
            review_provider="qwen",
            qwen_env_file=private_file,
        )
    )
    yield application
    application.state.engine.dispose()


@pytest.fixture
def client(app):
    with TestClient(app) as client:
        app.state.review_job_runner.stop()
        app.state.practice_maintenance.stop()
        yield client


def test_standard_factory_gateway_reaches_worker_and_preserves_usage(
    client, app, scope, factory, supplier
):
    assert isinstance(app.state.review_gateway, QwenReviewGateway)
    assert supplier["calls"] == []
    result = create_job(client, scope, input_source(client, scope))
    assert result.status_code == 202 and result.json()["status"] == "queued"
    assert batch(factory, app.state.review_gateway) == 1
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["status"] == "succeeded" and job["attempt_count"] == 1
    assert job["result"]["items"][0]["exact_quote"] == "I go"
    payload = json.loads(supplier["calls"][0].content)
    assert payload["model"] == "qwen3.8-flash"
    assert payload["response_format"]["type"] == "json_schema"
    with factory() as db:
        assert tuple(
            db.execute(text("SELECT input_tokens,output_tokens FROM review_attempts")).one()
        ) == (150, 40)
    assert batch(factory, app.state.review_gateway) == 0 and len(supplier["calls"]) == 1


def test_disabling_standard_factory_does_not_reschedule_or_read_missing_key(
    client, app, scope, supplier, tmp_path
):
    disabled = create_app(
        Settings(
            _env_file=None,
            database_url=TEST_URL,
            environment="test",
            review_provider="disabled",
            qwen_env_file=tmp_path / "absent.env",
        )
    )
    source = input_source(client, scope)
    with TestClient(disabled) as reader:
        disabled.state.review_job_runner.stop()
        disabled.state.practice_maintenance.stop()
        job = create_job(reader, scope, source).json()
        assert job["status"] == "blocked" and job["attempt_count"] == 0
        assert batch(disabled.state.session_factory, disabled.state.review_gateway) == 0
    assert supplier["calls"] == []


def test_standard_factory_configuration_rotation_blocks_captured_claim(
    client, app, scope, factory, supplier
):
    create_job(client, scope, input_source(client, scope))
    claim = claim_review_job(factory, app.state.review_gateway)
    assert claim is not None
    private_file = app.state.settings.qwen_env_file
    private_file.write_text(
        private_file.read_text() + "\nSIMONTALK_QWEN_REVIEW_CONFIG_ID=rotated\n"
    )
    changed = create_review_gateway(app.state.settings)
    assert asyncio.run(execute_review_job(factory, changed, claim))
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["status"] == "blocked" and job["error_code"] == "gateway_configuration_changed"
    assert supplier["calls"] == []


def test_standard_factory_unknown_is_not_resent_by_explicit_retry(
    client, app, scope, factory, supplier
):
    supplier["status"] = 503
    create_job(client, scope, input_source(client, scope))
    assert batch(factory, app.state.review_gateway) == 1
    job = client.get(path(scope), headers=scope.headers).json()
    assert job["status"] == "failed" and job["error_code"] == "outcome_unknown"
    assert retry(client, scope, job).json()["attempt_count"] == 1
    assert batch(factory, app.state.review_gateway) == 0
    assert len(supplier["calls"]) == 1
