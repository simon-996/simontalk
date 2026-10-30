"""One explicitly supplied socket, bounded synthetic overlap protocol, and close.

This library does not connect, read keys, generate audio or run on import. The
caller must supply synthetic PCM and an already opened isolated connection.
A close frame, a terminal event, or a local result is not proof of billing stop.
"""

import asyncio
import json

from qwen_overlap_probe_supervisor import supervise_overlap

PROMPT = "Count from one to twenty in English, clearly and without extra words."


async def execute_session(socket, *, pcm, timeout_seconds=30, post_speech_seconds=3):
    result = {
        "reason": None,
        "configured": False,
        "response_requested": False,
        "overlap": None,
        "cancel_attempted_before_supervision": False,
        "close_sent": None,
        "close_received": None,
    }
    supervision_started = False

    async def send(event):
        await asyncio.wait_for(socket.send(json.dumps(event)), 0.5)

    async def wait_for_type(kind):
        for _ in range(100):
            raw = await socket.recv()
            event = json.loads(raw) if isinstance(raw, (str, bytes)) else raw
            if type(event) is not dict or type(event.get("type")) is not str:
                raise ValueError("Invalid event")
            if event["type"] == "error":
                raise ValueError("Remote error")
            if event["type"] == kind:
                return event
        raise ValueError("Event limit")

    try:
        if type(pcm) is not bytes or not 0 < len(pcm) <= 320_000 or len(pcm) % 2:
            raise ValueError("Invalid input audio")
        if type(timeout_seconds) not in (int, float) or not 0 < timeout_seconds <= 30:
            raise ValueError("Invalid timeout")
        if type(post_speech_seconds) not in (int, float) or not 0 < post_speech_seconds <= 10:
            raise ValueError("Invalid observation window")
        async with asyncio.timeout(timeout_seconds):
            await wait_for_type("session.created")
            await send(
                {
                    "type": "session.update",
                    "session": {
                        "modalities": ["text", "audio"],
                        "max_tokens": 128,
                        "input_audio_transcription": {"model": "qwen3-asr-flash-realtime"},
                        "turn_detection": {
                            "type": "server_vad",
                            "threshold": 0.2,
                            "silence_duration_ms": 600,
                            "create_response": False,
                            "interrupt_response": False,
                        },
                        "audio": {
                            "input": {
                                "format": {
                                    "type": "pcm",
                                    "sample_rate": 16000,
                                    "sample_format": "s16le",
                                    "channels": 1,
                                    "packing": "interleaved",
                                    "channel_layout": "mono",
                                }
                            },
                            "output": {
                                "voice": "Tina",
                                "format": {"type": "pcm", "sample_rate": 24000},
                            },
                        },
                    },
                }
            )
            update = await wait_for_type("session.updated")
            session = update.get("session")
            vad = session.get("turn_detection") if type(session) is dict else None
            if not (
                type(vad) is dict
                and vad.get("type") == "server_vad"
                and vad.get("create_response") is False
                and vad.get("interrupt_response") is False
                and session.get("max_tokens") == 128
            ):
                result["reason"] = "configuration_unconfirmed"
                return result
            result["configured"] = True
            await send(
                {
                    "type": "conversation.item.create",
                    "item": {
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": PROMPT}],
                    },
                }
            )
            created_item = (await wait_for_type("conversation.item.created")).get("item")
            if (
                type(created_item) is not dict
                or created_item.get("role") != "user"
                or created_item.get("content") != [{"type": "input_text", "text": PROMPT}]
            ):
                raise ValueError("Input not confirmed")
            result["response_requested"] = True
            await send({"type": "response.create"})
            created = await wait_for_type("response.created")
            response = created.get("response")
            response_id = response.get("id") if type(response) is dict else None
            if type(response_id) is not str or not response_id or len(response_id) > 256:
                raise ValueError("Invalid response id")
            supervision_started = True
            result["overlap"] = await supervise_overlap(
                socket,
                response_id=response_id,
                pcm=pcm,
                max_audio_bytes=960_000,
                timeout_seconds=timeout_seconds,
                observe_overlap=True,
                post_speech_seconds=post_speech_seconds,
            )
            result["reason"] = "supervision_returned"
    except TimeoutError:
        result["reason"] = "timeout"
    except Exception:
        result["reason"] = "protocol_failed"
    finally:
        if result["response_requested"] and not supervision_started:
            result["cancel_attempted_before_supervision"] = True
            try:
                await asyncio.wait_for(socket.send('{"type":"response.cancel"}'), 0.25)
            except Exception:
                pass
        try:
            await asyncio.wait_for(socket.close(code=1000), 6)
        except Exception:
            pass
        protocol = getattr(socket, "protocol", None)
        for name in ("close_sent", "close_received"):
            frame = getattr(protocol, "close_rcvd" if name == "close_received" else name, None)
            code = getattr(frame, "code", None)
            if type(code) is int:
                result[name] = code
    return result
