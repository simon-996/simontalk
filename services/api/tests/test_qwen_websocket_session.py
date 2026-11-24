"""Offline provider event validation; no provider connection or user audio."""

import copy
import json

import pytest

from simontalk_api.qwen_websocket_session import QwenSessionError, QwenSessionGate


def event(kind, event_id="evt_created", session_id="sess_fixture"):
    return {
        "type": kind,
        "event_id": event_id,
        "session": {
            "id": session_id,
            "object": "realtime.session",
            "model": "qwen3.8-omni-flash-realtime",
        },
    }


def encode(value):
    return json.dumps(value, separators=(",", ":"))


def configured(gate):
    created = event("session.created")
    update = json.loads(gate.accept_created(encode(created)))
    return update["session"]


def test_created_and_updated_bind_one_session_and_exact_settings():
    gate = QwenSessionGate("beginner", "slow")
    settings = configured(gate)
    assert settings["modalities"] == ["text", "audio"]
    assert settings["max_tokens"] == 128 and settings["enable_search"] is False
    assert "short, simple sentences" in settings["instructions"]
    assert "Speak slowly and clearly" in settings["instructions"]
    assert "tools" not in settings
    updated = event("session.updated", event_id="evt_updated")
    updated["session"].update(settings)
    updated["session"].update({"input_audio_format": "pcm", "output_audio_format": "pcm"})
    assert gate.accept_updated(encode(updated)) is True
    assert gate.configured is True
    with pytest.raises(QwenSessionError):
        gate.accept_updated(encode(updated))
    assert gate.configured is False


@pytest.mark.parametrize(
    "difficulty,phrase",
    [
        ("beginner", "short, simple"),
        ("intermediate", "natural everyday"),
        ("advanced", "richer detail"),
    ],
)
@pytest.mark.parametrize("pace", ["slow", "normal"])
def test_snapshot_only_maps_known_enumerations(difficulty, phrase, pace):
    settings = configured(QwenSessionGate(difficulty, pace))
    assert phrase in settings["instructions"]
    assert ("Speak slowly" in settings["instructions"]) == (pace == "slow")


@pytest.mark.parametrize(
    "difficulty,pace", [("unknown", "normal"), ("beginner", "fast"), (None, "slow"), (True, "slow")]
)
def test_unknown_or_user_controlled_settings_are_rejected(difficulty, pace):
    with pytest.raises(QwenSessionError):
        QwenSessionGate(difficulty, pace)


@pytest.mark.parametrize(
    "change",
    [
        "different_session",
        "different_model",
        "same_event",
        "modalities",
        "modalities_unhashable",
        "token_bool",
        "search_missing",
        "tools_null",
        "tools_nonempty",
        "vad_bool",
        "instructions",
        "pcm",
        "transcription",
    ],
)
def test_incorrect_echo_rejected_and_cannot_resume(change):
    gate = QwenSessionGate("intermediate", "normal")
    settings = configured(gate)
    updated = event("session.updated", "evt_updated")
    updated["session"].update(copy.deepcopy(settings))
    updated["session"].update({"input_audio_format": "pcm", "output_audio_format": "pcm"})
    s = updated["session"]
    if change == "different_session":
        s["id"] = "sess_other"
    elif change == "different_model":
        s["model"] = "other"
    elif change == "same_event":
        updated["event_id"] = "evt_created"
    elif change == "modalities":
        s["modalities"] = ["text", "text"]
    elif change == "modalities_unhashable":
        s["modalities"] = ["text", {}]
    elif change == "token_bool":
        s["max_tokens"] = True
    elif change == "search_missing":
        del s["enable_search"]
    elif change == "tools_null":
        s["tools"] = None
    elif change == "tools_nonempty":
        s["tools"] = [{"secret": "private"}]
    elif change == "vad_bool":
        s["turn_detection"]["threshold"] = False
    elif change == "instructions":
        s["instructions"] += " private"
    elif change == "pcm":
        s["input_audio_format"] = "wav"
    elif change == "transcription":
        s["input_audio_transcription"]["model"] = "other"
    with pytest.raises(QwenSessionError) as exc:
        gate.accept_updated(encode(updated))
    assert "private" not in str(exc.value)
    assert gate.configured is False
    with pytest.raises(QwenSessionError):
        gate.accept_created(encode(event("session.created")))


@pytest.mark.parametrize(
    "raw",
    [
        "x",
        "{}",
        "[1]",
        '{"type":"session.created","type":"session.created"}',
        "x" * 131073,
        "\ud800",
    ],
)
def test_malformed_provider_events_fail_closed(raw):
    gate = QwenSessionGate("beginner", "normal")
    with pytest.raises(QwenSessionError):
        gate.accept_created(raw)
    assert gate.configured is False
    with pytest.raises(QwenSessionError):
        gate.accept_created(encode(event("session.created")))
