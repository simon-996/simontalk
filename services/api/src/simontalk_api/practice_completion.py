"""Fixed upload windows and immutable client-reported inputs, not media authority."""

import json
from datetime import datetime, timedelta
from typing import Literal
from uuid import UUID

from pydantic import Field, model_validator
from sqlalchemy import select

from simontalk_api.connections import ConnectionControl, own_connection
from simontalk_api.errors import APIError
from simontalk_api.models import (
    CompletionConnection,
    FinalTranscript,
    PlaybackEvidence,
    PracticeCompletion,
    PracticeSession,
    RealtimeConnection,
    User,
)
from simontalk_api.practice import own_preparation
from simontalk_api.schemas import InputModel
from simontalk_api.security import digest, now
from simontalk_api.termination_checks import ensure_termination_check

POLICY_VERSION = "final_text_candidate_v1"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


class SubmissionEventRef(InputModel):
    sequence: int = Field(strict=True, ge=1, le=2147483647)
    event_id: UUID


class LedgerManifest(InputModel):
    events: list[SubmissionEventRef] = Field(max_length=768)
    last_sequence: int = Field(strict=True, ge=0, le=2147483647)
    total_events: int = Field(strict=True, ge=0, le=768)
    total_text_bytes: int = Field(strict=True, ge=0, le=2 * 1024 * 1024)
    pending_count_at_close: int = Field(strict=True, ge=0, le=768)

    @model_validator(mode="after")
    def coherent(self):
        seq = [e.sequence for e in self.events]
        if (
            seq != sorted(set(seq))
            or len({e.event_id for e in self.events}) != len(seq)
            or self.total_events != len(seq)
            or self.last_sequence != (seq[-1] if seq else 0)
            or self.pending_count_at_close > len(seq)
            or (not seq and self.total_text_bytes != 0)
        ):
            raise ValueError("Invalid event manifest")
        return self


class CompletionManifest(ConnectionControl):
    transcripts: LedgerManifest
    playback: LedgerManifest
    tail_status: Literal["complete", "unconfirmed", "aborted"]
    unfinalized_turn_ids: list[UUID] = Field(max_length=256)
    unconfirmed_response_ids: list[UUID] = Field(max_length=256)
    transcript_rejected_count: int = Field(strict=True, ge=0, le=2147483647)
    playback_rejected_count: int = Field(strict=True, ge=0, le=2147483647)
    journal_unavailable: bool = Field(strict=True)

    @model_validator(mode="after")
    def bounded(self):
        if (
            self.transcripts.total_events > 512
            or self.transcripts.total_text_bytes > 1024 * 1024
            or len(set(self.unfinalized_turn_ids)) != len(self.unfinalized_turn_ids)
            or len(set(self.unconfirmed_response_ids)) != len(self.unconfirmed_response_ids)
        ):
            raise ValueError("Manifest bounds exceeded")
        return self


class CompletionSummary(InputModel):
    source: Literal["server_recorded"] = "server_recorded"
    account_id: UUID
    session_id: UUID
    origin_connection_id: UUID
    client_instance_id: UUID
    epoch: int
    end_key: UUID
    status: Literal["ending", "sealed"]
    accepted_at: datetime
    final_upload_deadline: datetime
    sealed_at: datetime | None
    input_revision: int
    input_hash: str | None
    coverage: Literal["pending", "complete", "incomplete"]
    connection_count: int
    gap_codes: list[str]


class CompletionReceipt(InputModel):
    source: Literal["server_recorded"] = "server_recorded"
    account_id: UUID
    session_id: UUID
    connection_id: UUID
    client_instance_id: UUID
    epoch: int
    sealed: Literal[True] = True
    recoverable: Literal[False] = False
    input_revision: Literal[1] = 1
    input_hash: str
    practice_input_hash: str
    transcript_events: list[SubmissionEventRef]
    playback_events: list[SubmissionEventRef]


