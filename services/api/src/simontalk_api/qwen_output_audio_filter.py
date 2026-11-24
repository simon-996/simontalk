"""Bounded Qwen audio filtering for already-authorized response identities."""

import base64
import binascii
import json
import re

from simontalk_api.qwen_websocket import _valid_message

_ID = re.compile(r"[A-Za-z0-9_-]{1,128}", re.ASCII)
_MAX_RESPONSES = 64
_MAX_EVENTS_PER_RESPONSE = 256
_MAX_PCM_BYTES = 48000


class QwenAudioError(Exception):
    """Fixed diagnostic without audio or provider data."""


class QwenOutputAudioFilter:
    def __init__(self):
        self._closed = False
        self._current = None
        self._retired = {}
        self._responses = set()
        self._items = set()
        self._events = set()
        self._current_count = 0

    def _fail(self):
        self._closed = True
        self._current = None
        self._retired.clear()
        self._responses.clear()
        self._items.clear()
        self._events.clear()
        raise QwenAudioError("audio_unavailable") from None

    @staticmethod
    def _id(value):
        return type(value) is str and _ID.fullmatch(value) is not None

    def start(self, response_id, item_id):
        if (
            self._closed
            or self._current is not None
            or not self._id(response_id)
            or not self._id(item_id)
            or response_id in self._responses
            or item_id in self._items
            or len(self._responses) >= _MAX_RESPONSES
        ):
            self._fail()
        self._responses.add(response_id)
        self._items.add(item_id)
        self._current = (response_id, item_id)
        self._current_count = 0

    def retire(self, response_id):
        if self._closed or self._current is None or self._current[0] != response_id:
            self._fail()
        self._retired[self._current[0]] = self._current[1]
        self._current = None
        self._current_count = 0

    def accept(self, raw):
        if self._closed or not _valid_message(raw):
            self._fail()
        try:
            data = json.loads(raw)
            response, item, event = (
                data.get(key) for key in ("response_id", "item_id", "event_id")
            )
            if (
                data.get("type") != "response.audio.delta"
                or not self._id(response)
                or not self._id(item)
                or not self._id(event)
                or type(data.get("output_index")) is not int
                or data["output_index"] != 0
                or type(data.get("content_index")) is not int
                or data["content_index"] != 0
            ):
                self._fail()
            if response in self._retired:
                if self._retired[response] != item:
                    self._fail()
                return None
            if (
                self._current != (response, item)
                or event in self._events
                or self._current_count >= _MAX_EVENTS_PER_RESPONSE
            ):
                self._fail()
            delta = data.get("delta")
            if type(delta) is not str or not 0 < len(delta) <= 64000:
                self._fail()
            pcm = base64.b64decode(delta, validate=True)
            if (
                not 0 < len(pcm) <= _MAX_PCM_BYTES
                or len(pcm) % 2
                or base64.b64encode(pcm).decode("ascii") != delta
            ):
                self._fail()
            self._events.add(event)
            self._current_count += 1
            return {
                "type": "response.audio.delta",
                "event_id": event,
                "response_id": response,
                "item_id": item,
                "output_index": 0,
                "content_index": 0,
                "delta": delta,
            }
        except (ValueError, TypeError, RecursionError, binascii.Error):
            self._fail()
