"""A separately saved deletion snapshot can clean an older restored database."""

import copy
import json
import stat
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import text
from test_practice_deletion import erase, snapshot
from test_rehearsal_preparations import create, release, target
from test_rehearsal_targets import rows
from test_rehearsal_targets import target_source as target_source
from test_saved_transcripts import scope as scope

from simontalk_api.db import Base
from simontalk_api.deletion_archive import (
    DeletionArchiveError,
    export_deletions,
    load_archive_bytes,
    read_archive,
    write_archive,
)
from simontalk_api.deletion_restore import replay_deletions
from simontalk_api.models import PracticeSession, RealtimeConnection
from simontalk_api.practice_completion import canonical
from simontalk_api.security import digest


def backup_rows(factory):
    with factory() as db:
        return {
            t.name: [dict(r) for r in db.execute(t.select()).mappings()]
            for t in Base.metadata.sorted_tables
        }


def restore_rows(factory, backup):
    with factory.begin() as db:
        db.execute(
            text("TRUNCATE users,invites,rate_limit_buckets,practice_deletion_receipts CASCADE")
        )
        for table in Base.metadata.sorted_tables:
            records = copy.deepcopy(backup[table.name])
            if table.name == "practice_sessions":
                records.sort(key=lambda r: (r["kind"] == "rehearsal", str(r["id"])))
            if records:
                db.execute(table.insert(), records)


@pytest.fixture
def deleted(client, target_source, factory):
    source = target_source
    release(factory, source)
    early = backup_rows(factory)
    children = []
    for _ in range(2):
        result = create(client, source, target(client, source))
        assert result.status_code == 201, result.text
        child = result.json()["practice"]
        children.append(child["id"])
        assert (
            client.post(
                f"/v1/practice-sessions/{child['id']}/cancel-preparation",
                headers=source.scope.headers,
            ).status_code
            == 200
        )
    # Restored unknown upstream evidence must never become safe merely by erasure.
    with factory.begin() as db:
        c = db.get(RealtimeConnection, UUID(source.connection["id"]))
        c.status, c.termination_status, c.ended_at = "unknown", "unknown", None
        c.offer_digest, c.signalling_started_at = "a" * 64, c.created_at
    backup = backup_rows(factory)
    h, sid = source.scope.headers, source.scope.session["id"]
    assert erase(client, children[0], h, snapshot(client, children[0], h)).status_code == 200
    assert erase(client, sid, h, snapshot(client, sid, h)).status_code == 200
    return SimpleNamespace(
        source=source,
        children=children,
        early=early,
        backup=backup,
        archive=export_deletions(factory),
        sid=sid,
        owner=source.scope.identity["user"]["id"],
    )


def apply(factory, archive):
    return replay_deletions(
        factory, archive, apply=True, confirm_database=factory.kw["bind"].url.database
    )


def encoded(archive, change=None):
    payload = archive.model_dump(mode="json")
    if change:
        change(payload)
    payload.pop("content_hash", None)
    payload["content_hash"] = digest(canonical(payload))
    return json.dumps(payload).encode()


def test_export_is_complete_owner_scoped_no_body_and_zero_write(deleted, factory):
    before = rows(factory)
    archive = export_deletions(factory)
    assert rows(factory) == before
    payload = archive.model_dump(mode="json")
    assert payload["schema_version"] == "deletion_archive_v1"
    assert len(payload["receipts"]) == 2
    assert [r["record_count"] for r in payload["receipts"]] == [1, 2]
    assert len({m["id"] for r in payload["receipts"] for m in r["members"]}) == 3
    assert deleted.source.original["text"] not in json.dumps(payload)
    assert set(payload) == {"schema_version", "exported_at", "receipts", "content_hash"}
    assert load_archive_bytes(encoded(archive)).content_hash == archive.content_hash


def test_empty_archive_is_explicit_and_previews_zero_writes(factory):
    before = rows(factory)
    archive = export_deletions(factory)
    assert archive.receipts == []
    result = replay_deletions(factory, archive)
    assert result["receipt_count"] == 0 and not result["applied"]
    assert rows(factory) == before


