"""Qwen WebSocket safety primitives; no gateway is installed by default."""

import asyncio
import json
import logging
import re
from dataclasses import dataclass, field

from websockets.asyncio.client import connect

from simontalk_api.qwen_webrtc_signalling import QwenWebRtcSettings


class no_redirect_connect(connect):  # noqa: N801 - preserves connect's callable interface
    """Reject every handshake redirect before credentials can reach another origin.

    websockets 15.0.1 invokes this method for failed handshakes. Its default
    behavior follows redirects and reuses additional headers, so the dependency
    is pinned and an actual local redirect is regression tested.
    """

    def __init__(self, *args, **kwargs):
        # The upstream library logs authorization headers and frame contents
        # at DEBUG. Keep this connection's logger disabled regardless of the
        # host application's logging configuration.
        private_logger = logging.Logger("simontalk.qwen.private", level=logging.CRITICAL + 1)
        private_logger.disabled = True
        kwargs["logger"] = private_logger
        super().__init__(*args, **kwargs)

    def process_redirect(self, exc: Exception) -> Exception:
        return exc


MAX_MESSAGE_BYTES = 131072
_OPEN_TIMEOUT = 7.0
_SEND_TIMEOUT = 3.0
_CLOSE_TIMEOUT = 6.0
_PENDING_OPENS = set()
_PENDING_IO = set()
_MAX_PENDING_OPENS = 128
_MAX_PENDING_IO = 256
_EVENT_TYPE = re.compile(r"[A-Za-z0-9_.-]{1,128}", re.ASCII)


