import importlib
import importlib.util

import pytest


@pytest.fixture
def module(monkeypatch):
    for name in ("API_KEY", "WORKSPACE_ID", "REALTIME_MODEL", "CONFIG_ID"):
        monkeypatch.delenv("SIMONTALK_QWEN_" + name, raising=False)
    assert importlib.util.find_spec("simontalk_api.qwen_config"), "Private Qwen loader missing"
    return importlib.import_module("simontalk_api.qwen_config")


def config(tmp_path, **changes):
    values = {"API_KEY": "private-fixture-key", "WORKSPACE_ID": "llm-fixture"}
    values.update(changes)
    path = tmp_path / ".env"
    path.write_text(
        "\n".join("SIMONTALK_QWEN_" + k + "=" + v for k, v in values.items() if v is not None)
    )
    path.chmod(0o600)
    return path


def test_private_file_constructs_existing_settings_without_network(module, tmp_path, monkeypatch):
    import httpx

    def forbidden(*args, **kwargs):
        pytest.fail("Configuration must not create a network client")

    monkeypatch.setattr(httpx, "AsyncClient", forbidden)
    result = module.load_qwen_realtime_settings(env_file=config(tmp_path))
    assert result.workspace_id == "llm-fixture"
    assert result.model == "qwen3.5-omni-plus-realtime" and result.config_id == "qwen-private-v1"
    assert result.api_key == "private-fixture-key" and result.api_key not in repr(result)


def test_environment_overrides_explicit_file(module, tmp_path, monkeypatch):
    path = config(tmp_path)
    monkeypatch.setenv("SIMONTALK_QWEN_API_KEY", "environment-secret")
    monkeypatch.setenv("SIMONTALK_QWEN_WORKSPACE_ID", "llm-environment")
    monkeypatch.setenv("SIMONTALK_QWEN_REALTIME_MODEL", "qwen3.5-omni-flash-realtime")
    monkeypatch.setenv("SIMONTALK_QWEN_CONFIG_ID", "controlled-check-v2")
    result = module.load_qwen_realtime_settings(env_file=path)
    assert result.api_key == "environment-secret" and result.workspace_id == "llm-environment"
    assert (
        result.model == "qwen3.5-omni-flash-realtime" and result.config_id == "controlled-check-v2"
    )


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
        {"REALTIME_MODEL": "unverified-model"},
        {"CONFIG_ID": "private invalid"},
    ],
)
def test_invalid_configuration_has_no_secret_or_exception_context(module, tmp_path, changes):
    with pytest.raises(ValueError) as caught:
        module.load_qwen_realtime_settings(env_file=config(tmp_path, **changes))
    assert str(caught.value) == "Qwen private configuration is invalid"
    assert caught.value.__context__ is None and caught.value.__cause__ is None


def test_missing_file_does_not_create_configuration(module, tmp_path):
    path = tmp_path / "missing.env"
    with pytest.raises(ValueError):
        module.load_qwen_realtime_settings(env_file=path)
    assert not path.exists()


def test_configuration_does_not_enable_application_gateways(module, tmp_path):
    from simontalk_api.config import Settings
    from simontalk_api.main import create_app
    from simontalk_api.practice import UnavailableAdmission
    from simontalk_api.review_gateway import UnavailableReviewGateway
    from simontalk_api.signalling import UnavailableSignallingGateway

    module.load_qwen_realtime_settings(env_file=config(tmp_path))
    app = create_app(Settings(_env_file=None))
    try:
        assert isinstance(app.state.practice_admission, UnavailableAdmission)
        assert isinstance(app.state.review_gateway, UnavailableReviewGateway)
        assert isinstance(app.state.signalling_gateway, UnavailableSignallingGateway)
    finally:
        app.state.engine.dispose()