def test_private_atomic_file_roundtrip_and_existing_destination_not_overwritten(tmp_path, deleted):
    path = tmp_path / "deletions.json"
    write_archive(path, deleted.archive)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert read_archive(path).content_hash == deleted.archive.content_hash
    original = path.read_bytes()
    with pytest.raises(DeletionArchiveError):
        write_archive(path, deleted.archive)
    assert path.read_bytes() == original
    assert sorted(p.name for p in tmp_path.iterdir()) == ["deletions.json"]


@pytest.mark.parametrize(
    "mutation",
    [
        lambda j: j.update(schema_version="future"),
        lambda j: j.update(extra="PRIVATE"),
        lambda j: j["receipts"][0].update(record_count=4),
        lambda j: j["receipts"][0].update(connection_pending=1),
        lambda j: j["receipts"][0].update(deleted_at="2026-10-23"),
        lambda j: j["receipts"][0]["members"][0].update(parent=None),
        lambda j: j["receipts"].reverse(),
        lambda j: j["receipts"].append(j["receipts"][0]),
        lambda j: j.update(exported_at="2020-01-01T00:00:00Z"),
    ],
)
def test_recomputed_digest_cannot_bypass_shape_and_membership(deleted, mutation):
    with pytest.raises(DeletionArchiveError):
        load_archive_bytes(encoded(deleted.archive, mutation))


def test_bad_digest_duplicate_json_keys_and_oversize_rejected(deleted, monkeypatch):
    from simontalk_api import deletion_archive

    value = json.loads(encoded(deleted.archive))
    value["content_hash"] = "b" * 64
    for raw in [
        json.dumps(value).encode(),
        b'{"schema_version":"a","schema_version":"b"}',
        b"[]",
        b"\xff",
    ]:
        with pytest.raises(DeletionArchiveError):
            load_archive_bytes(raw)
    monkeypatch.setattr(deletion_archive, "MAX_ARCHIVE_BYTES", 16)
    with pytest.raises(DeletionArchiveError):
        load_archive_bytes(b"x" * 17)


def test_export_refuses_incomplete_tombstone_coverage(deleted, factory):
    with factory.begin() as db:
        db.execute(text("DELETE FROM practice_deletion_receipts"))
    before = rows(factory)
    with pytest.raises(DeletionArchiveError):
        export_deletions(factory)
    assert rows(factory) == before


def test_restore_dry_run_then_apply_and_repeat_are_safe_and_atomic(deleted, client, factory):
    restore_rows(factory, deleted.backup)
    before = rows(factory)
    preview = replay_deletions(factory, deleted.archive)
    assert preview["present_records"] == 3 and preview["newly_hidden_records"] == 3
    assert rows(factory) == before
    result = apply(factory, deleted.archive)
    assert result["applied"] and result["receipt_count"] == 2
    h = deleted.source.scope.headers
    assert client.get(f"/v1/practice-history/{deleted.sid}", headers=h).status_code == 404
    assert client.get("/v1/practice-history", headers=h).json()["items"] == []
    assert (
        client.get("/v1/practice-sessions/current", headers=h).json()["connection"]["status"]
        == "unknown"
    )
    with factory() as db:
        for table in [
            "final_transcripts",
            "playback_evidence",
            "review_inputs",
            "review_jobs",
            "review_results",
            "practice_completions",
            "completion_connections",
        ]:
            assert db.scalar(text(f"SELECT count(*) FROM {table}")) == 0, table
        assert db.scalar(text("SELECT count(*) FROM review_attempts WHERE job_id IS NULL")) == 1
        assert (
            db.scalar(
                text(
                    "SELECT count(*) FROM termination_checks WHERE status='blocked' AND attempts=0"
                )
            )
            == 1
        )
    final = rows(factory)
    assert apply(factory, deleted.archive)["newly_hidden_records"] == 0
    assert rows(factory) == final


def test_apply_requires_exact_target_database_confirmation(deleted, factory):
    restore_rows(factory, deleted.backup)
    before = rows(factory)
    for name in [None, "wrong_database"]:
        with pytest.raises(DeletionArchiveError):
            replay_deletions(factory, deleted.archive, apply=True, confirm_database=name)
    assert rows(factory) == before