def _summary(completion):
    fields = {
        name: getattr(completion, name)
        for name in CompletionSummary.model_fields
        if name not in {"source", "account_id"}
    }
    return CompletionSummary(account_id=completion.user_id, **fields)


def _completion(db, user_id, session_id):
    own_preparation(db, user_id, session_id)
    result = db.get(PracticeCompletion, session_id)
    if result is None:
        raise APIError(404, "completion_not_found", "这次练习还没有登记结束。")
    return result


def _members(db, completion):
    return list(
        db.scalars(
            select(CompletionConnection)
            .where(CompletionConnection.session_id == completion.session_id)
            .order_by(CompletionConnection.epoch, CompletionConnection.connection_id)
        )
    )


def _ledger_rows(db, connection_id):
    return [
        list(
            db.scalars(
                select(model).where(model.connection_id == connection_id).order_by(model.sequence)
            )
        )
        for model in (FinalTranscript, PlaybackEvidence)
    ]


def _stats(rows, *, playback=False):
    return {
        "last_sequence": rows[-1].sequence if rows else 0,
        "total_events": len(rows),
        "total_text_bytes": sum(
            len(((r.generated_text or "") + (r.played_text or "")).encode("utf-8"))
            if playback
            else len(r.text.encode("utf-8"))
            for r in rows
        ),
    }


def _refs(rows):
    return [{"sequence": r.sequence, "event_id": str(r.event_id)} for r in rows]


def _prefix(row):
    return {
        "playback_event_id": str(row.event_id),
        "transcript_revision": row.transcript_revision,
        "playback_revision": row.playback_revision,
        "delivery_status": row.delivery_status,
    }


def _turns(transcripts, playback, manifest, gaps):
    by_turn = {}
    for row in transcripts:
        prior = by_turn.get(row.turn_id)
        if prior is None or row.revision > prior.revision:
            by_turn[row.turn_id] = row
    revoked = {r.response_id for r in playback if r.kind == "revoke"}
    if revoked:
        gaps.add("playback_revoked")
    unfinalized = set(manifest["unfinalized_turn_ids"]) if manifest else set()
    turns = []
    for row in sorted(by_turn.values(), key=lambda r: (r.turn_index, str(r.turn_id))):
        if row.role == "assistant":
            eligibility, reason = "excluded", "assistant_text"
        elif not row.text.strip():
            eligibility, reason = "excluded", "empty_text"
        elif str(row.turn_id) in unfinalized:
            eligibility, reason = "uncertain", "unfinalized_turn"
        else:
            eligibility, reason = "eligible", "user_final_text"
        item = {
            "turn_id": str(row.turn_id),
            "turn_index": row.turn_index,
            "role": row.role,
            "transcript_event_id": str(row.event_id),
            "revision": row.revision,
            "candidate_eligibility": eligibility,
            "policy_version": POLICY_VERSION,
            "reason_codes": [reason],
            "final_prefix": None,
            "interrupted_prefix": None,
        }
        if row.role == "assistant" and row.response_id not in revoked:
            candidates = [
                r
                for r in playback
                if r.turn_id == row.turn_id
                and r.kind != "revoke"
                and r.transcript_revision == row.revision
                and r.generated_text == row.text
                and r.transcript_final
                and r.delivery_status in {"partial", "played"}
            ]
            if candidates:
                item["final_prefix"] = _prefix(
                    max(candidates, key=lambda r: (r.playback_revision, r.sequence))
                )
            freezes = [
                r
                for r in playback
                if r.turn_id == row.turn_id
                and r.kind == "freeze"
                and r.delivery_status in {"partial", "played"}
                and r.played_text
            ]
            if freezes:
                item["interrupted_prefix"] = _prefix(min(freezes, key=lambda r: r.sequence))
            not_played = any(
                r.turn_id == row.turn_id
                and r.kind != "revoke"
                and r.transcript_revision == row.revision
                and r.generated_text == row.text
                and r.transcript_final
                and r.delivery_status == "not_played"
                for r in playback
            )
            if (
                item["final_prefix"] is None
                and item["interrupted_prefix"] is None
                and not not_played
            ):
                gaps.add("playback_unconfirmed")
        turns.append(item)
    # Playback snapshots carry independently checkable source versions even if
    # the final-text journal never accepted a matching event. Keep their gaps.
    playback_turns = {}
    for row in playback:
        if row.kind != "revoke" and row.turn_id not in by_turn:
            playback_turns.setdefault(row.turn_id, []).append(row)
    for source_rows in playback_turns.values():
        row = max(
            source_rows, key=lambda r: (r.transcript_revision, r.playback_revision, r.sequence)
        )
        if not row.transcript_final:
            gaps.add("unfinalized_turn")
        final_prefix = interrupted_prefix = None
        if row.response_id not in revoked:
            if row.transcript_final and row.delivery_status in {"partial", "played"}:
                final_prefix = _prefix(row)
            freezes = [
                r
                for r in source_rows
                if r.kind == "freeze"
                and r.delivery_status in {"partial", "played"}
                and r.played_text
            ]
            if freezes:
                interrupted_prefix = _prefix(min(freezes, key=lambda r: r.sequence))
            if (
                final_prefix is None
                and interrupted_prefix is None
                and not (row.transcript_final and row.delivery_status == "not_played")
            ):
                gaps.add("playback_unconfirmed")
        turns.append(
            {
                "turn_id": str(row.turn_id),
                "turn_index": row.turn_index,
                "role": "assistant",
                "transcript_event_id": None,
                "revision": row.transcript_revision,
                "candidate_eligibility": "excluded",
                "policy_version": POLICY_VERSION,
                "reason_codes": ["assistant_text"],
                "final_prefix": final_prefix,
                "interrupted_prefix": interrupted_prefix,
            }
        )
    return sorted(turns, key=lambda r: (r["turn_index"], r["turn_id"]))