class QwenWebSocketError(Exception):
    """Fixed diagnostic only; never embeds provider data, credentials or audio."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class QwenWebSocketSettings:
    workspace_id: str
    model: str
    config_id: str
    api_key: str = field(repr=False)

    def __post_init__(self):
        if self.model != "qwen3.8-omni-flash-realtime":
            raise ValueError("Invalid Qwen WebSocket settings")
        try:
            QwenWebRtcSettings(
                workspace_id=self.workspace_id,
                model=self.model,
                config_id=self.config_id,
                api_key=self.api_key,
            )
        except ValueError:
            raise ValueError("Invalid Qwen WebSocket settings") from None


def _unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _invalid_constant(_):
    raise ValueError("invalid JSON constant")


def _valid_message(value):
    if type(value) is not str or not value or len(value) > MAX_MESSAGE_BYTES:
        return False
    try:
        if len(value.encode("utf-8", errors="strict")) > MAX_MESSAGE_BYTES:
            return False
        data = json.loads(value, parse_constant=_invalid_constant, object_pairs_hook=_unique_pairs)
        return (
            type(data) is dict
            and type(data.get("type")) is str
            and bool(_EVENT_TYPE.fullmatch(data["type"]))
        )
    except (UnicodeError, ValueError, RecursionError):
        return False


class QwenWebSocketGateway:
    """Creates attempts, never enables admission or performs I/O on construction."""

    def __init__(self, settings: QwenWebSocketSettings, *, connector=None):
        if type(settings) is not QwenWebSocketSettings:
            raise ValueError("Invalid Qwen WebSocket settings")
        self._settings = settings
        self._connector = connector or no_redirect_connect

    def attempt(self, configuration):
        expected = {
            "provider": "dashscope",
            "region": "cn-beijing",
            "model": self._settings.model,
            "config_id": self._settings.config_id,
        }
        if type(configuration) is not dict or configuration != expected:
            raise QwenWebSocketError("configuration_unavailable")
        return _Attempt(self._settings, self._connector)


class _Attempt:
    def __init__(self, settings, connector):
        self._settings = settings
        self._connector = connector
        self._started = False

    async def open(self):
        if self._started:
            raise QwenWebSocketError("attempt_already_started")
        self._started = True
        settings = self._settings
        url = (
            f"wss://{settings.workspace_id}.cn-beijing.maas.aliyuncs.com"
            f"/api-ws/v1/realtime?model={settings.model}"
        )
        if len(_PENDING_OPENS) >= _MAX_PENDING_OPENS or len(_PENDING_IO) >= _MAX_PENDING_IO:
            raise QwenWebSocketError("connection_capacity")

        async def connect_once():
            return await self._connector(
                url,
                additional_headers={"Authorization": "Bearer " + settings.api_key},
                open_timeout=_OPEN_TIMEOUT,
                close_timeout=5,
                max_size=MAX_MESSAGE_BYTES,
                max_queue=8,
                write_limit=32768,
                compression=None,
                proxy=None,
                ping_interval=None,
            )

        opening = asyncio.create_task(connect_once())
        _PENDING_OPENS.add(opening)
        opening.add_done_callback(_PENDING_OPENS.discard)

        def discard_late(task):
            try:
                late = task.result()
            except BaseException:
                return
            # No consumer may receive a late connection after timeout/cancel.
            asyncio.create_task(_Connection(late).close())

        try:
            done, _ = await asyncio.wait({opening}, timeout=_OPEN_TIMEOUT)
        except asyncio.CancelledError:
            opening.cancel()
            opening.add_done_callback(discard_late)
            raise
        if not done:
            opening.cancel()
            opening.add_done_callback(discard_late)
            raise QwenWebSocketError("connection_timeout")
        failed = False
        try:
            socket = opening.result()
            if not all(callable(getattr(socket, name, None)) for name in ("send", "recv", "close")):
                raise ValueError("invalid socket")
        except BaseException:
            failed = True
        if failed:
            raise QwenWebSocketError("connection_failed")
        return _Connection(socket)


def _detach_io(task):
    """Keep cancelled I/O alive for cleanup without exposing late errors."""
    _PENDING_IO.add(task)

    def consume(done):
        _PENDING_IO.discard(done)
        try:
            done.result()
        except BaseException:
            pass

    task.add_done_callback(consume)
    task.cancel()


class _Connection:
    def __init__(self, socket):
        self._socket = socket
        self._closed = False
        self._sending = False
        self._receiving = False
        self._close_task = None
        self._aborted = False

    def _start_close(self):
        if self._close_task is None:
            self._closed = True
            self._close_task = asyncio.create_task(self._finish_close())
        return self._close_task

    async def _finish_close(self):
        task = None
        try:
            task = asyncio.create_task(self._socket.close(code=1000))
            done, _ = await asyncio.wait({task}, timeout=_CLOSE_TIMEOUT)
            if not done:
                self._abort_local()
                _detach_io(task)
                return
            task.result()
        except asyncio.CancelledError:
            self._abort_local()
            if task is not None and not task.done():
                _detach_io(task)
            raise
        except Exception:
            self._abort_local()

    def _abort_local(self):
        if self._aborted:
            return
        self._aborted = True
        try:
            self._socket.transport.abort()
        except Exception:
            pass

    async def close(self):
        task = self._start_close()
        try:
            await asyncio.shield(task)
        except asyncio.CancelledError:
            raise
        except Exception:
            # Failure to confirm local close cannot establish upstream termination.
            pass

    async def send(self, value):
        if self._closed:
            raise QwenWebSocketError("connection_closed")
        if self._sending:
            self._abort_local()
            await self.close()
            raise QwenWebSocketError("concurrent_send")
        if not _valid_message(value):
            await self.close()
            raise QwenWebSocketError("invalid_message")
        self._sending = True
        failed = False
        task = None
        try:
            task = asyncio.create_task(self._socket.send(value))
            done, _ = await asyncio.wait({task}, timeout=_SEND_TIMEOUT)
            if not done:
                self._abort_local()
                _detach_io(task)
                failed = True
            else:
                task.result()
        except asyncio.CancelledError:
            self._abort_local()
            if task is not None:
                _detach_io(task)
            self._start_close()
            raise
        except Exception:
            failed = True
        finally:
            self._sending = False
        if failed or self._closed:
            await self.close()
            raise QwenWebSocketError("transport_failed")

    async def receive(self):
        if self._closed:
            raise QwenWebSocketError("connection_closed")
        if self._receiving:
            self._abort_local()
            await self.close()
            raise QwenWebSocketError("concurrent_receive")
        self._receiving = True
        failed = False
        value = None
        task = None
        try:
            task = asyncio.create_task(self._socket.recv())
            done, _ = await asyncio.wait({task})
            value = next(iter(done)).result()
        except asyncio.CancelledError:
            self._abort_local()
            if task is not None:
                _detach_io(task)
            self._start_close()
            raise
        except Exception:
            failed = True
        finally:
            self._receiving = False
        if failed or self._closed or not _valid_message(value):
            await self.close()
            raise QwenWebSocketError("transport_failed")
        return value