def test_backup_missing_later_children_is_cleaned_without_recreating_records(deleted, factory):
    restore_rows(factory, deleted.early)
    result = apply(factory, deleted.archive)
    assert result["present_records"] == 1 and result["missing_records"] == 2
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM practice_sessions")) == 1
        assert (
            db.scalar(text("SELECT count(*) FROM practice_sessions WHERE deleted_at IS NOT NULL"))
            == 1
        )
        assert db.scalar(text("SELECT count(*) FROM practice_deletion_receipts")) == 2
    exported = export_deletions(factory)
    assert exported.receipts == deleted.archive.receipts
    restore_rows(factory, deleted.backup)
    assert apply(factory, exported)["newly_hidden_records"] == 3
    assert export_deletions(factory).receipts == exported.receipts


def test_missing_account_is_not_recreated(deleted, factory):
    with factory.begin() as db:
        db.execute(
            text("TRUNCATE users,invites,rate_limit_buckets,practice_deletion_receipts CASCADE")
        )
    result = apply(factory, deleted.archive)
    assert result["missing_accounts"] == 1
    with factory() as db:
        assert db.scalar(text("SELECT count(*) FROM users")) == 0
        assert db.scalar(text("SELECT count(*) FROM practice_sessions")) == 0
    assert export_deletions(factory).receipts == deleted.archive.receipts


def test_archive_requires_explicit_schema_version(factory):
    payload = export_deletions(factory).model_dump(mode="json")
    payload.pop("schema_version")
    with pytest.raises(DeletionArchiveError):
        load_archive_bytes(json.dumps(payload).encode())


def test_extra_visible_child_refuses_entire_batch_without_first_child_half_delete(deleted, factory):
    restore_rows(factory, deleted.backup)
    with factory.begin() as db:
        db.add(
            PracticeSession(
                user_id=UUID(deleted.owner),
                creation_key=uuid4(),
                request_digest="a" * 64,
                mode="free_chat",
                kind="rehearsal",
                status="cancelled",
                configuration={},
                source_session_id=UUID(deleted.sid),
                source_kind="ordinary",
                source_review_item_id=uuid4(),
                rehearsal_target={},
                rehearsal_target_hash="a" * 64,
            )
        )
    before = rows(factory)
    with pytest.raises(DeletionArchiveError) as error:
        apply(factory, deleted.archive)
    assert error.value.code == "restore_scope_conflict"
    assert rows(factory) == before


def test_existing_receipt_conflict_refuses_whole_batch(deleted, factory):
    with factory.begin() as db:
        db.execute(text("UPDATE practice_deletion_receipts SET scope_version=repeat('b',64)"))
    before = rows(factory)
    with pytest.raises(DeletionArchiveError):
        apply(factory, deleted.archive)
    assert rows(factory) == before


def test_schema_with_multiple_heads_is_not_accepted(factory):
    with factory.begin() as db:
        db.execute(text("INSERT INTO alembic_version(version_num) VALUES ('unexpected_branch')"))
    try:
        with pytest.raises(DeletionArchiveError):
            export_deletions(factory)
    finally:
        with factory.begin() as db:
            db.execute(text("DELETE FROM alembic_version WHERE version_num='unexpected_branch'"))


def test_final_newline_cannot_make_written_file_exceed_its_read_limit(
    tmp_path, deleted, monkeypatch
):
    from simontalk_api import deletion_archive

    body = canonical(deleted.archive.model_dump(mode="json")).encode()
    monkeypatch.setattr(deletion_archive, "MAX_ARCHIVE_BYTES", len(body))
    path = tmp_path / "bounded.json"
    with pytest.raises(DeletionArchiveError):
        write_archive(path, deleted.archive)
    assert not path.exists()


def test_wrong_owner_and_mutated_parsed_lists_are_rechecked(deleted, factory):
    restore_rows(factory, deleted.backup)
    before = rows(factory)
    wrong = str(uuid4())

    def replace_owner(j):
        for receipt in j["receipts"]:
            receipt["account_id"] = wrong

    archive = load_archive_bytes(encoded(deleted.archive, replace_owner))
    with pytest.raises(DeletionArchiveError):
        apply(factory, archive)
    assert rows(factory) == before
    changed = load_archive_bytes(encoded(deleted.archive))
    changed.receipts.clear()
    with pytest.raises(DeletionArchiveError):
        apply(factory, changed)
    assert rows(factory) == before
