"""Select numeric usage from an already validated Qwen response terminal event."""

import hashlib
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class QwenResponseUsage:
    response_digest: str
    status: str
    input_tokens: int | None
    output_tokens: int | None
    input_text_tokens: int | None
    input_audio_tokens: int | None
    output_text_tokens: int | None
    output_audio_tokens: int | None


def _count(value):
    return value if type(value) is int and 0 <= value <= 1_000_000_000 else None


def _counts(usage, direction):
    total = _count(usage.get(f"{direction}_tokens"))
    details = usage.get(f"{direction}_tokens_details")
    if type(details) is not dict:
        return total, None, None
    text = _count(details.get("text_tokens"))
    audio = _count(details.get("audio_tokens"))
    if total is not None:
        text = None if text is not None and text > total else text
        audio = None if audio is not None and audio > total else audio
        if (text or 0) + (audio or 0) > total:
            return total, None, None
    return total, text, audio


def read_qwen_response_usage(response_id, status, usage):
    usage = usage if type(usage) is dict else {}
    input_total, input_text, input_audio = _counts(usage, "input")
    output_total, output_text, output_audio = _counts(usage, "output")
    return QwenResponseUsage(
        response_digest=hashlib.sha256(response_id.encode("ascii")).hexdigest(),
        status=status,
        input_tokens=input_total,
        output_tokens=output_total,
        input_text_tokens=input_text,
        input_audio_tokens=input_audio,
        output_text_tokens=output_text,
        output_audio_tokens=output_audio,
    )
