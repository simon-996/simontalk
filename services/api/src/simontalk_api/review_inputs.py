"""Sealed review input storage, bounded source verification, and internal quote gate."""

from typing import Literal
from uuid import UUID

from pydantic import Field, ValidationError
from sqlalchemy import func, select

from simontalk_api.errors import APIError
from simontalk_api.final_transcripts import TranscriptEvent
from simontalk_api.models import (
    CompletionConnection,
    FinalTranscript,
    PlaybackEvidence,
    PracticeCompletion,
    RealtimeConnection,
    ReviewInput,
)
from simontalk_api.playback_evidence import PlaybackEvent
from simontalk_api.practice import own_preparation
from simontalk_api.practice_completion import POLICY_VERSION as COMPLETION_POLICY
from simontalk_api.practice_completion import _stats, canonical
from simontalk_api.review_input_policy import (
    POLICY_VERSION,
    ReviewInputLimit,
    derive_scope,
    resolve_ref,
    wire_size,
)
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest

MAX_MEMBERS = 32
MAX_SOURCE_EVENTS = 8192
MAX_SOURCE_BYTES = 4 * 1024 * 1024
MAX_EXPANDED_BYTES = 512 * 1024


class ReviewInputRequest(InputModel):
    input_revision: int = Field(strict=True, ge=1)
    input_hash: str = Field(strict=True, pattern=r"^[a-f0-9]{64}$")


class ReviewSuggestion(InputModel):
    source_connection_id: UUID
    source_turn_id: UUID
    revision: int = Field(strict=True, ge=1)
    exact_quote: str = Field(strict=True, min_length=1, max_length=8192)
    kind: Literal["correction", "polish", "extension"]
    basis: Literal["text_only", "conversation_context"]
    explanation: str = Field(strict=True, min_length=1, max_length=4096)
    suggestion: str = Field(strict=True, min_length=1, max_length=8192)


def _changed():
    raise APIError(409, "review_input_changed", "复盘输入依据发生变化，请重新读取保存状态。")


def _limit():
    raise APIError(409, "review_input_limit_exceeded", "这次练习超出当前复盘输入范围。")


def check_source_budget(members, events, text_bytes):
    if members > MAX_MEMBERS or events > MAX_SOURCE_EVENTS or text_bytes > MAX_SOURCE_BYTES:
        _limit()


def _completion(db, user_id, session_id, *, lock=False):
    own_preparation(db, user_id, session_id, lock=lock)
    completion = db.get(PracticeCompletion, session_id)
    if completion is None or completion.status != "sealed":
        raise APIError(409, "completion_not_sealed", "练习输入尚未封存。")
    if completion.user_id != user_id or completion.input_revision != 1:
        _changed()
    return completion


def _source_row(row, schema, member):
    if (
        row.client_instance_id != member.client_instance_id
        or row.epoch != member.epoch
        or row.source != "client_reported"
    ):
        _changed()
    payload = schema.model_validate({field: getattr(row, field) for field in schema.model_fields})
    value = payload.model_dump(mode="json")
    if digest(canonical(value)) != row.event_digest:
        _changed()
    return {**value, "event_digest": row.event_digest}


