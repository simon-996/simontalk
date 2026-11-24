"""Single-turn Qwen control policy; no network or public endpoint."""

import hashlib
import json
import re
from dataclasses import dataclass, field

from simontalk_api.qwen_output_audio_filter import QwenAudioError, QwenOutputAudioFilter
from simontalk_api.qwen_websocket import _valid_message

_ID = re.compile(r"[A-Za-z0-9_-]{1,128}", re.ASCII)
_MAX_EVENTS = 1024
_IGNORED = {
    "conversation.item.created",
    "response.content_part.added",
    "response.content_part.done",
    "response.output_item.done",
    "response.audio.done",
}


class QwenTurnError(Exception):
    """Fixed diagnostic with no provider content or user transcript."""


@dataclass(frozen=True, slots=True)
class TurnDecision:
    forward: bool = False
    create_response: bool = False
    cancel_response: bool = False
    quarantine: bool = False
    quarantine_response: str | None = None
    event: dict | None = field(default=None, repr=False)
    audio: dict | None = field(default=None, repr=False)


class QwenTurnPolicy:
    def __init__(self):
        self._closed = False
        self._events = {}
        self._user = None
        self._speech_stopped = False
        self._input_committed = False
        self._input_final = False
        self._reply_requested = False
        self._response = None
        self._item = None
        self._response_done = False
        self._interrupting = False
        self._cancel_sent = False
        self._audio_retired = False
        self._audio = QwenOutputAudioFilter()

    def _fail(self):
        self._closed = True
        self._events.clear()
        self._user = self._response = self._item = None
        raise QwenTurnError("turn_unavailable") from None

    def _id(self, value):
        if type(value) is not str or not _ID.fullmatch(value):
            self._fail()
        return value

    def _text(self, value):
        if type(value) is not str or "\x00" in value or len(value) > 8192:
            self._fail()
        try:
            if len(value.encode("utf-8", errors="strict")) > 8192:
                self._fail()
        except UnicodeError:
            self._fail()
        return value

    def _zero(self, value):
        if type(value) is not int or value != 0:
            self._fail()

    def _interrupt(self, item):
        if self._response is None or self._response_done or self._cancel_sent or item == self._user:
            self._fail()
        if self._item is not None and not self._audio_retired:
            self._audio.retire(self._response)
            self._audio_retired = True
        self._interrupting = True
        self._cancel_sent = True
        self._user = item
        self._speech_stopped = False
        self._input_committed = False
        self._input_final = False

    def accept(self, raw):
        if self._closed or not _valid_message(raw):
            self._fail()
        try:
            data = json.loads(raw)
            kind = data["type"]
            event_id = self._id(data.get("event_id"))
            fingerprint = hashlib.sha256(
                json.dumps(data, sort_keys=True, ensure_ascii=True, separators=(",", ":")).encode()
            ).digest()
            previous = self._events.get(event_id)
            if previous is not None:
                if previous != fingerprint:
                    self._fail()
                return TurnDecision()
            if len(self._events) >= _MAX_EVENTS:
                self._fail()
            decision = self._apply(kind, event_id, data, raw)
            self._events[event_id] = fingerprint
            return decision
        except QwenTurnError:
            raise
        except (QwenAudioError, ValueError, TypeError, RecursionError, KeyError, UnicodeError):
            self._fail()

    def _apply(self, kind, event_id, data, raw):
        base = {"type": kind, "event_id": event_id}
        if kind in _IGNORED:
            return TurnDecision()
        if kind in {
            "input_audio_buffer.speech_started",
            "conversation.item.input_audio_transcription.delta",
        }:
            item = self._id(data.get("item_id"))
            base["item_id"] = item
            if kind.endswith(".delta"):
                self._zero(data.get("content_index"))
                text, stash = self._text(data.get("text")), self._text(data.get("stash"))
                self._text(text + stash)
                base.update(content_index=0, text=text, stash=stash)
            else:
                text = None
            interrupt = False
            if self._reply_requested and not self._interrupting:
                if item == self._user or (text is not None and not (text + stash).strip()):
                    self._fail()
                self._interrupt(item)
                interrupt = True
            elif self._interrupting:
                if item != self._user:
                    self._fail()
            elif self._user is None:
                if kind.endswith(".delta"):
                    self._fail()
                self._user = item
            elif self._user != item or self._speech_stopped:
                self._fail()
            return TurnDecision(
                True,
                cancel_response=interrupt,
                quarantine=interrupt,
                quarantine_response=self._response if interrupt else None,
                event=base,
            )
        if kind in {"input_audio_buffer.speech_stopped", "input_audio_buffer.committed"}:
            item = self._id(data.get("item_id"))
            if item != self._user or (self._reply_requested and not self._interrupting):
                self._fail()
            if kind.endswith("speech_stopped"):
                self._speech_stopped = True
            else:
                if not self._speech_stopped:
                    self._fail()
                self._input_committed = True
            base["item_id"] = item
            return TurnDecision(True, event=base)
        if kind == "conversation.item.input_audio_transcription.completed":
            item = self._id(data.get("item_id"))
            self._zero(data.get("content_index"))
            transcript = self._text(data.get("transcript"))
            if (
                item != self._user
                or not self._speech_stopped
                or not self._input_committed
                or self._input_final
                or not transcript.strip()
            ):
                self._fail()
            if self._reply_requested and not self._interrupting:
                self._fail()
            create = not self._reply_requested
            self._input_final = True
            self._reply_requested = True
            base.update(item_id=item, content_index=0, transcript=transcript)
            return TurnDecision(True, create_response=create, event=base)
        if kind == "response.created":
            response = data.get("response")
            if not self._reply_requested or self._response_done or type(response) is not dict:
                self._fail()
            identity = self._id(response.get("id"))
            if self._response is not None:
                if self._response != identity:
                    self._fail()
                return TurnDecision()
            self._response = identity
            base["response"] = {"id": identity}
            return TurnDecision(True, event=base)
        if kind == "response.output_item.added":
            response = self._id(data.get("response_id"))
            self._zero(data.get("output_index"))
            item = data.get("item")
            if (
                response != self._response
                or self._response_done
                or self._interrupting
                or self._item is not None
                or type(item) is not dict
            ):
                self._fail()
            identity = self._id(item.get("id"))
            if item.get("type") != "message" or item.get("role") != "assistant":
                self._fail()
            self._audio.start(response, identity)
            self._item = identity
            base.update(
                response_id=response,
                output_index=0,
                item={"id": identity, "type": "message", "role": "assistant"},
            )
            return TurnDecision(True, event=base)
        if kind == "response.audio.delta":
            audio = self._audio.accept(raw)
            return TurnDecision(audio is not None, audio=audio)
        if kind in {"response.audio_transcript.delta", "response.audio_transcript.done"}:
            response, item = self._id(data.get("response_id")), self._id(data.get("item_id"))
            self._zero(data.get("output_index"))
            self._zero(data.get("content_index"))
            if response != self._response or item != self._item or self._response_done:
                self._fail()
            key = "delta" if kind.endswith(".delta") else "transcript"
            base.update(response_id=response, item_id=item, output_index=0, content_index=0)
            base[key] = self._text(data.get(key))
            return TurnDecision(True, event=base)
        if kind == "response.done":
            response = data.get("response")
            if (
                type(response) is not dict
                or self._response_done
                or self._id(response.get("id")) != self._response
            ):
                self._fail()
            status = response.get("status")
            if status not in ({"completed", "cancelled"} if self._interrupting else {"completed"}):
                self._fail()
            self._response_done = True
            if self._item is not None and not self._audio_retired:
                self._audio.retire(self._response)
                self._audio_retired = True
            base["response"] = {"id": self._response, "status": status}
            return TurnDecision(True, event=base)
        self._fail()
