"""Bounded multi-turn Qwen control policy; no network or public endpoint."""

import hashlib
import json
import re
from dataclasses import dataclass, field

from simontalk_api.qwen_output_audio_filter import QwenAudioError, QwenOutputAudioFilter
from simontalk_api.qwen_response_usage import QwenResponseUsage, read_qwen_response_usage
from simontalk_api.qwen_websocket import _valid_message

_ID = re.compile(r"[A-Za-z0-9_-]{1,128}", re.ASCII)
_MAX_TURNS = 64
_MAX_EVENTS = 4096
_IGNORED = {
    "conversation.item.created",
    "response.content_part.added",
    "response.content_part.done",
    "response.output_item.done",
    "response.audio.done",
}
_USER_OPEN = {
    "input_audio_buffer.speech_started",
    "conversation.item.input_audio_transcription.delta",
}
_USER_TAIL = {
    "input_audio_buffer.speech_stopped",
    "input_audio_buffer.committed",
    "conversation.item.input_audio_transcription.completed",
}
_RESPONSE_EVENTS = {
    "response.created",
    "response.output_item.added",
    "response.audio.delta",
    "response.audio_transcript.delta",
    "response.audio_transcript.done",
    "response.done",
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
    usage_measurement: QwenResponseUsage | None = field(default=None, repr=False)


class QwenTurnPolicy:
    def __init__(self):
        self._closed = False
        self._draining = False
        self._explicit_commit_item = None
        self._events = {}
        self._seen_users = set()
        self._seen_responses = set()
        self._turn_count = 0
        self._user = None
        self._speech_stopped = False
        self._input_committed = False
        self._input_failed = False
        self._input_final = False
        self._reply_requested = False
        self._response = None
        self._item = None
        self._response_done = False
        self._settled = False
        self._interrupting = False
        self._cancel_sent = False
        self._audio_retired = False
        self._audio = QwenOutputAudioFilter()

    @property
    def draining(self):
        return self._draining

    @property
    def interrupting(self):
        return self._interrupting

    def begin_drain(self):
        self._draining = True
        if not self._speech_stopped and not self._input_committed:
            self._explicit_commit_item = self._user
        return self._explicit_commit_item is not None

    def _fail(self):
        self._closed = True
        self._events.clear()
        self._seen_users.clear()
        self._seen_responses.clear()
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
        if self._response is None or self._cancel_sent or item in self._seen_users:
            self._fail()
        need_cancel = not self._response_done
        if self._item is not None and not self._audio_retired:
            self._audio.retire(self._response)
            self._audio_retired = True
        self._interrupting = True
        self._cancel_sent = True
        self._user = item
        self._seen_users.add(item)
        self._speech_stopped = False
        self._input_committed = False
        self._input_final = False
        return need_cancel

    def settle(self, response_id):
        """Unlock the next user turn only after downstream confirms playback finished."""
        if self._closed:
            self._fail()
        identity = self._id(response_id)
        if self._response is None or identity != self._response or self._settled:
            self._fail()
        if self._interrupting:
            # A crossing client settle arriving just after upstream speech_started
            # cannot clear interruption quarantine, nor be replayed a second time.
            self._settled = True
            return "ignored"
        if not self._response_done:
            self._fail()
        self._settled = True
        return "settled"

    def interrupt_by_client(self):
        """Explicit user turn takeover ('我来说') for an active unsettled reply."""
        if self._closed or self._draining:
            self._fail()
        if self._interrupting:
            return TurnDecision()
        if not self._reply_requested or self._response is None or self._settled:
            self._fail()
        need_cancel = not self._response_done
        if self._item is not None and not self._audio_retired:
            self._audio.retire(self._response)
            self._audio_retired = True
        self._interrupting = True
        self._cancel_sent = True
        self._user = None
        self._speech_stopped = False
        self._input_committed = False
        self._input_final = False
        return TurnDecision(
            cancel_response=need_cancel,
            quarantine=True,
            quarantine_response=self._response,
        )

    def accept_session_updated(self, raw, validator):
        if self._closed or not _valid_message(raw):
            self._fail()
        try:
            data = json.loads(raw)
            if data.get("type") != "session.updated":
                self._fail()
            event_id = self._id(data.get("event_id"))
            fingerprint = hashlib.sha256(
                json.dumps(data, sort_keys=True, ensure_ascii=True, separators=(",", ":")).encode()
            ).digest()
            previous = self._events.get(event_id)
            if previous is not None:
                if previous != fingerprint:
                    self._fail()
                return False
            if len(self._events) >= _MAX_EVENTS:
                self._fail()
            validator(raw)
            self._events[event_id] = fingerprint
            return True
        except QwenTurnError:
            raise
        except Exception:
            self._fail()

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
        if self._draining and (
            kind in _USER_OPEN
            or (kind in _USER_TAIL and self._id(data.get("item_id")) != self._user)
            or (kind in _RESPONSE_EVENTS and self._response is None)
        ):
            return TurnDecision()
        if self._draining and kind == "conversation.item.input_audio_transcription.failed":
            if self._id(data.get("item_id")) != self._user:
                return TurnDecision()
            self._zero(data.get("content_index"))
            if (
                not self._input_committed
                or self._input_final
                or type(data.get("error")) is not dict
            ):
                self._fail()
            self._input_failed = True
            return TurnDecision()
        if kind in _USER_OPEN:
            item = self._id(data.get("item_id"))
            base["item_id"] = item
            is_delta = kind.endswith(".delta")
            if is_delta:
                self._zero(data.get("content_index"))
                text, stash = self._text(data.get("text")), self._text(data.get("stash"))
                combined = self._text(text + stash)
                base.update(content_index=0, text=text, stash=stash)
            else:
                combined = None
            interrupt = False
            need_cancel = False
            if self._reply_requested and not self._interrupting and not self._settled:
                if item in self._seen_users or (is_delta and not combined.strip()):
                    self._fail()
                need_cancel = self._interrupt(item)
                interrupt = True
            elif self._interrupting:
                if self._user is None:
                    if (
                        (is_delta and not combined.strip())
                        or item in self._seen_users
                        or self._turn_count >= _MAX_TURNS
                    ):
                        self._fail()
                    self._turn_count += 1
                    self._user = item
                    self._seen_users.add(item)
                elif item != self._user or (
                    self._input_final if is_delta else self._speech_stopped
                ):
                    self._fail()
            elif self._settled:
                if (
                    (is_delta and not combined.strip())
                    or item in self._seen_users
                    or self._turn_count >= _MAX_TURNS
                ):
                    self._fail()
                self._turn_count += 1
                self._user = item
                self._seen_users.add(item)
                self._speech_stopped = False
                self._input_committed = False
                self._input_final = False
                self._reply_requested = False
                self._response = None
                self._item = None
                self._response_done = False
                self._settled = False
                self._audio_retired = False
            elif self._user is None:
                if (
                    (is_delta and not combined.strip())
                    or item in self._seen_users
                    or self._turn_count >= _MAX_TURNS
                ):
                    self._fail()
                self._turn_count += 1
                self._user = item
                self._seen_users.add(item)
            elif self._user != item or (self._input_final if is_delta else self._speech_stopped):
                self._fail()
            return TurnDecision(
                True,
                cancel_response=need_cancel,
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
                if not self._speech_stopped and item != self._explicit_commit_item:
                    self._fail()
                self._input_committed = True
            base["item_id"] = item
            return TurnDecision(True, event=base)
        if kind == "conversation.item.input_audio_transcription.completed":
            item = self._id(data.get("item_id"))
            self._zero(data.get("content_index"))
            transcript = self._text(data.get("transcript"))
            if self._input_failed:
                return TurnDecision()
            if (
                item != self._user
                or not self._input_committed
                or self._input_final
                or not transcript.strip()
            ):
                self._fail()
            if self._reply_requested and not self._interrupting:
                self._fail()
            create = not self._draining and not self._reply_requested
            self._input_final = True
            self._reply_requested |= create
            base.update(item_id=item, content_index=0, transcript=transcript)
            return TurnDecision(True, create_response=create, event=base)
        if kind == "response.created":
            response = data.get("response")
            if (
                not self._reply_requested
                or self._response_done
                or self._interrupting
                or type(response) is not dict
            ):
                self._fail()
            identity = self._id(response.get("id"))
            if self._response is not None:
                if self._response != identity:
                    self._fail()
                return TurnDecision()
            if identity in self._seen_responses:
                self._fail()
            self._seen_responses.add(identity)
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
                or self._item is not None
                or type(item) is not dict
            ):
                self._fail()
            identity = self._id(item.get("id"))
            if item.get("type") != "message" or item.get("role") != "assistant":
                self._fail()
            self._audio.start(response, identity)
            if self._interrupting and not self._audio_retired:
                self._audio.retire(response)
                self._audio_retired = True
            self._item = identity
            base.update(
                response_id=response,
                output_index=0,
                item={"id": identity, "type": "message", "role": "assistant"},
            )
            return TurnDecision(True, event=base)
        if kind == "response.audio.delta":
            audio = self._audio.accept(raw)
            return TurnDecision(not self._draining and audio is not None, audio=audio)
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
            valid = {"completed"}
            if self._interrupting or self._draining:
                valid.add("cancelled")
            if self._draining:
                valid.update(("failed", "incomplete"))
            if status not in valid:
                self._fail()
            self._response_done = True
            if self._item is not None and not self._audio_retired:
                self._audio.retire(self._response)
                self._audio_retired = True
            base["response"] = {"id": self._response, "status": status}
            usage = read_qwen_response_usage(self._response, status, response.get("usage"))
            return TurnDecision(True, event=base, usage_measurement=usage)
        self._fail()