def _view(db, completion, member):
    transcripts, playback = _ledger_rows(db, member.connection_id)
    manifest = member.manifest
    gaps = set()
    ledgers = {}
    covered = True
    safe_empty = member.empty_not_started and not transcripts and not playback
    if manifest is None and not safe_empty:
        gaps.add("manifest_missing")
        covered = False
    for name, rows in (("transcripts", transcripts), ("playback", playback)):
        declared = manifest[name] if manifest else None
        actual = _refs(rows)
        actual_map = {r["event_id"]: r["sequence"] for r in actual}
        declared_map = (
            {r["event_id"]: r["sequence"] for r in declared["events"]} if declared else {}
        )
        missing = sorted(k for k, v in declared_map.items() if actual_map.get(k) != v)
        unexpected = sorted(
            k for k, v in actual_map.items() if declared and declared_map.get(k) != v
        )
        prefix = "transcript" if name == "transcripts" else "playback"
        received = _stats(rows, playback=name == "playback")
        if missing:
            gaps.add(f"{prefix}_missing")
        if unexpected:
            gaps.add(f"{prefix}_unexpected")
        mismatch = declared is not None and any(received[k] != declared[k] for k in received)
        if mismatch:
            gaps.add("manifest_totals_mismatch")
        covered &= not missing and not unexpected and not mismatch
        ledgers[name] = {
            "declared": declared,
            "received": received,
            "missing_event_ids": missing,
            "unexpected_event_ids": unexpected,
            "events": actual,
        }
    if manifest:
        for field, code in (
            ("transcript_rejected_count", "transcript_rejected"),
            ("playback_rejected_count", "playback_rejected"),
            ("unfinalized_turn_ids", "unfinalized_turn"),
            ("unconfirmed_response_ids", "unconfirmed_response"),
            ("journal_unavailable", "journal_unavailable"),
        ):
            if manifest[field]:
                gaps.add(code)
        if manifest["tail_status"] != "complete":
            gaps.add("tail_" + manifest["tail_status"])
    elif not safe_empty:
        gaps.add("tail_unconfirmed")
    turns = _turns(transcripts, playback, manifest, gaps)
    scope = {
        "account_id": str(completion.user_id),
        "session_id": str(completion.session_id),
        "connection_id": str(member.connection_id),
        "client_instance_id": str(member.client_instance_id),
        "epoch": member.epoch,
    }
    coverage = (
        "empty_not_started"
        if safe_empty and manifest is None
        else ("incomplete" if gaps else "complete")
    )
    view = {
        "source": "server_recorded",
        **scope,
        "sealed": False,
        "recoverable": False,
        "input_revision": 0,
        "input_hash": None,
        "coverage": coverage,
        "gap_codes": sorted(gaps),
        "manifest_received": manifest is not None,
        "tail_status": manifest["tail_status"] if manifest else None,
        **ledgers,
        "turns": turns,
    }
    hash_input = {
        "schema_version": 1,
        "policy_version": POLICY_VERSION,
        "scope": scope,
        "manifest": manifest,
        "coverage": coverage,
        "gap_codes": view["gap_codes"],
        "turns": turns,
        "transcripts": [
            {**r, "event_digest": e.event_digest}
            for r, e in zip(_refs(transcripts), transcripts, strict=True)
        ],
        "playback": [
            {**r, "event_digest": e.event_digest}
            for r, e in zip(_refs(playback), playback, strict=True)
        ],
    }
    return view, digest(canonical(hash_input)), covered


