"""Fail-closed Qwen WebSocket configuration gate; performs no I/O."""

import json
import re

from simontalk_api.qwen_websocket import _valid_message

_ID = re.compile(r"[A-Za-z0-9_-]{1,128}", re.ASCII)
_LEVELS = {
    "beginner": "Use short, simple sentences and familiar words.",
    "intermediate": "Use natural everyday English and clear questions.",
    "advanced": "Use natural English with richer detail and discussion.",
}
_PACES = {"normal": "Speak at a natural conversational pace.", "slow": "Speak slowly and clearly."}


class QwenSessionError(Exception):
    """Fixed protocol diagnostic without session data."""


class QwenSessionGate:
    def __init__(self, difficulty, pace):
        if type(difficulty) is not str or type(pace) is not str:
            raise QwenSessionError("session_unavailable")
        if difficulty not in _LEVELS or pace not in _PACES:
            raise QwenSessionError("session_unavailable")
        self._settings = {
            "modalities": ["text", "audio"],
            "max_tokens": 128,
            "enable_search": False,
            "voice": "Tina",
            "instructions": (
                "You are a friendly English conversation partner. "
                + _LEVELS[difficulty]
                + " "
                + _PACES[pace]
                + " Keep replies concise and invite the learner to speak."
            ),
            "input_audio_transcription": {"model": "qwen3-asr-flash-realtime"},
            "turn_detection": {
                "type": "server_vad",
                "threshold": 0.2,
                "silence_duration_ms": 600,
                "create_response": False,
                "interrupt_response": False,
            },
        }
        self._state = "created_pending"
        self._session_id = None
        self._created_event_id = None

    @property
    def configured(self):
        return self._state == "configured"

    def _fail(self):
        self._state = "closed"
        self._session_id = None
        self._created_event_id = None
        raise QwenSessionError("session_unavailable") from None

    def _event(self, raw, expected_type):
        if not _valid_message(raw):
            self._fail()
        try:
            event = json.loads(raw)
            event_id = event.get("event_id")
            session = event.get("session")
            if (
                event.get("type") != expected_type
                or type(event_id) is not str
                or not _ID.fullmatch(event_id)
                or type(session) is not dict
                or session.get("object") != "realtime.session"
                or session.get("model") != "qwen3.8-omni-flash-realtime"
                or type(session.get("id")) is not str
                or not _ID.fullmatch(session["id"])
            ):
                self._fail()
            return event_id, session
        except (ValueError, TypeError, RecursionError):
            self._fail()

    def accept_created(self, raw):
        if self._state != "created_pending":
            self._fail()
        event_id, session = self._event(raw, "session.created")
        self._session_id = session["id"]
        self._created_event_id = event_id
        self._state = "updated_pending"
        return json.dumps(
            {"type": "session.update", "session": self._settings}, separators=(",", ":")
        )

    def accept_updated(self, raw):
        if self._state != "updated_pending":
            self._fail()
        event_id, session = self._event(raw, "session.updated")
        vad = session.get("turn_detection")
        transcription = session.get("input_audio_transcription")
        modalities = session.get("modalities")
        tools = session.get("tools")
        expected_vad = self._settings["turn_detection"]
        valid_vad = type(vad) is dict and all(
            type(vad.get(key)) is type(value) and vad.get(key) == value
            for key, value in expected_vad.items()
        )
        if (
            event_id == self._created_event_id
            or session["id"] != self._session_id
            or type(modalities) is not list
            or len(modalities) != 2
            or any(type(modality) is not str for modality in modalities)
            or set(modalities) != {"text", "audio"}
            or type(session.get("max_tokens")) is not int
            or session["max_tokens"] != 128
            or session.get("enable_search") is not False
            or ("tools" in session and (type(tools) is not list or tools))
            or session.get("voice") != self._settings["voice"]
            or session.get("instructions") != self._settings["instructions"]
            or session.get("input_audio_format") != "pcm"
            or session.get("output_audio_format") != "pcm"
            or type(transcription) is not dict
            or transcription.get("model") != "qwen3-asr-flash-realtime"
            or not valid_vad
        ):
            self._fail()
        self._state = "configured"
        return True
