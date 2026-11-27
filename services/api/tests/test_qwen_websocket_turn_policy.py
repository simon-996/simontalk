"""A guarded single response using synthetic provider events, never a model."""

import base64
import json
from pathlib import Path

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


def test_terminal_response_records_only_normalized_usage_and_deduplicates():
    policy = QwenTurnPolicy()
    response_ready(policy)
    raw = event(
        "response.done",
        "e8",
        response={
            "id": "response_a",
            "status": "completed",
            "usage": {
                "input_tokens": 12,
                "output_tokens": 5,
                "input_tokens_details": {"text_tokens": 12, "audio_tokens": 0},
                "output_tokens_details": {"text_tokens": 3, "audio_tokens": 2},
                "unexpected": "private payload",
            },
        },
    )
    done = policy.accept(raw)
    measured = done.usage_measurement
    assert measured.status == "completed" and measured.input_tokens == 12
    assert measured.input_text_tokens == 12 and measured.input_audio_tokens == 0
    assert measured.output_tokens == 5
    assert measured.output_text_tokens == 3 and measured.output_audio_tokens == 2
    assert len(measured.response_digest) == 64 and "response_a" not in repr(measured)
    assert "private payload" not in repr(measured)
    assert done.event["response"] == {"id": "response_a", "status": "completed"}
    assert policy.accept(raw).usage_measurement is None


@pytest.mark.parametrize(
    "usage",
    [None, "malformed", {"input_tokens": True, "output_tokens": -1}],
)
def test_missing_or_invalid_provider_usage_remains_unknown(usage):
    policy = QwenTurnPolicy()
    response_ready(policy)
    policy.accept(event("input_audio_buffer.speech_started", "e7", item_id="user_b"))
    done = policy.accept(
        event(
            "response.done",
            "e8",
            response={"id": "response_a", "status": "cancelled", "usage": usage},
        )
    )
    assert done.forward and done.usage_measurement.status == "cancelled"
    assert done.usage_measurement.input_tokens is None
    assert done.usage_measurement.output_tokens is None


def test_contradictory_provider_modality_fields_are_not_counted():
    policy = QwenTurnPolicy()
    response_ready(policy)
    done = policy.accept(
        event(
            "response.done",
            "e8",
            response={
                "id": "response_a",
                "status": "completed",
                "usage": {
                    "input_tokens": 4,
                    "input_tokens_details": {"text_tokens": 4, "audio_tokens": 1},
                    "output_tokens_details": {"audio_tokens": 2},
                },
            },
        )
    )
    measured = done.usage_measurement
    assert measured.input_tokens == 4
    assert measured.input_text_tokens is None and measured.input_audio_tokens is None
    assert measured.output_tokens is None and measured.output_audio_tokens == 2


def test_known_zero_is_retained_when_a_sibling_usage_field_is_impossible():
    policy = QwenTurnPolicy()
    response_ready(policy)
    done = policy.accept(
        event(
            "response.done",
            "e8",
            response={
                "id": "response_a",
                "status": "completed",
                "usage": {
                    "input_tokens": 1,
                    "input_tokens_details": {"text_tokens": 2, "audio_tokens": 0},
                },
            },
        )
    )
    assert done.usage_measurement.input_text_tokens is None
    assert done.usage_measurement.input_audio_tokens == 0


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


def test_settled_response_unlocks_next_turn_and_rejects_id_reuse():
    policy = QwenTurnPolicy()
    response_ready(policy)
    assert policy.accept(pcm()).forward
    assert policy.accept(
        event("response.done", "e8", response={"id": "response_a", "status": "completed"})
    ).forward
    assert policy.settle("response_a") == "settled"

    assert policy.accept(event("input_audio_buffer.speech_started", "e9", item_id="user_b")).forward
    policy.accept(event("input_audio_buffer.speech_stopped", "e10", item_id="user_b"))
    policy.accept(event("input_audio_buffer.committed", "e11", item_id="user_b"))
    second_user = policy.accept(
        event(
            "conversation.item.input_audio_transcription.completed",
            "e12",
            item_id="user_b",
            content_index=0,
            transcript="Second turn",
        )
    )
    assert second_user.forward and second_user.create_response
    assert policy.accept(event("response.created", "e13", response={"id": "response_b"})).forward
    assert policy.accept(
        event(
            "response.output_item.added",
            "e14",
            response_id="response_b",
            output_index=0,
            item={"id": "item_b", "type": "message", "role": "assistant"},
        )
    ).forward
    second_pcm = event(
        "response.audio.delta",
        "e15",
        response_id="response_b",
        item_id="item_b",
        output_index=0,
        content_index=0,
        delta=base64.b64encode(b"\x01\x02").decode(),
    )
    assert policy.accept(second_pcm).forward
    assert policy.accept(
        event("response.done", "e16", response={"id": "response_b", "status": "completed"})
    ).forward
    assert policy.settle("response_b") == "settled"
    with pytest.raises(QwenTurnError):
        policy.accept(event("input_audio_buffer.speech_started", "e17", item_id="user_a"))