def try_finalize_completion(db, practice, *, stamp=None, force=False):
    completion = db.get(PracticeCompletion, practice.id)
    if completion is None or completion.status == "sealed":
        return False
    stamp = stamp or now()
    members = _members(db, completion)
    views = [(member, *_view(db, completion, member)) for member in members]
    if (
        not force
        and stamp < completion.final_upload_deadline
        and not all(item[3] for item in views)
    ):
        return False
    gaps = set()
    hashes = []
    for member, view, snapshot_hash, _ in views:
        view.update(sealed=True, input_revision=1, input_hash=snapshot_hash)
        member.snapshot = view
        member.snapshot_hash = snapshot_hash
        gaps.update(view["gap_codes"])
        hashes.append(
            {
                "connection_id": str(member.connection_id),
                "client_instance_id": str(member.client_instance_id),
                "epoch": member.epoch,
                "input_hash": snapshot_hash,
            }
        )
    completion.status = "sealed"
    completion.input_revision = 1
    completion.sealed_at = stamp
    completion.gap_codes = sorted(gaps)
    completion.coverage = "incomplete" if gaps else "complete"
    completion.input_hash = digest(
        canonical(
            {
                "schema_version": 1,
                "policy_version": POLICY_VERSION,
                "session_id": str(practice.id),
                "members": hashes,
            }
        )
    )
    practice.status = "completed"
    practice.ended_at = stamp
    practice.state_reason = "input_sealed"
    return True


