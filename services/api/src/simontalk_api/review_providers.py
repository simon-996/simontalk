"""Explicit startup composition. Constructing a gateway never dispatches a review."""

from simontalk_api.config import Settings
from simontalk_api.review_gateway import UnavailableReviewGateway


def create_review_gateway(settings: Settings):
    if settings.review_provider == "disabled":
        return UnavailableReviewGateway()
    if settings.review_provider != "qwen":
        raise ValueError("Unsupported review provider")

    from simontalk_api.qwen_config import load_qwen_review_settings
    from simontalk_api.qwen_review_gateway import QwenReviewGateway

    return QwenReviewGateway(load_qwen_review_settings(env_file=settings.qwen_env_file))


def create_assistance_gateway(settings: Settings):
    if settings.assistance_provider == "disabled":
        return None
    from simontalk_api.qwen_config import load_qwen_review_settings
    from simontalk_api.qwen_review_gateway import QwenReviewGateway

    return QwenReviewGateway(load_qwen_review_settings(env_file=settings.qwen_env_file))
