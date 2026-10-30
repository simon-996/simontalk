"""Candidate-only SDP boundary. Not installed by create_app or practice admission."""

import asyncio
import re
from collections.abc import Callable
from dataclasses import dataclass, field

import httpx

from simontalk_api.errors import APIError
from simontalk_api.signalling import MAX_SDP_BYTES, valid_sdp

_EXCHANGE_TIMEOUT_SECONDS = 7.0
_MODELS = frozenset(
    {"qwen3.5-omni-plus-realtime", "qwen3.5-omni-flash-realtime", "qwen3.8-omni-flash-realtime"}
)
_WORKSPACE = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", re.ASCII)
_CONFIG_ID = re.compile(r"[a-zA-Z0-9_.-]{1,128}", re.ASCII)


@dataclass(frozen=True, slots=True)
class QwenWebRtcSettings:
    workspace_id: str
    model: str
    config_id: str
    api_key: str = field(repr=False)

    def __post_init__(self):
        if (
            type(self.workspace_id) is not str
            or _WORKSPACE.fullmatch(self.workspace_id) is None
            or type(self.model) is not str
            or self.model not in _MODELS
            or type(self.config_id) is not str
            or _CONFIG_ID.fullmatch(self.config_id) is None
            or type(self.api_key) is not str
            or not 1 <= len(self.api_key) <= 4096
            or any(not "!" <= character <= "~" for character in self.api_key)
        ):
            raise ValueError("Invalid Qwen WebRTC settings")


class QwenSignallingFailure(Exception):
    def __init__(self):
        super().__init__("Signalling exchange failed")


def _client():
    return httpx.AsyncClient(
        trust_env=False,
        follow_redirects=False,
        timeout=httpx.Timeout(_EXCHANGE_TIMEOUT_SECONDS),
        transport=httpx.AsyncHTTPTransport(trust_env=False, retries=0),
    )


class QwenWebRtcSignallingGateway:
    """One HTTP exchange per invocation; the durable caller owns attempt deduplication."""

    def __init__(
        self,
        settings: QwenWebRtcSettings,
        *,
        client_factory: Callable[[], httpx.AsyncClient] | None = None,
    ):
        if type(settings) is not QwenWebRtcSettings:
            raise ValueError("Invalid Qwen WebRTC settings")
        self._settings = settings
        self._client_factory = client_factory or _client

    def check_configuration(self, configuration):
        expected = {
            "provider": "dashscope",
            "region": "cn-beijing",
            "model": self._settings.model,
            "config_id": self._settings.config_id,
        }
        if type(configuration) is not dict or configuration != expected:
            raise APIError(503, "realtime_unavailable", "实时语音配置尚未通过核对。")

    async def exchange_offer(self, configuration, offer):
        self.check_configuration(configuration)
        try:
            valid = valid_sdp(offer)
        except UnicodeError:
            valid = False
        if not valid:
            raise APIError(422, "invalid_offer", "信令输入未通过校验。")
        url = httpx.URL(
            f"https://{self._settings.workspace_id}.cn-beijing.maas.aliyuncs.com"
            "/api/v1/webrtc/realtime",
            params={"model": self._settings.model},
        )
        failure = None
        try:
            async with asyncio.timeout(_EXCHANGE_TIMEOUT_SECONDS):
                async with self._client_factory() as client:
                    async with client.stream(
                        "POST",
                        url,
                        headers={
                            "Authorization": f"Bearer {self._settings.api_key}",
                            "Content-Type": "application/sdp",
                            "Accept": "application/sdp",
                            "Accept-Encoding": "identity",
                        },
                        content=offer.encode("utf-8"),
                        follow_redirects=False,
                    ) as response:
                        if (
                            response.status_code != 200
                            or response.headers.get("Content-Type", "")
                            .split(";", 1)[0]
                            .strip()
                            .lower()
                            != "application/sdp"
                            or response.headers.get("Content-Encoding", "identity").strip().lower()
                            != "identity"
                        ):
                            raise QwenSignallingFailure()
                        declared = response.headers.get("Content-Length")
                        if declared is not None:
                            if (
                                re.fullmatch(r"[0-9]{1,20}", declared, re.ASCII) is None
                                or int(declared) > MAX_SDP_BYTES
                            ):
                                raise QwenSignallingFailure()
                            declared = int(declared)
                        body = bytearray()
                        async for chunk in response.aiter_raw():
                            if len(body) + len(chunk) > MAX_SDP_BYTES:
                                raise QwenSignallingFailure()
                            body.extend(chunk)
                        if declared is not None and len(body) != declared:
                            raise QwenSignallingFailure()
                        answer = body.decode("utf-8", errors="strict")
                        if not valid_sdp(answer):
                            raise QwenSignallingFailure()
                        return answer
        except (TimeoutError, httpx.TimeoutException):
            failure = TimeoutError("Signalling exchange timed out")
        except Exception:
            failure = QwenSignallingFailure()
        # Raise outside the handler: neither context nor traceback carries an SDK
        # exception that may contain credentials, SDP or an upstream error body.
        raise failure