def _load_sources(db, completion):
    """Aggregate counts/bytes before materializing source text or member snapshots."""
    member_query = select(CompletionConnection).where(
        CompletionConnection.session_id == completion.session_id
    )
    count = db.scalar(select(func.count()).select_from(member_query.subquery()))
    check_source_budget(count, 0, 0)
    if count != completion.connection_count:
        _changed()
    events = size = 0
    for model, bytes_expr in (
        (FinalTranscript, func.octet_length(FinalTranscript.text)),
        (
            PlaybackEvidence,
            func.coalesce(func.octet_length(PlaybackEvidence.generated_text), 0)
            + func.coalesce(func.octet_length(PlaybackEvidence.played_text), 0),
        ),
    ):
        amount, byte_count = db.execute(
            select(func.count(), func.coalesce(func.sum(bytes_expr), 0))
            .select_from(model)
            .join(CompletionConnection, CompletionConnection.connection_id == model.connection_id)
            .where(CompletionConnection.session_id == completion.session_id)
        ).one()
        events += amount
        size += byte_count
    check_source_budget(count, events, size)
    members = list(
        db.scalars(
            member_query.order_by(
                CompletionConnection.epoch, CompletionConnection.connection_id
            ).limit(MAX_MEMBERS + 1)
        )
    )
    all_sources, scopes, hashes = {}, [], []
    for member in members:
        connection = db.get(RealtimeConnection, member.connection_id)
        if (
            connection is None
            or connection.user_id != completion.user_id
            or connection.session_id != completion.session_id
        ):
            _changed()
        transcripts, playback = [], []
        for model, schema, target, ledger in (
            (FinalTranscript, TranscriptEvent, transcripts, "transcripts"),
            (PlaybackEvidence, PlaybackEvent, playback, "playback"),
        ):
            rows = list(
                db.scalars(
                    select(model)
                    .where(model.connection_id == member.connection_id)
                    .order_by(model.sequence)
                    .limit(MAX_SOURCE_EVENTS + 1)
                )
            )
            for row in rows:
                value = _source_row(row, schema, member)
                target.append(value)
                all_sources[(str(member.connection_id), ledger, str(row.event_id))] = value
            view = member.snapshot
            if not isinstance(view, dict) or view[ledger]["events"] != [
                {"sequence": row.sequence, "event_id": str(row.event_id)} for row in rows
            ]:
                _changed()
            if view[ledger]["received"] != _stats(rows, playback=ledger == "playback"):
                _changed()
        scope = {
            "account_id": str(completion.user_id),
            "session_id": str(completion.session_id),
            "connection_id": str(member.connection_id),
            "client_instance_id": str(member.client_instance_id),
            "epoch": member.epoch,
        }
        view = member.snapshot
        if (
            any(view.get(key) != value for key, value in scope.items())
            or not view.get("sealed")
            or view.get("input_revision") != 1
            or view.get("input_hash") != member.snapshot_hash
        ):
            _changed()
        if (
            member.manifest is not None
            and digest(canonical(member.manifest)) != member.manifest_digest
        ):
            _changed()
        original_hash = digest(
            canonical(
                {
                    "schema_version": 1,
                    "policy_version": COMPLETION_POLICY,
                    "scope": scope,
                    "manifest": member.manifest,
                    "coverage": view["coverage"],
                    "gap_codes": view["gap_codes"],
                    "turns": view["turns"],
                    "transcripts": [
                        {
                            "sequence": row["sequence"],
                            "event_id": row["event_id"],
                            "event_digest": row["event_digest"],
                        }
                        for row in transcripts
                    ],
                    "playback": [
                        {
                            "sequence": row["sequence"],
                            "event_id": row["event_id"],
                            "event_digest": row["event_digest"],
                        }
                        for row in playback
                    ],
                }
            )
        )
        if original_hash != member.snapshot_hash:
            _changed()
        hashes.append(
            {
                "connection_id": scope["connection_id"],
                "client_instance_id": scope["client_instance_id"],
                "epoch": member.epoch,
                "input_hash": original_hash,
            }
        )
        scopes.append((scope, transcripts, playback, view, member.manifest))
    if (
        digest(
            canonical(
                {
                    "schema_version": 1,
                    "policy_version": COMPLETION_POLICY,
                    "session_id": str(completion.session_id),
                    "members": hashes,
                }
            )
        )
        != completion.input_hash
    ):
        _changed()
    return scopes, all_sources


def _derive(completion, sources):
    scopes, all_sources = sources
    snapshot = {
        "source": "server_derived",
        "evidence_source": "client_reported",
        "account_id": str(completion.user_id),
        "session_id": str(completion.session_id),
        "input_revision": 1,
        "practice_input_hash": completion.input_hash,
        "policy_version": POLICY_VERSION,
        "status": "no_evaluable_content",
        "counts": {"eligible": 0, "uncertain": 0, "excluded": 0},
        "scopes": [],
    }
    consumed = wire_size(snapshot) + 256
    for scope, transcripts, playback, view, manifest in scopes:
        derived, amount = derive_scope(
            scope,
            transcripts,
            playback,
            view,
            manifest,
            remaining_bytes=MAX_EXPANDED_BYTES - consumed,
        )
        consumed += amount
        snapshot["scopes"].append(derived)
        for decision in derived["decisions"]:
            snapshot["counts"][decision["eligibility"]] += 1
    if snapshot["counts"]["eligible"] + snapshot["counts"]["uncertain"]:
        snapshot["status"] = "ready"
    return snapshot


