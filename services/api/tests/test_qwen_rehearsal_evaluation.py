import asyncio
import copy
import json

import pytest
from test_qwen_review_gateway import envelope, exchange, request
from test_qwen_review_gateway import module as module


def parent():
    return {
        "source_text": "Yesterday I go to the park.",
        "exact_quote": "I go",
        "kind": "correction",
        "basis": "text_only",
        "explanation": "过去式",
        "suggestion": "Yesterday I went to the park.",
        "context_before": [],
        "target_hash": "a" * 64,
        "account_id": "private-account",
        "job_id": "private-job",
    }


def output():
    return {
        "suggestions": [],
        "rehearsal_evaluation": {
            "intent": {
                "status": "conveyed",
                "explanation": "原意已表达",
                "evidence": [{"target_id": 0, "exact_quote": "I went"}],
            },
            "target_issue": {
                "status": "demonstrated",
                "explanation": "已展示过去式",
                "evidence": [{"target_id": 0, "exact_quote": "I went"}],
            },
        },
    }


def source():
    result = request(rehearsal_target=parent())
    result.targets[0]["text"] = "Yesterday I went to the park."
    return result


@pytest.mark.parametrize("model", ["qwen-flash", "qwen3.8-flash"])
def test_child_maps_evidence_and_filters_parent_identifiers(module, model):
    gateway, calls, _, _ = exchange(
        module, envelope(json.dumps(output()), model=model), model=model
    )
    req = source()
    result = asyncio.run(gateway.generate(req))
    assert result.suggestions == []
    evaluation = result.rehearsal_evaluation
    assert evaluation["schema_version"] == "rehearsal_evaluation_v1"
    assert evaluation["target_hash"] == req.rehearsal_target["target_hash"]
    assert evaluation["intent"]["evidence"] == [
        {
            **{
                key: req.targets[0][key]
                for key in ("source_connection_id", "source_turn_id", "revision")
            },
            "exact_quote": "I went",
        }
    ]
    payload = json.loads(calls[0].content)
    supplied = json.loads(payload["messages"][1]["content"])
    assert supplied["rehearsal_target"] == {
        key: value
        for key, value in parent().items()
        if key not in {"target_hash", "account_id", "job_id"}
    }
    assert "private-account" not in str(payload) and "private-job" not in str(payload)
    assert "a" * 64 not in str(payload)
    if model == "qwen3.8-flash":
        schema = payload["response_format"]["json_schema"]["schema"]
        assert set(schema["required"]) == {"suggestions", "rehearsal_evaluation"}
        assert schema["additionalProperties"] is False
        assert schema["properties"]["rehearsal_evaluation"]["additionalProperties"] is False
    prompt = payload["messages"][0]["content"]
    assert "not_demonstrated" in prompt and "ASR" in prompt and "different wording" in prompt


@pytest.mark.parametrize(
    "mutate",
    [
        lambda v: v.pop("rehearsal_evaluation"),
        lambda v: v.update(extra=1),
        lambda v: v["rehearsal_evaluation"].update(target_hash="a" * 64),
        lambda v: v["rehearsal_evaluation"]["intent"].update(evidence=[]),
        lambda v: v["rehearsal_evaluation"]["intent"]["evidence"][0].update(target_id=True),
        lambda v: v["rehearsal_evaluation"]["intent"]["evidence"][0].update(target_id=1),
        lambda v: v["rehearsal_evaluation"]["intent"]["evidence"][0].update(exact_quote="I go"),
        lambda v: v["rehearsal_evaluation"]["intent"]["evidence"][0].update(extra=1),
        lambda v: v["rehearsal_evaluation"]["intent"].update(explanation="bad\x00text"),
    ],
)
def test_child_invalid_complete_root_rejects_all_output(module, mutate):
    value = copy.deepcopy(output())
    mutate(value)
    gateway, _, _, _ = exchange(module, envelope(json.dumps(value)))
    result = asyncio.run(gateway.generate(source()))
    assert result.suggestions is None
    assert result.rehearsal_evaluation is None


def test_ordinary_request_with_extension_is_rejected(module):
    gateway, _, _, _ = exchange(module, envelope(json.dumps(output())))
    result = asyncio.run(gateway.generate(request()))
    assert result.suggestions is None and result.rehearsal_evaluation is None


def sent_rehearsal_prompt(module):
    gateway, calls, _, _ = exchange(module, envelope(json.dumps(output())))
    asyncio.run(gateway.generate(source()))
    return json.loads(calls[0].content)["messages"][0]["content"]


def test_rehearsal_prompt_identifies_current_user_text_without_age_ambiguity(module):
    prompt = sent_rehearsal_prompt(module)
    assert "targets 数组中每项 text 就是本人本次重练的用户文字" in prompt
    assert "rehearsal_target 是原普通练习的冻结目标" in prompt
    assert "child" not in prompt.lower()
    assert "不得声称未提供本次重练文字" in prompt


def test_rehearsal_prompt_compares_facts_separately_from_language_form(module):
    prompt = sent_rehearsal_prompt(module)
    assert "语法修正、同义改写或不同措辞本身不等于 changed" in prompt
    assert "关键事实" in prompt
    assert "原意和目标问题必须独立评价" in prompt
    assert "conveyed/still_present" in prompt
    assert "changed/demonstrated" in prompt
    assert "Yesterday I go to the park." not in prompt
    assert "Yesterday I visited the park." not in prompt


def test_rehearsal_prompt_requires_specific_reason_for_missing_evidence(module):
    prompt = sent_rehearsal_prompt(module)
    assert "insufficient_evidence 必须说明具体的识别或上下文不确定" in prompt
    assert "uncertain" in prompt
    assert "not_demonstrated" in prompt
    assert "ASR" in prompt


def test_uncertain_eligibility_does_not_erase_independent_text_evidence(module):
    prompt = sent_rehearsal_prompt(module)
    assert "uncertain 不等于文字不存在或整段不可评价" in prompt
    assert "不依赖可疑替词的清楚语法和直接意思仍可评价" in prompt