def begin_completion(db, user_id, session_id, connection_id, payload, key):
    practice = own_preparation(db, user_id, session_id, lock=True)
    # Ownership is read first; every member is locked together in epoch order below.
    connection = own_connection(db, user_id, session_id, connection_id)
    fingerprint = digest(
        canonical({"connection_id": str(connection_id), **payload.model_dump(mode="json")})
    )
    existing = db.scalar(
        select(PracticeCompletion).where(
            PracticeCompletion.user_id == user_id, PracticeCompletion.end_key == key
        )
    )
    completion = db.get(PracticeCompletion, session_id)
    if existing is not None or completion is not None:
        if (
            existing is None
            or existing.session_id != session_id
            or existing.request_digest != fingerprint
        ):
            raise APIError(409, "idempotency_conflict", "这个结束请求已登记，请读取当前结果。")
        return _summary(existing)
    if (
        connection.client_instance_id != payload.client_instance_id
        or connection.epoch != payload.epoch
    ):
        raise APIError(409, "connection_identity_changed", "连接身份或代次已变化。")
    if practice.connection_epoch != connection.epoch:
        raise APIError(409, "connection_epoch_changed", "这条连接已不是当前连接。")
    if practice.status in {"cancelled", "failed", "completed"}:
        raise APIError(409, "completion_state_changed", "这次练习不能登记结束。")
    connections = list(
        db.scalars(
            select(RealtimeConnection)
            .where(RealtimeConnection.session_id == session_id)
            .order_by(RealtimeConnection.epoch, RealtimeConnection.id)
            .with_for_update()
        )
    )
    stamp = now()
    completion = PracticeCompletion(
        session_id=session_id,
        user_id=user_id,
        origin_connection_id=connection_id,
        client_instance_id=connection.client_instance_id,
        epoch=connection.epoch,
        end_key=key,
        request_digest=fingerprint,
        status="ending",
        accepted_at=stamp,
        final_upload_deadline=stamp + timedelta(seconds=30),
        input_revision=0,
        coverage="pending",
        connection_count=len(connections),
        gap_codes=[],
    )
    db.add(completion)
    db.flush()
    for current in connections:
        safe = (
            current.termination_status == "not_started"
            and current.offer_digest is None
            and current.signalling_started_at is None
            and current.signalling_finished_at is None
        )
        old_empty = (
            safe
            and current.epoch < connection.epoch
            and current.status in {"closed", "failed"}
            and current.ended_at is not None
        )
        db.add(
            CompletionConnection(
                connection_id=current.id,
                session_id=session_id,
                client_instance_id=current.client_instance_id,
                epoch=current.epoch,
                empty_not_started=old_empty,
            )
        )
        if current.status not in {"closed", "failed"}:
            if safe:
                current.status = "closed"
                current.ended_at = stamp
                current.state_reason = "ended_before_signalling"
            else:
                current.status = "unknown"
                current.termination_status = "unknown"
                current.state_reason = "end_requested"
                ensure_termination_check(db, current, stamp)
    practice.status = "ending"
    practice.state_reason = "end_requested"
    db.flush()
    try_finalize_completion(db, practice, stamp=stamp)
    db.commit()
    return _summary(completion)


def _sealed():
    raise APIError(409, "practice_input_sealed", "练习输入已结束补交，不能再添加内容。")


def validate_completion_append(db, practice, connection, ledger, event, stamp=None):
    completion = db.get(PracticeCompletion, practice.id)
    if completion is None:
        return
    if completion.status == "sealed" or (stamp or now()) >= completion.final_upload_deadline:
        _sealed()
    member = db.get(CompletionConnection, connection.id)
    if member is None:
        raise APIError(409, "completion_manifest_conflict", "连接不在结束范围中。")
    if member.manifest is not None and not any(
        r["event_id"] == str(event.event_id) and r["sequence"] == event.sequence
        for r in member.manifest[ledger]["events"]
    ):
        raise APIError(409, "completion_manifest_conflict", "内容不在最终提交清单中。")


def submit_manifest(db, user_id, session_id, connection_id, payload):
    practice = own_preparation(db, user_id, session_id, lock=True)
    connection = own_connection(db, user_id, session_id, connection_id, lock=True)
    if (
        connection.client_instance_id != payload.client_instance_id
        or connection.epoch != payload.epoch
    ):
        raise APIError(409, "connection_identity_changed", "连接身份或代次已变化。")
    completion = _completion(db, user_id, session_id)
    member = db.get(CompletionConnection, connection_id)
    if member is None or member.session_id != session_id:
        raise APIError(409, "completion_manifest_conflict", "连接不在结束范围中。")
    value = payload.model_dump(mode="json")
    fingerprint = digest(canonical(value))
    if member.manifest is not None:
        if member.manifest_digest != fingerprint:
            raise APIError(409, "completion_manifest_conflict", "最终提交清单已固定。")
        return _summary(completion)
    stamp = now()
    if completion.status == "sealed" or stamp >= completion.final_upload_deadline:
        _sealed()
    member.manifest, member.manifest_digest, member.manifest_received_at = value, fingerprint, stamp
    db.flush()
    try_finalize_completion(db, practice, stamp=stamp)
    db.commit()
    return _summary(completion)