def test_speech_after_response_done_before_settle_quarantines_without_upstream_cancel():
    policy = QwenTurnPolicy()
    response_ready(policy)
    assert policy.accept(
        event("response.done", "e8", response={"id": "response_a", "status": "completed"})
    ).forward
    overlap = policy.accept(event("input_audio_buffer.speech_started", "e9", item_id="user_b"))
    assert overlap.forward and overlap.quarantine and not overlap.cancel_response
    assert overlap.quarantine_response == "response_a"
    assert policy.settle("response_a") == "ignored"
    policy.accept(event("input_audio_buffer.speech_stopped", "e10", item_id="user_b"))
    policy.accept(event("input_audio_buffer.committed", "e11", item_id="user_b"))
    final = policy.accept(
        event(
            "conversation.item.input_audio_transcription.completed",
            "e12",
            item_id="user_b",
            content_index=0,
            transcript="Interrupted during playback",
        )
    )
    assert final.forward and not final.create_response
    with pytest.raises(QwenTurnError):
        policy.settle("response_a")


def _prefix_ids(raw_event, prefix):
    item = json.loads(json.dumps(raw_event))
    for key in ("event_id", "item_id", "response_id"):
        if isinstance(item.get(key), str):
            item[key] = prefix + item[key]
    if isinstance(item.get("response"), dict) and isinstance(item["response"].get("id"), str):
        item["response"]["id"] = prefix + item["response"]["id"]
    if isinstance(item.get("item"), dict) and isinstance(item["item"].get("id"), str):
        item["item"]["id"] = prefix + item["item"]["id"]
    return item


def test_real_qwen_fixture_replays_across_two_settled_turns():
    fixture_path = (
        Path(__file__).resolve().parents[3]
        / "apps/client/test/fixtures/qwen_guarded_synthetic_events.json"
    )
    raw_events = [
        e
        for e in json.loads(fixture_path.read_text())["events"]
        if e["type"] not in {"session.created", "session.updated"}
    ]
    policy = QwenTurnPolicy()
    creates = 0
    for item in raw_events:
        decision = policy.accept(json.dumps(item, separators=(",", ":")))
        if decision.create_response:
            creates += 1
    assert creates == 1
    assert policy.settle("id_28") == "settled"

    for item in raw_events:
        decision = policy.accept(json.dumps(_prefix_ids(item, "t2_"), separators=(",", ":")))
        if decision.create_response:
            creates += 1
    assert creates == 2
    assert policy.settle("t2_id_28") == "settled"


def test_early_turn_delta_and_in_flight_output_item_after_quarantine():
    policy = QwenTurnPolicy()
    assert policy.accept(
        event(
            "conversation.item.input_audio_transcription.delta",
            "e1",
            item_id="u1",
            content_index=0,
            text="",
            stash="Hello",
        )
    ).forward
    assert policy.accept(event("input_audio_buffer.speech_started", "e2", item_id="u1")).forward
    policy.accept(event("input_audio_buffer.speech_stopped", "e3", item_id="u1"))
    policy.accept(event("input_audio_buffer.committed", "e4", item_id="u1"))
    assert policy.accept(
        event(
            "conversation.item.input_audio_transcription.delta",
            "e5",
            item_id="u1",
            content_index=0,
            text="Hello ",
            stash="world",
        )
    ).forward
    done_u1 = policy.accept(
        event(
            "conversation.item.input_audio_transcription.completed",
            "e6",
            item_id="u1",
            content_index=0,
            transcript="Hello world",
        )
    )
    assert done_u1.create_response
    assert policy.accept(event("response.created", "e7", response={"id": "r1"})).forward

    overlap = policy.accept(event("input_audio_buffer.speech_started", "e8", item_id="u2"))
    assert overlap.quarantine and overlap.cancel_response and overlap.quarantine_response == "r1"
    assert policy.accept(
        event(
            "response.output_item.added",
            "e9",
            response_id="r1",
            output_index=0,
            item={"id": "a1", "type": "message", "role": "assistant"},
        )
    ).forward
    assert not policy.accept(
        event(
            "response.audio.delta",
            "e10",
            response_id="r1",
            item_id="a1",
            output_index=0,
            content_index=0,
            delta="AAA=",
        )
    ).forward
    assert policy.accept(
        event(
            "response.audio_transcript.done",
            "e11",
            response_id="r1",
            item_id="a1",
            output_index=0,
            content_index=0,
            transcript="In flight",
        )
    ).forward
    policy.accept(event("input_audio_buffer.speech_stopped", "e12", item_id="u2"))
    policy.accept(event("input_audio_buffer.committed", "e13", item_id="u2"))
    policy.accept(
        event(
            "conversation.item.input_audio_transcription.completed",
            "e14",
            item_id="u2",
            content_index=0,
            transcript="Interrupt",
        )
    )
    with pytest.raises(QwenTurnError):
        policy.accept(
            event(
                "conversation.item.input_audio_transcription.delta",
                "e15",
                item_id="u2",
                content_index=0,
                text="late",
                stash="",
            )
        )
