"""Offline bundle integrity and bounded subprocesses; synthetic dumps are not restores."""

import hashlib
import importlib
import importlib.util
import json
import os
import stat
import sys

import pytest
from sqlalchemy.engine import make_url

from simontalk_api.deletion_archive import load_archive_bytes
from simontalk_api.practice_completion import canonical
from simontalk_api.security import digest


def test_backup_bundle_module_exists():
    assert importlib.util.find_spec("simontalk_api.backup_bundle") is not None, (
        "Backup bundle missing"
    )


@pytest.fixture
def module():
    return importlib.import_module("simontalk_api.backup_bundle")


def make_bundle(folder):
    folder.mkdir(mode=0o700)
    payload = {
        "schema_version": "deletion_archive_v1",
        "exported_at": "2026-10-25T00:00:00Z",
        "receipts": [],
    }
    archive = load_archive_bytes(
        canonical({**payload, "content_hash": digest(canonical(payload))}).encode()
    )
    files = {
        "database.dump": b"PGDMPsynthetic-not-restorable",
        "deletions.json": canonical(archive.model_dump(mode="json")).encode(),
    }
    manifest = {
        "schema_version": "backup_bundle_v1",
        "created_at": "2026-10-25T00:00:00Z",
        "schema_revision": "4f6a58cd2e32",
        "postgres_version": 170000,
        "source_database": "test",
        "deletion_archive_hash": archive.content_hash,
        "files": {
            name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            for name, data in files.items()
        },
    }
    for name, data in files.items():
        (folder / name).write_bytes(data)
        (folder / name).chmod(0o600)
    save_manifest(folder, manifest)
    return manifest


def save_manifest(folder, manifest):
    p = folder / "manifest.json"
    p.write_text(json.dumps(manifest))
    p.chmod(0o600)


def test_offline_integrity_does_not_claim_restore_or_latest_deletions(module, tmp_path):
    folder = tmp_path / "bundle"
    make_bundle(folder)
    before = {p.name: p.read_bytes() for p in folder.iterdir()}
    result = module.check_backup(folder)
    assert result["integrity_verified"] is True
    assert result["restore_verified"] is False and result["latest_deletions_verified"] is False
    assert result["receipt_count"] == 0 and result["member_count"] == 0
    assert before == {p.name: p.read_bytes() for p in folder.iterdir()}


@pytest.mark.parametrize(
    "change",
    [
        lambda m: m.update(extra="private"),
        lambda m: m.update(schema_version="future"),
        lambda m: m.update(schema_revision="old"),
        lambda m: m.update(postgres_version=True),
        lambda m: m.update(source_database="postgresql://private"),
        lambda m: m.update(created_at=123),
        lambda m: m["files"].pop("database.dump"),
        lambda m: m["files"].update({"../escape": m["files"]["database.dump"]}),
        lambda m: m["files"]["database.dump"].update(bytes=True),
        lambda m: m["files"]["database.dump"].update(sha256="a" * 64),
        lambda m: m.update(deletion_archive_hash="a" * 64),
    ],
)
def test_invalid_manifest_refuses_without_echo(module, tmp_path, change):
    folder = tmp_path / "bundle"
    manifest = make_bundle(folder)
    change(manifest)
    save_manifest(folder, manifest)
    with pytest.raises(module.BackupError) as caught:
        module.check_backup(folder)
    assert "private" not in str(caught.value) and str(folder) not in str(caught.value)
    assert caught.value.__context__ is None


