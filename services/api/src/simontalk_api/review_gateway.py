"""Review-only async boundary; the standard app disables providers by default."""

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class ReviewCapability:
    config_id: str
    supports_idempotency: bool = False

    def __post_init__(self):
        if (
            type(self.config_id) is not str
            or not 1 <= len(self.config_id) <= 128
            or not self.config_id.isascii()
            or not self.config_id.replace("-", "").replace("_", "").replace(".", "").isalnum()
            or type(self.supports_idempotency) is not bool
        ):
            raise ValueError("Invalid review capability")


@dataclass(frozen=True)
class ReviewRequest:
    logical_request_key: str
    generation_policy_version: str
    targets: tuple[dict, ...]
    rehearsal_target: dict | None = None


@dataclass(frozen=True)
class ReviewUsage:
    input_tokens: int | None = None
    output_tokens: int | None = None

    def __post_init__(self):
        for value in (self.input_tokens, self.output_tokens):
            if value is not None and (type(value) is not int or not 0 <= value <= 1_000_000_000):
                raise ValueError("Invalid token usage")


@dataclass(frozen=True)
class ReviewGeneration:
    suggestions: object
    usage: ReviewUsage | None = None
    rehearsal_evaluation: object = None


class ReviewGatewayError(Exception):
    """Only explicit known outcomes are safe errors. Other exceptions remain unknown."""

    def __init__(self, code="generation_failed", *, retryable=False):
        super().__init__()
        self.code = (
            "gateway_configuration_changed"
            if code == "gateway_configuration_changed"
            else "temporary_unavailable"
            if retryable
            else "generation_failed"
        )
        self.retryable = retryable is True


class ReviewGateway(Protocol):
    @property
    def capability(self) -> ReviewCapability | None: ...

    async def generate(self, request: ReviewRequest) -> ReviewGeneration: ...


class UnavailableReviewGateway:
    capability = None

    async def generate(self, request):
        raise RuntimeError("Unavailable review gateway cannot generate")


def capability(gateway):
    value = gateway.capability
    return value if type(value) is ReviewCapability else None
