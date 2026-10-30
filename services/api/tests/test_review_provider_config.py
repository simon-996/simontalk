import importlib
import importlib.util
import os
from pathlib import Path

import httpx
import pytest
from test_qwen_config import config

from simontalk_api.config import Settings
from simontalk_api.qwen_review_gateway import QwenReviewGateway
from simontalk_api.review_gateway import UnavailableReviewGateway


@pytest.fixture(autouse=True)
def private_environment(monkeypatch):
    for name in tuple(os.environ):
        if name.startswith("SIMONTALK_QWEN_") or name == "SIMONTALK_REVIEW_PROVIDER":
            monkeypatch.delenv(name)


def load_review(**kwargs):
    module = importlib.import_module("simontalk_api.qwen_config")
    assert callable(getattr(module, "load_qwen_review_settings", None)), "Review loader missing"
    return module.load_qwen_review_settings(**kwargs)


def provider(settings):
    name = "simontalk_api.review_providers"
    assert importlib.util.find_spec(name), "Review provider factory missing"
    return importlib.import_module(name).create_review_gateway(settings)


def forbidden_network(*args, **kwargs):
    pytest.fail("Configuration must never construct an HTTP client")


def test_default_mode_is_disabled_without_reading_qwen_file(tmp_path, monkeypatch):
    monkeypatch.setattr(httpx, "AsyncClient", forbidden_network)
    settings = Settings(_env_file=None, qwen_env_file=tmp_path / "missing.env")
    assert getattr(settings, "review_provider", None) == "disabled"
    assert isinstance(provider(settings), UnavailableReviewGateway)
    assert not (tmp_path / "missing.env").exists()


def test_explicit_private_review_loader_is_silent_and_separate_from_realtime(tmp_path, monkeypatch):
    monkeypatch.setattr(httpx, "AsyncClient", forbidden_network)
    result = load_review(
        env_file=config(tmp_path, REALTIME_MODEL="unverified", CONFIG_ID="invalid realtime")
    )
    assert result.model == "qwen3.8-flash" and result.config_id == "qwen-review-v1"
    assert result.workspace_id == "llm-fixture" and result.api_key == "private-fixture-key"
    assert result.api_key not in repr(result)


def test_environment_overrides_review_file(tmp_path, monkeypatch):
    path = config(tmp_path, REVIEW_CONFIG_ID="file-review")
    monkeypatch.setenv("SIMONTALK_QWEN_API_KEY", "environment-secret")
    monkeypatch.setenv("SIMONTALK_QWEN_WORKSPACE_ID", "environment-space")
    monkeypatch.setenv("SIMONTALK_QWEN_REVIEW_CONFIG_ID", "environment-review")
    result = load_review(env_file=path)
    assert result.api_key == "environment-secret"
    assert result.workspace_id == "environment-space"
    assert result.config_id == "environment-review"


def test_review_supports_environment_without_a_file(monkeypatch):
    monkeypatch.setenv("SIMONTALK_QWEN_API_KEY", "environment-secret")
    monkeypatch.setenv("SIMONTALK_QWEN_WORKSPACE_ID", "environment-space")
    assert load_review(env_file=None).model == "qwen3.8-flash"


@pytest.mark.parametrize(
    "changes",
    [
        {"API_KEY": None},
        {"WORKSPACE_ID": None},
        {"API_KEY": ""},
        {"API_KEY": "private key"},
        {"API_KEY": "x" * 4097},
        {"WORKSPACE_ID": "https://private.invalid"},
        {"WORKSPACE_ID": "UPPER"},
        {"REVIEW_MODEL": "qwen-flash"},
        {"REVIEW_MODEL": "unverified-model"},
        {"REVIEW_CONFIG_ID": "private invalid"},
        {"REVIEW_CONFIG_ID": "x" * 49},
    ],
)
def test_invalid_enabled_configuration_is_sanitized(tmp_path, changes):
    with pytest.raises(ValueError) as caught:
        load_review(env_file=config(tmp_path, **changes))
    assert str(caught.value) == "Qwen review configuration is invalid"
    assert caught.value.__context__ is None and caught.value.__cause__ is None


def test_missing_review_file_does_not_create_it(tmp_path):
    path = tmp_path / "absent.env"
    with pytest.raises(ValueError, match="Qwen review configuration is invalid"):
        load_review(env_file=path)
    assert not path.exists()


def test_enabled_factory_constructs_only_verified_model_without_network(tmp_path, monkeypatch):
    monkeypatch.setattr(httpx, "AsyncClient", forbidden_network)
    settings = Settings(_env_file=None, review_provider="qwen", qwen_env_file=config(tmp_path))
    gateway = provider(settings)
    assert isinstance(gateway, QwenReviewGateway)
    assert gateway.capability.supports_idempotency is False
    assert "private-fixture-key" not in repr(settings)
    assert "api_key" not in settings.model_dump()


def test_unknown_mode_cannot_silently_enable_provider():
    with pytest.raises(ValueError):
        Settings(_env_file=None, review_provider="typo")


def test_mutated_unknown_mode_is_rejected_before_loading(tmp_path):
    settings = Settings(_env_file=None, qwen_env_file=tmp_path / "absent.env")
    settings.review_provider = "typo"
    with pytest.raises(ValueError, match="Unsupported review provider"):
        provider(settings)


def test_mode_and_private_file_can_be_configured_from_environment(tmp_path, monkeypatch):
    path = config(tmp_path)
    monkeypatch.setenv("SIMONTALK_REVIEW_PROVIDER", "qwen")
    monkeypatch.setenv("SIMONTALK_QWEN_ENV_FILE", str(path))
    settings = Settings(_env_file=None)
    assert getattr(settings, "qwen_env_file", None) == path
    assert isinstance(provider(settings), QwenReviewGateway)


def test_enabled_app_rejects_bad_private_config_before_database(tmp_path, monkeypatch):
    from simontalk_api import main

    def forbidden_database(*args, **kwargs):
        pytest.fail("Invalid enabled configuration must fail before database setup")

    monkeypatch.setattr(main, "create_database", forbidden_database)
    with pytest.raises(ValueError, match="Qwen review configuration is invalid"):
        main.create_app(
            Settings(_env_file=None, review_provider="qwen", qwen_env_file=tmp_path / "absent.env")
        )


def test_app_uses_configured_gateway_but_keeps_media_closed(tmp_path, monkeypatch):
    from simontalk_api.main import create_app
    from simontalk_api.practice import UnavailableAdmission
    from simontalk_api.signalling import UnavailableSignallingGateway

    monkeypatch.setattr(httpx, "AsyncClient", forbidden_network)
    app = create_app(
        Settings(_env_file=None, review_provider="qwen", qwen_env_file=config(tmp_path))
    )
    try:
        assert isinstance(app.state.review_gateway, QwenReviewGateway)
        assert isinstance(app.state.practice_admission, UnavailableAdmission)
        assert isinstance(app.state.signalling_gateway, UnavailableSignallingGateway)
    finally:
        app.state.engine.dispose()


def test_settings_default_private_path_is_dotenv():
    settings = Settings(_env_file=None)
    assert getattr(settings, "qwen_env_file", None) == Path(".env")
