"""Synthetic Qwen output events; no user audio, network or model calls."""

import base64
import json

import pytest

from simontalk_api.qwen_output_audio_filter import QwenAudioError, QwenOutputAudioFilter


def audio(response="response_a", item="item_a", event="event_a", raw=b"\x00\x00"):
    return {
        "type": "response.audio.delta",
        "event_id": event,
        "response_id": response,
        "item_id": item,
        "output_index": 0,
        "content_index": 0,
        "delta": base64.b64encode(raw).decode("ascii"),
        "ignored": "private",
    }


def encoded(value):
    return json.dumps(value, separators=(",", ":"))


def test_bound_audio_is_sanitized_and_late_old_reply_dropped():
    gate = QwenOutputAudioFilter()
    gate.start("response_a", "item_a")
    result = gate.accept(encoded(audio()))
    assert set(result) == {
        "type",
        "event_id",
        "response_id",
        "item_id",
        "output_index",
        "content_index",
        "delta",
    }
    assert "private" not in str(result)
    gate.retire("response_a")
    gate.start("response_b", "item_b")
    stale = audio()
    stale["delta"] = "not base64 and ignored"
    assert gate.accept(encoded(stale)) is None
    assert (
        gate.accept(encoded(audio("response_b", "item_b", "event_b")))["response_id"]
        == "response_b"
    )


@pytest.mark.parametrize(
    "case",
    [
        "wrong_item",
        "unknown_response",
        "duplicate",
        "invalid_base64",
        "odd_pcm",
        "empty_pcm",
        "large_pcm",
        "bool_index",
        "missing_id",
        "reused_event",
    ],
)
def test_bad_audio_fails_closed(case):
    gate = QwenOutputAudioFilter()
    gate.start("response_a", "item_a")
    value = audio()
    if case == "wrong_item":
        value["item_id"] = "wrong"
    elif case == "unknown_response":
        value["response_id"] = "other"
    elif case == "duplicate":
        gate.accept(encoded(value))
    elif case == "invalid_base64":
        value["delta"] = "!!!!"
    elif case == "odd_pcm":
        value = audio(raw=b"x")
    elif case == "empty_pcm":
        value = audio(raw=b"")
    elif case == "large_pcm":
        value = audio(raw=bytes(48002))
    elif case == "bool_index":
        value["output_index"] = False
    elif case == "missing_id":
        del value["event_id"]
    elif case == "reused_event":
        gate.accept(encoded(value))
        gate.retire("response_a")
        gate.start("response_b", "item_b")
        value = audio("response_b", "item_b", "event_a")
    with pytest.raises(QwenAudioError) as caught:
        gate.accept(encoded(value))
    assert "private" not in str(caught.value)
    with pytest.raises(QwenAudioError):
        gate.start("response_c", "item_c")


def test_overlap_identity_reuse_and_wrong_retirement_fail_closed():
    for operation in ("overlap", "response", "item", "retire"):
        gate = QwenOutputAudioFilter()
        gate.start("response_a", "item_a")
        if operation in {"response", "item"}:
            gate.retire("response_a")
        with pytest.raises(QwenAudioError):
            if operation == "overlap":
                gate.start("response_b", "item_b")
            elif operation == "response":
                gate.start("response_a", "item_b")
            elif operation == "item":
                gate.start("response_b", "item_a")
            else:
                gate.retire("wrong")


def test_response_event_capacity_is_bounded(monkeypatch):
    import simontalk_api.qwen_output_audio_filter as module

    monkeypatch.setattr(module, "_MAX_EVENTS_PER_RESPONSE", 2)
    gate = QwenOutputAudioFilter()
    gate.start("response_a", "item_a")
    gate.accept(encoded(audio(event="event_1")))
    gate.accept(encoded(audio(event="event_2")))
    with pytest.raises(QwenAudioError):
        gate.accept(encoded(audio(event="event_3")))


def test_noncanonical_base64_and_wrong_retired_item_fail_closed():
    gate = QwenOutputAudioFilter()
    gate.start("response_a", "item_a")
    value = audio()
    value["delta"] = "AB=="
    with pytest.raises(QwenAudioError):
        gate.accept(encoded(value))
    gate = QwenOutputAudioFilter()
    gate.start("response_a", "item_a")
    gate.retire("response_a")
    with pytest.raises(QwenAudioError):
        gate.accept(encoded(audio(item="other")))


def test_response_identity_capacity_is_bounded(monkeypatch):
    import simontalk_api.qwen_output_audio_filter as module

    monkeypatch.setattr(module, "_MAX_RESPONSES", 2)
    gate = QwenOutputAudioFilter()
    gate.start("response_a", "item_a")
    gate.retire("response_a")
    gate.start("response_b", "item_b")
    gate.retire("response_b")
    with pytest.raises(QwenAudioError):
        gate.start("response_c", "item_c")
