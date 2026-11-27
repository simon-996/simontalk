"""Bounded single-writer Qwen command queue; no routes or credentials."""

import asyncio
import base64
import binascii
import json
import re
from collections import deque

from simontalk_api.qwen_websocket import _valid_message

_MAX_AUDIO_PENDING = 3
_MAX_CONTROL_PENDING = 3
_MAX_WORKERS = 128
_WORKERS = set()
_AUDIO_ID = re.compile(r"event_audio_([1-9][0-9]{0,4})", re.ASCII)
_FINISH_INPUT = {"type": "input_audio_buffer.commit", "event_id": "simontalk_finish_input"}
FINISH_INPUT = json.dumps(_FINISH_INPUT, separators=(",", ":"))


class QwenSendError(Exception):
    """Fixed diagnostic without message or audio contents."""


def _classify(value):
    if not _valid_message(value) or len(value) > 5000:
        raise ValueError("invalid message")
    data = json.loads(value)
    if data == {"type": "response.create"}:
        return "create"
    if data == {"type": "response.cancel"} or data == _FINISH_INPUT:
        return "control"
    if set(data) != {"type", "event_id", "audio"} or data["type"] != "input_audio_buffer.append":
        raise ValueError("invalid message")
    event, audio = data["event_id"], data["audio"]
    match = _AUDIO_ID.fullmatch(event) if type(event) is str else None
    if match is None or int(match.group(1)) > 36000 or type(audio) is not str or len(audio) != 4268:
        raise ValueError("invalid audio")
    pcm = base64.b64decode(audio, validate=True)
    if len(pcm) != 3200 or base64.b64encode(pcm).decode("ascii") != audio:
        raise ValueError("invalid audio")
    return "audio"


class QwenSerializedSender:
    def __init__(self, connection):
        if not callable(getattr(connection, "send", None)) or not callable(
            getattr(connection, "close", None)
        ):
            raise ValueError("Invalid Qwen sender configuration")
        self._connection = connection
        self._audio = deque()
        self._controls = deque()
        self._current = None
        self._worker = None
        self._closed = False
        self._creating_responses = True
        self._session_update_sent = False
        self._close_task = None

    def stop_creating_responses(self):
        self._creating_responses = False

    @staticmethod
    def _reject(future):
        if future is not None and not future.done():
            future.set_exception(QwenSendError("sender_closed"))

    def _start_close(self):
        if self._close_task is None:
            self._closed = True
            self._reject(self._current)
            for queue in (self._controls, self._audio):
                while queue:
                    _, _, future = queue.popleft()
                    self._reject(future)
            self._close_task = asyncio.create_task(self._finish_close())
        return self._close_task

    async def _finish_close(self):
        try:
            await self._connection.close()
        except Exception:
            pass

    async def close(self):
        await asyncio.shield(self._start_close())

    async def _fail(self):
        await self.close()
        raise QwenSendError("sender_closed") from None

    async def _drain(self):
        try:
            while not self._closed:
                queue = self._controls if self._controls else self._audio
                if not queue:
                    return
                value, kind, future = queue.popleft()
                if kind in {"create", "session_update"} and not self._creating_responses:
                    if not future.done():
                        future.set_result(None)
                    continue
                self._current = future
                try:
                    await self._connection.send(value)
                except asyncio.CancelledError:
                    self._start_close()
                    raise
                except Exception:
                    self._start_close()
                    return
                finally:
                    self._current = None
                if self._closed:
                    self._reject(future)
                    return
                if not future.done():
                    future.set_result(None)
        finally:
            self._worker = None

    @staticmethod
    def _worker_done(task):
        _WORKERS.discard(task)
        try:
            task.result()
        except BaseException:
            pass

    async def _enqueue(self, value, kind):
        queue = self._audio if kind == "audio" else self._controls
        maximum = _MAX_AUDIO_PENDING if kind == "audio" else _MAX_CONTROL_PENDING
        if len(queue) >= maximum or (self._worker is None and len(_WORKERS) >= _MAX_WORKERS):
            await self._fail()
        future = asyncio.get_running_loop().create_future()
        queue.append((value, kind, future))
        if self._worker is None:
            self._worker = asyncio.create_task(self._drain())
            _WORKERS.add(self._worker)
            self._worker.add_done_callback(self._worker_done)
        try:
            await future
        except asyncio.CancelledError:
            self._start_close()
            raise

    async def send_session_update(self, value):
        if self._closed:
            raise QwenSendError("sender_closed")
        try:
            if not _valid_message(value) or len(value) > 16384 or self._session_update_sent:
                raise ValueError("invalid session update")
            data = json.loads(value)
            if (
                set(data) != {"type", "session"}
                or data["type"] != "session.update"
                or type(data["session"]) is not dict
            ):
                raise ValueError("invalid session update")
        except (ValueError, TypeError, RecursionError, UnicodeError):
            await self._fail()
        self._session_update_sent = True
        if not self._creating_responses:
            return
        await self._enqueue(value, "session_update")

    async def send(self, value):
        if self._closed:
            raise QwenSendError("sender_closed")
        try:
            kind = _classify(value)
        except (ValueError, TypeError, RecursionError, UnicodeError, binascii.Error):
            await self._fail()
        if kind == "create" and not self._creating_responses:
            return
        await self._enqueue(value, kind)
