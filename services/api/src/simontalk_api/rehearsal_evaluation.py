"""Bounded rehearsal conclusions grounded in exact, current child user evidence."""

import re
from uuid import UUID

from simontalk_api.errors import APIError

INTENT_STATUSES = ("conveyed", "changed", "insufficient_evidence")
ISSUE_STATUSES = ("demonstrated", "still_present", "not_demonstrated", "insufficient_evidence")
REFERENCE_FIELDS = ("source_connection_id", "source_turn_id", "revision")


def _text(value, limit):
    if type(value) is not str or not value.strip() or "\x00" in value or len(value) > limit:
        raise ValueError()
    if len(value.encode("utf-8")) > limit * 4:
        raise ValueError()


def review_targets(data):
    """Current non-excluded user decisions, retaining their exact source scope."""
    return tuple(
        {
            "source_connection_id": scope["connection_id"],
            "source_turn_id": item["turn_id"],
            "revision": item["revision"],
            "text": item["text"],
            "eligibility": item["eligibility"],
            "allowed_bases": item["allowed_bases"],
            "context_before": [
                {
                    key: value
                    for key, value in context.items()
                    if key in {"role", "text", "turn_id", "revision"}
                }
                for context in item["context_before"]
            ],
        }
        for scope in data["scopes"]
        for item in scope["decisions"]
        if item["role"] == "user" and item["eligibility"] != "excluded"
    )


def validate_rehearsal_evaluation(value, rehearsal_target, targets, *, required=True):
    """Validate the full extension; no normalization can manufacture quoted evidence."""
    try:
        if value is None:
            if required and rehearsal_target is not None:
                raise ValueError()
            return None
        if (
            rehearsal_target is None
            or type(value) is not dict
            or set(value) != {"schema_version", "target_hash", "intent", "target_issue"}
        ):
            raise ValueError()
        if (
            value["schema_version"] != "rehearsal_evaluation_v1"
            or type(value["target_hash"]) is not str
            or re.fullmatch(r"[a-f0-9]{64}", value["target_hash"]) is None
            or value["target_hash"] != rehearsal_target["target_hash"]
        ):
            raise ValueError()
        for name, statuses in (("intent", INTENT_STATUSES), ("target_issue", ISSUE_STATUSES)):
            conclusion = value[name]
            if type(conclusion) is not dict or set(conclusion) != {
                "status",
                "explanation",
                "evidence",
            }:
                raise ValueError()
            if type(conclusion["status"]) is not str or conclusion["status"] not in statuses:
                raise ValueError()
            _text(conclusion["explanation"], 4096)
            evidence = conclusion["evidence"]
            if type(evidence) is not list or len(evidence) > 3:
                raise ValueError()
            if not evidence and conclusion["status"] != "insufficient_evidence":
                raise ValueError()
            for ref in evidence:
                if type(ref) is not dict or set(ref) != set(REFERENCE_FIELDS) | {"exact_quote"}:
                    raise ValueError()
                for key in REFERENCE_FIELDS[:2]:
                    if type(ref[key]) is not str or str(UUID(ref[key])) != ref[key]:
                        raise ValueError()
                if type(ref["revision"]) is not int or not 1 <= ref["revision"] <= 2147483647:
                    raise ValueError()
                _text(ref["exact_quote"], 8192)
                if not any(
                    all(ref[key] == target[key] for key in REFERENCE_FIELDS)
                    and target["eligibility"] != "excluded"
                    and ref["exact_quote"] in target["text"]
                    for target in targets
                ):
                    raise ValueError()
        return value
    except (ValueError, TypeError, KeyError, UnicodeError):
        raise APIError(409, "review_suggestions_invalid", "复盘输出未通过依据核对。") from None