@pytest.mark.parametrize(
    "kind",
    [
        "duplicate",
        "nan",
        "huge",
        "missing",
        "extra",
        "permissions",
        "dir_permissions",
        "symlink",
        "dir_symlink",
        "header",
        "corrupt_deletions",
    ],
)
def test_local_files_fail_closed(module, tmp_path, kind):
    folder = tmp_path / "bundle"
    manifest = make_bundle(folder)
    path = folder / "manifest.json"
    if kind == "duplicate":
        path.write_text('{"schema_version":"backup_bundle_v1","schema_version":"backup_bundle_v1"}')
    if kind == "nan":
        path.write_text('{"value":NaN}')
    if kind == "huge":
        path.write_bytes(b"x" * 65537)
    if kind == "missing":
        path.unlink()
    if kind == "extra":
        (folder / "unknown").write_text("private")
    if kind == "permissions":
        path.chmod(0o644)
    if kind == "dir_permissions":
        folder.chmod(0o755)
    if kind == "symlink":
        other = tmp_path / "real"
        path.rename(other)
        path.symlink_to(other)
    if kind == "dir_symlink":
        other = tmp_path / "real"
        folder.rename(other)
        folder.symlink_to(other, target_is_directory=True)
    if kind in {"header", "corrupt_deletions"}:
        name = "database.dump" if kind == "header" else "deletions.json"
        data = b"INVALID-DUMP" if kind == "header" else b'{"private":"untrusted"}'
        (folder / name).write_bytes(data)
        manifest["files"][name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        save_manifest(folder, manifest)
    with pytest.raises(module.BackupError):
        module.check_backup(folder)


def test_relative_bundle_path_is_rejected(module):
    with pytest.raises(module.BackupError):
        module.check_backup("relative")


def tool(tmp_path, code):
    path = tmp_path / "pg_dump"
    path.write_text(f"#!{sys.executable}\n" + code)
    path.chmod(0o700)
    return str(path)


def test_tool_uses_no_shell_or_password_in_argv_and_private_output(module, tmp_path):
    executable = tool(
        tmp_path,
        "import os,sys\n"
        "assert os.environ['PGPASSWORD']=='secret-test'\n"
        "assert 'secret-test' not in repr(sys.argv)\n"
        "assert '--snapshot=00000001-00000001-1' in sys.argv\n"
        "assert os.environ.get('PGSERVICE') is None\n"
        "sys.stdout.buffer.write(b'PGDMPtest')\n",
    )
    url = make_url("postgresql+psycopg://test:secret-test@127.0.0.1:54329/test")
    path = tmp_path / "output"
    module._dump(executable, path, "00000001-00000001-1", module._postgres_environment(url), 2)
    assert path.read_bytes() == b"PGDMPtest"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


@pytest.mark.parametrize(
    "code",
    [
        "import sys;sys.stderr.write('secret-test private');sys.exit(1)",
        "import sys;sys.stderr.write('warning: private');sys.stdout.buffer.write(b'PGDMPtest')",
        "import time;time.sleep(10)",
        "import sys;sys.stdout.buffer.write(b'PGDMP'+b'x'*1000)",
    ],
)
def test_process_failure_is_bounded_closed_and_sanitized(module, tmp_path, monkeypatch, code):
    monkeypatch.setattr(module, "_MAX_DUMP_BYTES", 64)
    processes = []
    original = module.subprocess.Popen

    def track(*args, **kwargs):
        p = original(*args, **kwargs)
        processes.append(p)
        return p

    monkeypatch.setattr(module.subprocess, "Popen", track)
    path = tmp_path / "output"
    with pytest.raises(module.BackupError) as caught:
        module._dump(
            tool(tmp_path, code),
            path,
            "00000001-00000001-1",
            module._postgres_environment(make_url("postgresql+psycopg://test:test@127.0.0.1/test")),
            0.08,
        )
    assert not path.exists()
    assert processes[0].poll() is not None
    assert processes[0].stdout.closed and processes[0].stderr.closed
    assert "private" not in str(caught.value) and "secret-test" not in str(caught.value)
    assert caught.value.__context__ is None


@pytest.mark.parametrize(
    "url",
    [
        "postgresql+psycopg://u:p@localhost/db?options=private",
        "postgresql+psycopg://u:p@localhost/postgresql%3A%2F%2Fprivate",
        "sqlite:///test",
    ],
)
def test_unsupported_connection_options_are_not_silently_ignored(module, url):
    with pytest.raises(module.BackupError):
        module._postgres_environment(make_url(url))


def test_parent_pg_environment_cannot_redirect_backup(module, monkeypatch):
    monkeypatch.setenv("PGSERVICE", "private")
    monkeypatch.setenv("PGOPTIONS", "private")
    env = module._postgres_environment(
        make_url(
            "postgresql+psycopg://test:secret-test@localhost:54329/test?sslmode=verify-full&sslrootcert=/explicit/root"
        )
    )
    assert env["PGSSLMODE"] == "verify-full" and env["PGSSLROOTCERT"] == "/explicit/root"
    assert "PGSERVICE" not in env and "PGOPTIONS" not in env and env["PGPASSFILE"] == os.devnull


def test_partial_manifest_write_failure_removes_its_own_file(module, tmp_path, monkeypatch):
    path = tmp_path / "manifest.json"

    def fail(_):
        raise OSError("private path")

    monkeypatch.setattr(module.os, "fsync", fail)
    with pytest.raises(OSError):
        module._write(path, b"partial")
    assert not path.exists()


def test_kill_race_still_removes_failed_dump(module, tmp_path, monkeypatch):
    original = module.os.killpg

    def killed_already(pid, sig):
        original(pid, sig)
        raise ProcessLookupError("already exited")

    monkeypatch.setattr(module.os, "killpg", killed_already)
    path = tmp_path / "output"
    with pytest.raises(module.BackupError):
        module._dump(
            tool(tmp_path, "import time;time.sleep(10)"),
            path,
            "00000001-00000001-1",
            module._postgres_environment(make_url("postgresql+psycopg://test:test@127.0.0.1/test")),
            0.08,
        )
    assert not path.exists()


def test_archive_publication_sync_failure_does_not_leave_an_untracked_file(
    module, tmp_path, monkeypatch
):
    from simontalk_api import deletion_archive

    folder = tmp_path / "source"
    make_bundle(folder)
    archive = load_archive_bytes((folder / "deletions.json").read_bytes())
    target = tmp_path / "deletions.json"
    original = deletion_archive.os.fsync

    def fail_directory(fd):
        if stat.S_ISDIR(os.fstat(fd).st_mode):
            raise OSError("directory sync failure")
        original(fd)

    monkeypatch.setattr(deletion_archive.os, "fsync", fail_directory)
    with pytest.raises(deletion_archive.DeletionArchiveError):
        deletion_archive.write_archive(target, archive)
    assert not target.exists()


@pytest.mark.parametrize("kind", ["write", "dump"])
def test_failed_cleanup_preserves_an_external_replacement(module, tmp_path, monkeypatch, kind):
    path = tmp_path / "output"
    old = tmp_path / "renamed-original"

    def replace_then_fail(_):
        path.rename(old)
        path.write_bytes(b"external-replacement")
        raise OSError("sync failure")

    monkeypatch.setattr(module.os, "fsync", replace_then_fail)
    if kind == "write":
        with pytest.raises(OSError):
            module._write(path, b"original")
    else:
        with pytest.raises(module.BackupError):
            module._dump(
                tool(tmp_path, "import sys;sys.stdout.buffer.write(b'PGDMPtest')"),
                path,
                "00000001-00000001-1",
                module._postgres_environment(
                    make_url("postgresql+psycopg://test:test@localhost/test")
                ),
                2,
            )
    assert path.exists() and path.read_bytes() == b"external-replacement"
    assert old.exists()


@pytest.mark.skipif(not hasattr(os, "fork"), reason="POSIX process groups required")
def test_exited_leader_does_not_leave_a_child_process(module, tmp_path):
    import signal
    import time

    marker = tmp_path / "child-ran"
    pidfile = tmp_path / "pid"
    code = (
        "import os,time\nfrom pathlib import Path\n"
        "if os.fork()==0:\n"
        f" Path({str(pidfile)!r}).write_text(str(os.getpid()))\n"
        " time.sleep(.3)\n"
        f' Path({str(marker)!r}).write_text("alive")\n'
        " time.sleep(5)\n"
        "os._exit(0)\n"
    )
    try:
        with pytest.raises(module.BackupError):
            module._dump(
                tool(tmp_path, code),
                tmp_path / "output",
                "00000001-00000001-1",
                module._postgres_environment(
                    make_url("postgresql+psycopg://test:test@localhost/test")
                ),
                0.1,
            )
        time.sleep(0.4)
        assert not marker.exists()
    finally:
        if pidfile.exists():
            try:
                os.kill(int(pidfile.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass


@pytest.mark.parametrize("name", ["manifest.json", "database.dump", "deletions.json"])
def test_successful_writer_never_claims_an_external_replacement(
    module, tmp_path, monkeypatch, name
):
    from types import SimpleNamespace

    class DB:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def execute(self, query):
            pass

        def scalar(self, query):
            return 170000 if str(query) == "SHOW server_version_num" else "snapshot"

        def scalars(self, query):
            assert str(query) == "SELECT version_num FROM alembic_version"
            return SimpleNamespace(all=lambda: ["4f6a58cd2e32"])

    class Factory:
        kw = {
            "bind": SimpleNamespace(url=make_url("postgresql+psycopg://test:test@localhost/test"))
        }

        def __call__(self):
            return DB()

    source = tmp_path / "source"
    make_bundle(source)
    archive = load_archive_bytes((source / "deletions.json").read_bytes())
    monkeypatch.setattr(module, "export_deletions_in_snapshot", lambda _: archive)
    folder, old = tmp_path / "bundle", tmp_path / "original"
    target = folder / name
    original_sync, replaced = module.os.fsync, []

    def replace_but_succeed(fd):
        info = os.fstat(fd)
        matches = target.exists() and (
            stat.S_ISDIR(info.st_mode)
            if name == "deletions.json"
            else info.st_ino == target.stat().st_ino
        )
        if matches and not replaced:
            target.rename(old)
            target.write_bytes(b"external-replacement")
            target.chmod(0o600)
            replaced.append(True)
        original_sync(fd)

    monkeypatch.setattr(module.os, "fsync", replace_but_succeed)
    with pytest.raises(module.BackupError):
        module.create_backup(
            Factory(),
            folder,
            pg_dump=tool(tmp_path, "import sys;sys.stdout.buffer.write(b'PGDMPtest')"),
        )
    assert replaced and target.read_bytes() == b"external-replacement"
    assert old.exists()