def read_completion(db, user_id, session_id):
    return _summary(_completion(db, user_id, session_id))


def _read_member(db, user_id, session_id, connection_id):
    own_connection(db, user_id, session_id, connection_id)
    # A receipt must not combine a post-seal member with a pre-seal global hash.
    result = db.execute(
        select(PracticeCompletion, CompletionConnection)
        .join(
            CompletionConnection, CompletionConnection.session_id == PracticeCompletion.session_id
        )
        .where(
            PracticeCompletion.user_id == user_id,
            PracticeCompletion.session_id == session_id,
            CompletionConnection.connection_id == connection_id,
        )
        .execution_options(populate_existing=True)
    ).one_or_none()
    if result is None:
        raise APIError(404, "completion_not_found", "没有找到这条连接的结束记录。")
    return result


def read_connection_completion(db, user_id, session_id, connection_id):
    completion, member = _read_member(db, user_id, session_id, connection_id)
    return member.snapshot if member.snapshot is not None else _view(db, completion, member)[0]


def read_completion_receipt(db, user_id, session_id, connection_id):
    completion, member = _read_member(db, user_id, session_id, connection_id)
    view = member.snapshot
    if view is None or completion.status != "sealed":
        raise APIError(409, "completion_not_sealed", "练习输入尚未固化，请稍后读取。")
    return CompletionReceipt(
        account_id=user_id,
        session_id=session_id,
        connection_id=connection_id,
        client_instance_id=view["client_instance_id"],
        epoch=view["epoch"],
        input_hash=view["input_hash"],
        practice_input_hash=completion.input_hash,
        transcript_events=view["transcripts"]["events"],
        playback_events=view["playback"]["events"],
    )


def finalize_due_completions(db, *, limit=100):
    if type(limit) is not int or not 1 <= limit <= 1000:
        raise ValueError("Invalid scan limit")
    stamp = now()
    candidates = db.execute(
        select(PracticeCompletion.session_id, PracticeCompletion.user_id)
        .where(
            PracticeCompletion.status == "ending", PracticeCompletion.final_upload_deadline <= stamp
        )
        .order_by(PracticeCompletion.final_upload_deadline, PracticeCompletion.session_id)
        .limit(limit)
    ).all()
    count = 0
    for session_id, user_id in candidates:
        if (
            db.scalar(select(User.id).where(User.id == user_id).with_for_update(skip_locked=True))
            is None
        ):
            continue
        practice = db.scalar(
            select(PracticeSession)
            .where(PracticeSession.id == session_id, PracticeSession.user_id == user_id)
            .with_for_update(skip_locked=True)
            .execution_options(populate_existing=True)
        )
        if practice is None:
            continue
        completion = db.scalar(
            select(PracticeCompletion)
            .where(
                PracticeCompletion.session_id == session_id,
                PracticeCompletion.status == "ending",
                PracticeCompletion.final_upload_deadline <= stamp,
            )
            .execution_options(populate_existing=True)
        )
        if completion is None:
            continue
        connections = list(
            db.scalars(
                select(RealtimeConnection)
                .where(RealtimeConnection.session_id == session_id)
                .order_by(RealtimeConnection.epoch, RealtimeConnection.id)
                .with_for_update(skip_locked=True)
                .execution_options(populate_existing=True)
            )
        )
        if len(connections) != completion.connection_count:
            continue
        count += try_finalize_completion(db, practice, stamp=stamp, force=True)
    return count
