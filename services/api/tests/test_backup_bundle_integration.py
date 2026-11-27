"""Production SQL/CLI composition; real pg tools are explicitly opt-in for restore tests."""

import json
from pathlib import Path

import pytest
from sqlalchemy import text
from test_backup_bundle import make_bundle, tool
from test_deletion_archive import deleted as deleted
from test_deletion_archive_cli import configure
from test_rehearsal_targets import rows
from test_rehearsal_targets import target_source as target_source
from test_saved_transcripts import scope as scope

from simontalk_api import cli
from simontalk_api.backup_bundle import BackupError, check_backup, create_backup
from simontalk_api.deletion_archive import DeletionArchiveError, export_deletions_in_snapshot


def test_create_and_check_are_read_only_with_private_ready_files(factory, tmp_path):
    before = rows(factory)
    path = tmp_path / "backup"
    result = create_backup(
        factory,
        path,
        pg_dump=tool(tmp_path, "import sys;sys.stdout.buffer.write(b'PGDMPsynthetic')"),
    )
    assert result["created"] and result["integrity_verified"] and not result["restore_verified"]
    assert check_backup(path)["manifest_hash"] == result["manifest_hash"]
    with factory() as db:
        revision = db.scalar(text("SELECT version_num FROM alembic_version"))
    assert json.loads((path / "manifest.json").read_text())["schema_revision"] == revision
    assert rows(factory) == before
    assert {p.name for p in path.iterdir()} == {"database.dump", "deletions.json", "manifest.json"}
    assert path.stat().st_mode & 0o777 == 0o700
    assert all(p.stat().st_mode & 0o777 == 0o600 for p in path.iterdir())


def test_current_schema_is_required_and_failure_does_not_leave_ready_directory(factory, tmp_path):
    with factory.begin() as db:
        revision = db.scalar(text("SELECT version_num FROM alembic_version"))
        db.execute(text("UPDATE alembic_version SET version_num='unrecognized'"))
    try:
        with pytest.raises(BackupError):
            create_backup(factory, tmp_path / "backup", pg_dump="/abs/missing")
        assert not (tmp_path / "backup").exists()
    finally:
        with factory.begin() as db:
            db.execute(
                text("UPDATE alembic_version SET version_num=:version"), {"version": revision}
            )


def test_export_session_cannot_silently_read_a_different_snapshot(factory):
    with factory() as db:
        with pytest.raises(DeletionArchiveError):
            export_deletions_in_snapshot(db)


@pytest.mark.parametrize("kind", ["directory", "file", "symlink"])
def test_existing_output_is_never_overwritten(factory, tmp_path, kind):
    path = tmp_path / "backup"
    if kind == "directory":
        path.mkdir()
        (path / "keep").write_text("keep")
    if kind == "file":
        path.write_text("keep")
    if kind == "symlink":
        target = tmp_path / "target"
        target.write_text("keep")
        path.symlink_to(target)
    with pytest.raises(BackupError):
        create_backup(factory, path, pg_dump="/abs/missing")
    assert path.exists()
    if kind == "directory":
        assert (path / "keep").read_text() == "keep"
    else:
        assert path.read_text() == "keep"


def test_missing_tool_removes_owned_files_but_not_an_external_addition(
    factory, tmp_path, monkeypatch
):
    import simontalk_api.backup_bundle as module

    def fail(*args):
        (tmp_path / "backup" / "keep").write_text("external")
        raise BackupError("backup_tool_failed")

    monkeypatch.setattr(module, "_dump", fail)
    with pytest.raises(BackupError):
        create_backup(factory, tmp_path / "backup", pg_dump="/abs/missing")
    assert [p.name for p in (tmp_path / "backup").iterdir()] == ["keep"]


def test_cli_create_output_and_existing_error_are_sanitized(factory, tmp_path, monkeypatch, capsys):
    path = tmp_path / "backup"
    executable = tool(tmp_path, "import sys;sys.stdout.buffer.write(b'PGDMPsynthetic')")
    configure(
        monkeypatch, factory, ["backup-create", "--output", str(path), "--pg-dump", executable]
    )
    cli.main()
    result = json.loads(capsys.readouterr().out)
    assert result["created"] and not result["restore_verified"]
    with pytest.raises(SystemExit) as caught:
        cli.main()
    assert caught.value.code == 1
    output = capsys.readouterr()
    assert output.out == "" and str(path) not in output.err and "postgresql" not in output.err


def test_offline_cli_never_loads_settings_or_creates_a_database(tmp_path, monkeypatch, capsys):
    path = tmp_path / "backup"
    make_bundle(path)

    def forbidden(*args, **kwargs):
        raise AssertionError("Offline check connected")

    monkeypatch.setattr(cli, "Settings", forbidden)
    monkeypatch.setattr(cli, "create_database", forbidden)
    monkeypatch.setattr("sys.argv", ["simontalk-admin", "backup-check", "--input", str(path)])
    cli.main()
    assert json.loads(capsys.readouterr().out)["integrity_verified"] is True