def _render(record, sources):
    response = {
        **record.snapshot,
        "review_input_hash": record.review_input_hash,
        "created_at": record.created_at,
    }
    rendered_scopes = []
    for scope in record.snapshot["scopes"]:
        local = {
            (ledger, event_id): row
            for (connection, ledger, event_id), row in sources.items()
            if connection == scope["connection_id"]
        }
        decisions = []
        for decision in scope["decisions"]:
            item = {**decision}
            if decision["eligibility"] != "excluded":
                row = local[("transcripts", decision["transcript_event_id"])]
                if (
                    row["event_digest"] != decision["event_digest"]
                    or row["revision"] != decision["revision"]
                    or row["turn_id"] != decision["turn_id"]
                    or row["role"] != "user"
                ):
                    _changed()
                item["text"] = row["text"]
                item["context_before"] = [
                    resolve_ref(ref, local) for ref in decision["context_before"]
                ]
            decisions.append(item)
        rendered_scopes.append({**scope, "decisions": decisions})
    response["scopes"] = rendered_scopes
    if wire_size({**response, "created_at": record.created_at.isoformat()}) > MAX_EXPANDED_BYTES:
        _limit()
    return response


def _verified(db, completion, record):
    if (
        record.user_id != completion.user_id
        or record.practice_input_hash != completion.input_hash
        or record.input_revision != 1
        or record.policy_version != POLICY_VERSION
        or digest(canonical(record.snapshot)) != record.review_input_hash
    ):
        _changed()
    sources = _load_sources(db, completion)
    # Re-derive references from the original seal, never trust a caller's projection.
    if _derive(completion, sources) != record.snapshot:
        _changed()
    return _render(record, sources[1])


def create_review_input(db, user_id, session_id, payload):
    completion = _completion(db, user_id, session_id, lock=True)
    if payload.input_revision != 1 or payload.input_hash != completion.input_hash:
        _changed()
    key = (session_id, 1, POLICY_VERSION)
    record = db.get(ReviewInput, key)
    try:
        if record is not None:
            return _verified(db, completion, record)
        sources = _load_sources(db, completion)
        snapshot = _derive(completion, sources)
        record = ReviewInput(
            session_id=session_id,
            user_id=user_id,
            input_revision=1,
            policy_version=POLICY_VERSION,
            practice_input_hash=completion.input_hash,
            review_input_hash=digest(canonical(snapshot)),
            snapshot=snapshot,
        )
        db.add(record)
        db.flush()
        response = _render(record, sources[1])
        db.commit()
        return response
    except ReviewInputLimit:
        _limit()
    except (KeyError, ValueError, TypeError, ValidationError):
        _changed()


def read_review_input(db, user_id, session_id):
    own_preparation(db, user_id, session_id)
    record = db.get(ReviewInput, (session_id, 1, POLICY_VERSION))
    if record is None:
        raise APIError(404, "review_input_not_found", "这次练习尚未建立复盘输入。")
    try:
        return _verified(db, _completion(db, user_id, session_id), record)
    except ReviewInputLimit:
        _limit()
    except (KeyError, ValueError, TypeError, ValidationError):
        _changed()


def validate_review_suggestions(
    db,
    user_id,
    session_id,
    *,
    input_revision,
    practice_input_hash,
    review_input_hash,
    policy_version,
    suggestions,
):
    """Internal only. Valid references do not establish linguistic or audio correctness."""
    data = read_review_input(db, user_id, session_id)
    if (
        type(input_revision) is not int
        or input_revision != data["input_revision"]
        or practice_input_hash != data["practice_input_hash"]
        or review_input_hash != data["review_input_hash"]
        or policy_version != data["policy_version"]
    ):
        _changed()
    try:
        if type(suggestions) is not list or len(suggestions) > 3:
            raise ValueError("Invalid suggestion count")
        parsed = [ReviewSuggestion.model_validate(item) for item in suggestions]
        targets = {
            (scope["connection_id"], entry["turn_id"], entry["revision"]): entry
            for scope in data["scopes"]
            for entry in scope["decisions"]
            if entry["eligibility"] != "excluded"
        }
        for item in parsed:
            target = targets.get(
                (str(item.source_connection_id), str(item.source_turn_id), item.revision)
            )
            if (
                target is None
                or item.exact_quote not in target["text"]
                or not item.exact_quote.strip()
                or item.basis not in target["allowed_bases"]
                or not item.explanation.strip()
                or not item.suggestion.strip()
            ):
                raise ValueError("Invalid suggestion reference")
        return [item.model_dump(mode="json") for item in parsed]
    except (ValueError, ValidationError):
        raise APIError(
            409, "review_suggestions_invalid", "复盘建议未通过原话与依据核对。"
        ) from None
