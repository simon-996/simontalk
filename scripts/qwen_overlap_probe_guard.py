"""Bounded receive-and-cancel helper for a future Qwen overlap experiment.

This module never opens a connection or reads configuration. A caller owns the
socket, input task and close, and must supervise this coroutine concurrently.
Its return does not prove remote termination or final charges.
"""

import asyncio
import base64
import binascii
import json


async def receive_bounded(
    socket,
    *,
    max_audio_bytes,
    timeout_seconds,
    stop_feeding=None,
    expected_response_id=None,
    on_event=None,
    observe_overlap=False,
    post_speech_seconds=3,
):
    if type(max_audio_bytes) is not int or max_audio_bytes < 1:
        raise ValueError("Invalid audio limit")
    if type(timeout_seconds) not in (int, float) or not 0 < timeout_seconds <= 60:
        raise ValueError("Invalid timeout")
    if expected_response_id is not None and (
        type(expected_response_id) is not str or not expected_response_id
    ):
        raise ValueError("Invalid response id")
    if type(observe_overlap) is not bool or (
        observe_overlap
        and (
            expected_response_id is None
            or type(post_speech_seconds) not in (int, float)
            or not 0 < post_speech_seconds <= 10
        )
    ):
        raise ValueError("Invalid observation window")

    result = {
        "reason": None,
        "audio_bytes_observed": 0,
        "cancel_sent": False,
        "response_status": None,
        "usage": None,
        "stop_feeding_failed": False,
        "speech_started_before_done": None,
        "speech_stopped": False,
        "speech_item_matched": False,
        "remote_error_observed": False,
    }
    cancel_attempted = False
    speech_deadline = None
    speech_item_id = None

    async def abort(reason):
        nonlocal cancel_attempted
        if result["reason"] is None:
            result["reason"] = reason
            if stop_feeding is not None:
                try:
                    stop_feeding()
                except Exception:
                    result["stop_feeding_failed"] = True
        if not cancel_attempted:
            cancel_attempted = True
            try:
                await asyncio.wait_for(socket.send('{"type":"response.cancel"}'), 0.25)
                result["cancel_sent"] = True
            except Exception:
                pass

    try:
        async with asyncio.timeout(timeout_seconds):
            for _ in range(1000):
                if observe_overlap and speech_deadline is not None and result["response_status"]:
                    remaining = speech_deadline - asyncio.get_running_loop().time()
                    if remaining <= 0:
                        result["reason"] = result["reason"] or "overlap_window_observed"
                        return result
                    try:
                        raw = await asyncio.wait_for(socket.recv(), remaining)
                    except TimeoutError:
                        result["reason"] = result["reason"] or "overlap_window_observed"
                        return result
                else:
                    raw = await socket.recv()
                try:
                    event = json.loads(raw) if isinstance(raw, (bytes, str)) else raw
                    if type(event) is not dict or type(event.get("type")) is not str:
                        raise ValueError()
                    if event["type"] == "error":
                        result["remote_error_observed"] = True
                        await abort("remote_error")
                        continue
                    if (
                        observe_overlap
                        and result["reason"] is None
                        and event["type"] == "input_audio_buffer.speech_started"
                    ):
                        if result["speech_started_before_done"] is not None:
                            await abort("invalid_speech_order")
                            continue
                        speech_item_id = event.get("item_id")
                        if type(speech_item_id) is not str or not speech_item_id:
                            await abort("invalid_speech_item")
                            continue
                        result["speech_started_before_done"] = result["response_status"] is None
                    elif (
                        observe_overlap
                        and result["reason"] is None
                        and event["type"] == "input_audio_buffer.speech_stopped"
                    ):
                        if result["speech_started_before_done"] is None or result["speech_stopped"]:
                            await abort("invalid_speech_order")
                            continue
                        if event.get("item_id") != speech_item_id:
                            await abort("invalid_speech_item")
                            continue
                        result["speech_stopped"] = True
                        result["speech_item_matched"] = True
                        speech_deadline = asyncio.get_running_loop().time() + post_speech_seconds
                    elif observe_overlap and event["type"] == "response.created":
                        await abort("unexpected_response_created")
                        return result
                    if event["type"] == "response.audio.delta":
                        if (
                            expected_response_id is not None
                            and event.get("response_id") != expected_response_id
                        ):
                            await abort("unexpected_response")
                            continue
                        chunk = base64.b64decode(event["delta"], validate=True)
                        result["audio_bytes_observed"] += len(chunk)
                        if result["audio_bytes_observed"] > max_audio_bytes:
                            await abort("audio_limit")
                        elif on_event is not None and result["reason"] is None:
                            on_event(event["type"])
                    elif event["type"] == "response.done":
                        response = event.get("response")
                        if (
                            type(response) is dict
                            and expected_response_id is not None
                            and response.get("id") != expected_response_id
                        ):
                            continue
                        if type(response) is not dict or response.get("status") not in {
                            "completed",
                            "cancelled",
                            "failed",
                            "incomplete",
                        }:
                            raise ValueError()
                        result["response_status"] = response["status"]
                        usage = response.get("usage")
                        if type(usage) is dict:
                            result["usage"] = {
                                key: usage[key]
                                for key in ("input_tokens", "output_tokens", "total_tokens")
                                if type(usage.get(key)) is int and 0 <= usage[key] <= 2_000_000_000
                            } or None
                            for detail_key in ("input_tokens_details", "output_tokens_details"):
                                details = usage.get(detail_key)
                                if type(details) is dict and result["usage"] is not None:
                                    clean = {
                                        key: details[key]
                                        for key in ("text_tokens", "audio_tokens")
                                        if type(details.get(key)) is int
                                        and 0 <= details[key] <= 2_000_000_000
                                    }
                                    if clean:
                                        result["usage"][detail_key] = clean
                        if not observe_overlap or result["reason"] is not None:
                            result["reason"] = result["reason"] or "response_done"
                            return result
                except (ValueError, TypeError, KeyError, binascii.Error):
                    await abort("invalid_audio")
            await abort("event_limit")
    except TimeoutError:
        await abort("timeout")
    except asyncio.CancelledError:
        await abort("reader_cancelled")
        raise
    except Exception:
        await abort("receiver_failed")
    return result
