from copy import deepcopy
from uuid import uuid4

import pytest

from simontalk_api.errors import APIError
from simontalk_api.review_gateway import ReviewGeneration, ReviewRequest, ReviewUsage


def fixtures():
    target = {
        "source_connection_id": str(uuid4()),
        "source_turn_id": str(uuid4()),
        "revision": 2,
        "text": "Yesterday I went to the park.",
        "eligibility": "eligible",
        "allowed_bases": ["text_only"],
        "context_before": [],
    }
    evidence = {key: target[key] for key in ("source_connection_id", "source_turn_id", "revision")}
    evidence["exact_quote"] = "I went"
    evaluation = {
        "schema_version": "rehearsal_evaluation_v1",
        "target_hash": "a" * 64,
        "intent": {"status": "conveyed", "explanation": "原意已表达。", "evidence": [evidence]},
        "target_issue": {
            "status": "demonstrated",
            "explanation": "展示了过去式。",
            "evidence": [evidence],
        },
    }
    return {"target_hash": "a" * 64}, (target,), evaluation


def validate(value, target, targets, **kwargs):
    from simontalk_api.rehearsal_evaluation import validate_rehearsal_evaluation

    return validate_rehearsal_evaluation(value, target, targets, **kwargs)


def test_optional_dataclass_fields_preserve_positional_usage():
    usage = ReviewUsage(1, 2)
    assert ReviewRequest("key", "v1", ()).rehearsal_target is None
    assert ReviewGeneration([], usage).usage is usage
    assert ReviewGeneration([], usage).rehearsal_evaluation is None


def test_exact_current_user_evidence_and_alternative_statuses():
    target, targets, evaluation = fixtures()
    assert validate(evaluation, target, targets) == evaluation
    for name in ("intent", "target_issue"):
        evaluation[name] = {
            "status": "insufficient_evidence",
            "explanation": "证据不足",
            "evidence": [],
        }
    assert validate(evaluation, target, targets) == evaluation


@pytest.mark.parametrize(
    "change",
    [
        lambda v: v.update(extra=True),
        lambda v: v.update(target_hash="b" * 64),
        lambda v: v["intent"].update(status="demonstrated"),
        lambda v: v["target_issue"].update(status="conveyed"),
        lambda v: v["intent"].update(evidence=[]),
        lambda v: v["intent"].update(explanation=" "),
        lambda v: v["intent"].update(explanation="bad\x00text"),
        lambda v: v["intent"].update(explanation="\ud800"),
        lambda v: v["intent"].update(explanation="a" * 4097),
        lambda v: v["intent"].update(evidence=v["intent"]["evidence"] * 4),
        lambda v: v["intent"]["evidence"][0].update(revision=True),
        lambda v: v["intent"]["evidence"][0].update(revision=1),
        lambda v: v["intent"]["evidence"][0].update(source_connection_id=str(uuid4())),
        lambda v: v["intent"]["evidence"][0].update(source_turn_id=str(uuid4())),
        lambda v: v["intent"]["evidence"][0].update(exact_quote="I go"),
        lambda v: v["intent"]["evidence"][0].update(extra=True),
    ],
)
def test_invalid_evaluation_is_rejected_as_one_whole(change):
    target, targets, evaluation = fixtures()
    value = deepcopy(evaluation)
    change(value)
    with pytest.raises(APIError) as error:
        validate(value, target, targets)
    assert error.value.code == "review_suggestions_invalid"


def test_ordinary_forbidden_missing_required_and_legacy_optional():
    target, targets, evaluation = fixtures()
    with pytest.raises(APIError):
        validate(evaluation, None, targets)
    with pytest.raises(APIError):
        validate(None, target, targets)
    assert validate(None, target, targets, required=False) is None
    assert validate(None, None, targets) is None
    targets[0]["eligibility"] = "excluded"
    with pytest.raises(APIError):
        validate(evaluation, target, targets)
