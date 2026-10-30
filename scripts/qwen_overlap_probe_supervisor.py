"""Supervise input and reception for a single overlap experiment.

The caller provides an already-configured connection and its actual response ID.
This module does not connect, load credentials, play audio, or close the socket.
"""

import asyncio
import base64
import json

from qwen_overlap_probe_guard import receive_bounded


async def supervise_overlap(
    socket,
    *,
    response_id,
    pcm,
    max_audio_bytes,
    timeout_seconds,
    chunk_interval=0.1,
    observe_overlap=False,
    post_speech_seconds=3,
):
    if type(response_id) is not str or not response_id or len(response_id) > 256:
        raise ValueError("Invalid response id")
    if type(pcm) is not bytes or not 0 < len(pcm) <= 320_000 or len(pcm) % 2:
        raise ValueError("Invalid input audio")
    if type(chunk_interval) not in (int, float) or not 0 < chunk_interval <= 1:
        raise ValueError("Invalid chunk interval")

    first_audio = asyncio.Event()
    feeder_task = None
    input_chunks_sent = 0
    input_complete = False

    def stop_feeding():
        if feeder_task is not None and not feeder_task.done():
            feeder_task.cancel()

    def on_event(event_type):
        if event_type == "response.audio.delta":
            first_audio.set()

    async def feed():
        nonlocal input_chunks_sent, input_complete
        await first_audio.wait()
        for offset in range(0, len(pcm), 3200):
            payload = json.dumps(
                {
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(pcm[offset : offset + 3200]).decode("ascii"),
                }
            )
            await asyncio.wait_for(socket.send(payload), 0.25)
            input_chunks_sent += 1
            await asyncio.sleep(chunk_interval)
        input_complete = True

    reader_task = asyncio.create_task(
        receive_bounded(
            socket,
            max_audio_bytes=max_audio_bytes,
            timeout_seconds=timeout_seconds,
            stop_feeding=stop_feeding,
            expected_response_id=response_id,
            on_event=on_event,
            observe_overlap=observe_overlap,
            post_speech_seconds=post_speech_seconds,
        )
    )
    feeder_task = asyncio.create_task(feed())
    result = {
        "reason": None,
        "reader": None,
        "feeder_stopped": False,
        "input_chunks_sent": 0,
        "input_complete": False,
    }
    try:
        done, _ = await asyncio.wait(
            (reader_task, feeder_task), return_when=asyncio.FIRST_COMPLETED
        )
        if feeder_task in done and not feeder_task.cancelled() and feeder_task.exception():
            result["reason"] = "feeder_failed"
            if not reader_task.done():
                reader_task.cancel()
        try:
            result["reader"] = await reader_task
        except asyncio.CancelledError:
            if asyncio.current_task().cancelling() or not reader_task.cancelled():
                raise
        if result["reason"] is None:
            result["reason"] = "reader_finished"
    finally:
        stop_feeding()
        if not reader_task.done():
            reader_task.cancel()
        done, _ = await asyncio.wait((feeder_task, reader_task), timeout=1)
        result["feeder_stopped"] = feeder_task in done
        result["input_chunks_sent"] = input_chunks_sent
        result["input_complete"] = input_complete
        for task in done:
            if not task.cancelled():
                task.exception()
    return result
