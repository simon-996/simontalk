"""Explicit private configuration loading; never enables a gateway or performs I/O to Qwen."""

from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

from simontalk_api.qwen_review_gateway import QwenReviewSettings
from simontalk_api.qwen_webrtc_signalling import QwenWebRtcSettings


class _Credentials(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SIMONTALK_QWEN_", extra="ignore", hide_input_in_errors=True
    )

    api_key: SecretStr = Field(repr=False)
    workspace_id: str


class _PrivateSettings(_Credentials):
    realtime_model: str = "qwen3.5-omni-plus-realtime"
    config_id: str = "qwen-private-v1"


class _ReviewPrivateSettings(_Credentials):
    review_model: Literal["qwen3.8-flash"] = "qwen3.8-flash"
    review_config_id: str = "qwen-review-v1"


def load_qwen_realtime_settings(*, env_file=".env"):
    try:
        private = _PrivateSettings(_env_file=env_file)
        result = QwenWebRtcSettings(
            workspace_id=private.workspace_id,
            model=private.realtime_model,
            config_id=private.config_id,
            api_key=private.api_key.get_secret_value(),
        )
    except (ValueError, OSError):
        pass
    else:
        return result
    # Do not expose validation inputs or their exception context to operators/loggers.
    raise ValueError("Qwen private configuration is invalid")


def load_qwen_review_settings(*, env_file=".env"):
    try:
        private = _ReviewPrivateSettings(_env_file=env_file)
        result = QwenReviewSettings(
            workspace_id=private.workspace_id,
            model=private.review_model,
            config_id=private.review_config_id,
            api_key=private.api_key.get_secret_value(),
        )
    except (ValueError, OSError):
        pass
    else:
        return result
    raise ValueError("Qwen review configuration is invalid")
