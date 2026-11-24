"""A guarded single response using synthetic provider events, never a model."""

import base64
import json

import pytest

from simontalk_api.qwen_websocket_turn_policy import QwenTurnError, QwenTurnPolicy


def event(kind, eid, **values):
    return json.dumps({"type": kind, "event_id": eid, **values}, separators=(",", ":"))


def user_ready(policy):
    assert policy.accept(event("input_audio_buffer.speech_started", "e1", item_id="user_a")).forward
    policy.accept(event("input_audio_buffer.speech_stopped", "e2", item_id="user_a"))
    policy.accept(event("input_audio_buffer.committed", "e3", item_id="user_a"))
    return policy.accept(
        event(
            "conversation.item.input_audio_transcription.completed",
            "e4",
            item_id="user_a",
            content_index=0,
            transcript="Hello there",
        )
    )


def response_ready(policy):
    result = user_ready(policy)
    assert result.create_response
    policy.accept(event("response.created", "e5", response={"id": "response_a"}))
    policy.accept(
        event(
            "response.output_item.added",
            "e6",
            response_id="response_a",
            output_index=0,
            item={"id": "item_a", "type": "message", "role": "assistant"},
        )
    )


def pcm(eid="e7"):
    return event(
        "response.audio.delta",
        eid,
        response_id="response_a",
        item_id="item_a",
        output_index=0,
        content_index=0,
        delta=base64.b64encode(b"\x00\x00").decode(),
    )


def test_valid_user_turn_requests_exactly_one_reply_and_filters_audio():
    policy = QwenTurnPolicy()
    response_ready(policy)
    result = policy.accept(pcm())
    assert result.forward and result.audio["response_id"] == "response_a"
    done = policy.accept(
        event("response.done", "e8", response={"id": "response_a", "status": "completed"})
    )
    assert done.forward and not done.create_response
    assert not policy.accept(pcm("e9")).forward
    with pytest.raises(QwenTurnError):
        policy.accept(event("response.created", "e10", response={"id": "response_b"}))


def test_early_transcript_interrupts_once_and_quarantines_old_audio():
    policy = QwenTurnPolicy()
    response_ready(policy)
    first = policy.accept(
        event(
            "conversation.item.input_audio_transcription.delta",
            "e9",
            item_id="user_b",
            content_index=0,
            text="Wait",
            stash="",
        )
    )
    assert first.forward and first.quarantine and first.cancel_response
    assert first.quarantine_response == "response_a"
    assert not policy.accept(pcm("e10")).forward
    later = policy.accept(event("input_audio_buffer.speech_started", "e11", item_id="user_b"))
    assert later.forward and not later.cancel_response and not later.quarantine
    policy.accept(event("input_audio_buffer.speech_stopped", "e12", item_id="user_b"))
    policy.accept(event("input_audio_buffer.committed", "e13", item_id="user_b"))
    final = policy.accept(
        event(
            "conversation.item.input_audio_transcription.completed",
            "e14",
            item_id="user_b",
            content_index=0,
            transcript="Wait please",
        )
    )
    assert final.forward and not final.create_response
    assert policy.accept(
        event("response.done", "e15", response={"id": "response_a", "status": "cancelled"})
    ).forward


def test_duplicate_events_never_repeat_actions_and_conflicts_fail_closed():
    policy = QwenTurnPolicy()
    response_ready(policy)
    raw = event("input_audio_buffer.speech_started", "e9", item_id="user_b")
    assert policy.accept(raw).cancel_response
    repeat = policy.accept(raw)
    assert not repeat.forward and not repeat.cancel_response
    with pytest.raises(QwenTurnError):
        policy.accept(event("input_audio_buffer.speech_started", "e9", item_id="different"))
    with pytest.raises(QwenTurnError):
        policy.accept(pcm("e10"))


@pytest.mark.parametrize(
    "case",
    [
        "completed_before_commit",
        "empty_transcript",
        "reply_before_user",
        "wrong_item",
        "wrong_response",
        "invalid_audio",
        "unknown_event",
        "bool_index",
        "unbound_interruption",
    ],
)
def test_invalid_events_cannot_enable_response_or_audio(case):
    policy = QwenTurnPolicy()
    with pytest.raises(QwenTurnError):
        if case == "completed_before_commit":
            policy.accept(event("input_audio_buffer.speech_started", "a1", item_id="user_a"))
            policy.accept(
                event(
                    "conversation.item.input_audio_transcription.completed",
                    "a2",
                    item_id="user_a",
                    content_index=0,
                    transcript="Hello",
                )
            )
        elif case == "empty_transcript":
            policy.accept(event("input_audio_buffer.speech_started", "a1", item_id="user_a"))
            policy.accept(event("input_audio_buffer.speech_stopped", "a2", item_id="user_a"))
            policy.accept(event("input_audio_buffer.committed", "a3", item_id="user_a"))
            policy.accept(
                event(
                    "conversation.item.input_audio_transcription.completed",
                    "a4",
                    item_id="user_a",
                    content_index=0,
                    transcript="  ",
                )
            )
        elif case == "reply_before_user":
            policy.accept(event("response.created", "a1", response={"id": "response_a"}))
        elif case == "unbound_interruption":
            user_ready(policy)
            policy.accept(event("input_audio_buffer.speech_started", "a5", item_id="user_b"))
        elif case == "unknown_event":
            policy.accept(event("provider.secret", "a1", secret="never log"))
        else:
            response_ready(policy)
            if case == "wrong_item":
                policy.accept(
                    event(
                        "response.audio.delta",
                        "a1",
                        response_id="response_a",
                        item_id="wrong",
                        output_index=0,
                        content_index=0,
                        delta="AAA=",
                    )
                )
            elif case == "wrong_response":
                policy.accept(
                    event("response.done", "a1", response={"id": "other", "status": "completed"})
                )
            elif case == "invalid_audio":
                policy.accept(
                    event(
                        "response.audio.delta",
                        "a1",
                        response_id="response_a",
                        item_id="item_a",
                        output_index=0,
                        content_index=0,
                        delta="!!!!",
                    )
                )
            else:
                policy.accept(
                    event(
                        "response.audio.delta",
                        "a1",
                        response_id="response_a",
                        item_id="item_a",
                        output_index=False,
                        content_index=0,
                        delta="AAA=",
                    )
                )
    with pytest.raises(QwenTurnError):
        policy.accept(pcm("after_fail"))


def test_replayed_final_with_new_event_id_fails_closed():
    policy = QwenTurnPolicy()
    user_ready(policy)
    with pytest.raises(QwenTurnError):
        policy.accept(
            event(
                "conversation.item.input_audio_transcription.completed",
                "different_event",
                item_id="user_a",
                content_index=0,
                transcript="Hello there",
            )
        )


def test_interrupted_final_cannot_be_forwarded_twice_with_new_identity():
    policy = QwenTurnPolicy()
    response_ready(policy)
    policy.accept(event("input_audio_buffer.speech_started", "e9", item_id="user_b"))
    policy.accept(event("input_audio_buffer.speech_stopped", "e10", item_id="user_b"))
    policy.accept(event("input_audio_buffer.committed", "e11", item_id="user_b"))
    final = dict(item_id="user_b", content_index=0, transcript="private text")
    first = policy.accept(
        event("conversation.item.input_audio_transcription.completed", "e12", **final)
    )
    assert "private text" not in repr(first)
    with pytest.raises(QwenTurnError):
        policy.accept(
            event("conversation.item.input_audio_transcription.completed", "e13", **final)
        )