@pytest.fixture
def pg_tools():
    import os

    dump = os.environ.get("SIMONTALK_BACKUP_TEST_PG_DUMP")
    restore = os.environ.get("SIMONTALK_BACKUP_TEST_PG_RESTORE")
    if not dump or not restore:
        if os.environ.get("SIMONTALK_REQUIRE_REAL_BACKUP_TESTS") == "1":
            pytest.fail("Required real restore tools are not configured")
        pytest.skip("Real restore requires explicitly configured PostgreSQL test tools")
    assert Path(dump).is_absolute() and Path(restore).is_absolute()
    return dump, restore


@pytest.fixture
def restored_factory(factory):
    import subprocess
    from contextlib import contextmanager
    from uuid import uuid4

    from sqlalchemy import create_engine

    from simontalk_api.backup_bundle import _postgres_environment
    from simontalk_api.db import create_database

    @contextmanager
    def restore_bundle(bundle, executable):
        url = factory.kw["bind"].url
        name = "simontalk_backup_restore_" + uuid4().hex[:12] + "_test"
        admin = create_engine(url.set(database="postgres"), isolation_level="AUTOCOMMIT")
        engine = None
        with admin.connect() as db:
            assert (
                db.scalar(text("SELECT count(*) FROM pg_database WHERE datname=:n"), {"n": name})
                == 0
            )
            db.execute(text(f'CREATE DATABASE "{name}"'))
        try:
            with (bundle / "database.dump").open("rb") as source:
                result = subprocess.run(
                    [executable, "--exit-on-error", "--no-owner", "--no-acl", f"--dbname={name}"],
                    stdin=source,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    env=_postgres_environment(url),
                    timeout=30,
                )
            assert result.returncode == 0
            engine, target = create_database(url.set(database=name))
            yield target, name
        finally:
            if engine is not None:
                engine.dispose()
            with admin.connect() as db:
                assert (
                    db.scalar(
                        text("SELECT count(*) FROM pg_stat_activity WHERE datname=:n"), {"n": name}
                    )
                    == 0
                )
                db.execute(text(f'DROP DATABASE "{name}"'))
            admin.dispose()

    return restore_bundle


def test_actual_pg_dump_and_restore_preserve_all_rows(
    factory, deleted, tmp_path, pg_tools, restored_factory
):
    before = rows(factory)
    path = tmp_path / "real-backup"
    result = create_backup(factory, path, pg_dump=pg_tools[0])
    assert result["receipt_count"] == 2 and result["member_count"] == 3
    with restored_factory(path, pg_tools[1]) as (target, _):
        assert rows(target) == before
    assert rows(factory) == before


def test_concurrent_delete_is_outside_exported_snapshot_and_latest_replay_is_required(
    client, factory, target_source, tmp_path, pg_tools, restored_factory, monkeypatch
):
    from uuid import UUID

    from test_practice_deletion import erase, snapshot

    from simontalk_api import backup_bundle as module
    from simontalk_api.deletion_archive import export_deletions, read_archive
    from simontalk_api.deletion_restore import replay_deletions
    from simontalk_api.models import RealtimeConnection, VoiceResponseUsage

    source = target_source
    with factory.begin() as db:
        c = db.get(RealtimeConnection, UUID(source.connection["id"]))
        c.status, c.termination_status, c.ended_at = "unknown", "unknown", None
        c.offer_digest, c.signalling_started_at = "a" * 64, c.created_at
        db.add(
            VoiceResponseUsage(
                connection_id=c.id, response_digest="b" * 64, status="completed", input_tokens=37
            )
        )
    before = rows(factory)
    original = module._dump

    def delete_then_dump(*args):
        h, sid = source.scope.headers, source.scope.session["id"]
        assert erase(client, sid, h, snapshot(client, sid, h)).status_code == 200
        return original(*args)

    monkeypatch.setattr(module, "_dump", delete_then_dump)
    path = tmp_path / "real-backup"
    create_backup(factory, path, pg_dump=pg_tools[0])
    assert read_archive(path / "deletions.json").receipts == []
    latest = export_deletions(factory)
    assert len(latest.receipts) == 1
    with restored_factory(path, pg_tools[1]) as (target, name):
        assert rows(target) == before
        result = replay_deletions(target, latest, apply=True, confirm_database=name)
        assert result["applied"] is True
        with target() as db:
            for table in ["final_transcripts", "review_inputs", "review_jobs", "review_results"]:
                assert db.scalar(text(f"SELECT count(*) FROM {table}")) == 0
            c = db.get(RealtimeConnection, UUID(source.connection["id"]))
            assert c.status == "unknown" and c.termination_status == "unknown"
            usage = db.get(VoiceResponseUsage, (c.id, "b" * 64))
            assert usage.input_tokens == 37 and usage.output_tokens is None
        replayed = rows(target)
        replay_deletions(target, latest, apply=True, confirm_database=name)
        assert rows(target) == replayed
