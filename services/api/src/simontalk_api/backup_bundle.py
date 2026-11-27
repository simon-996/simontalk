"""Private manual backups; integrity checks do not certify restore or deletion freshness."""

import hashlib
import json
import os
import re
import selectors
import signal
import stat
import subprocess
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import text

from simontalk_api.deletion_archive import (
    MAX_ARCHIVE_BYTES,
    ArchiveSchemaRevision,
    check_archive_schema,
    export_deletions_in_snapshot,
    load_archive_bytes,
    write_archive,
)
from simontalk_api.practice_completion import canonical

_MAX_DUMP_BYTES = 512 * 1024 * 1024
_FILES = {"database.dump", "deletions.json", "manifest.json"}
_DATABASE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]{0,62}", re.ASCII)
_SSL = {
    "sslmode": "PGSSLMODE",
    "sslrootcert": "PGSSLROOTCERT",
    "sslcert": "PGSSLCERT",
    "sslkey": "PGSSLKEY",
    "channel_binding": "PGCHANNELBINDING",
}


class BackupError(ValueError):
    def __init__(self, code="backup_invalid"):
        self.code = code
        super().__init__(code)


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class _File(_Strict):
    bytes: int = Field(strict=True, ge=1, le=_MAX_DUMP_BYTES)
    sha256: str = Field(strict=True, pattern=r"^[a-f0-9]{64}$")


class _Manifest(_Strict):
    schema_version: Literal["backup_bundle_v1"]
    created_at: AwareDatetime
    schema_revision: ArchiveSchemaRevision
    postgres_version: int = Field(strict=True, ge=170000, lt=180000)
    source_database: str = Field(strict=True, pattern=r"^[A-Za-z0-9_][A-Za-z0-9_-]{0,62}$")
    deletion_archive_hash: str = Field(strict=True, pattern=r"^[a-f0-9]{64}$")
    files: dict[Literal["database.dump", "deletions.json"], _File]

    @field_validator("created_at", mode="before")
    @classmethod
    def timestamp(cls, value):
        if type(value) is not str:
            raise ValueError("Invalid time")
        return value


def _public(action):
    code = "backup_failed"
    try:
        return action()
    except BackupError as error:
        code = error.code
    except Exception:
        pass
    # No private paths, DB parameters or subprocess exception context escapes.
    raise BackupError(code)


def _private(info, directory=False):
    if (
        (not stat.S_ISDIR(info.st_mode) if directory else not stat.S_ISREG(info.st_mode))
        or info.st_mode & 0o077
        or info.st_uid != os.getuid()
    ):
        raise BackupError("backup_private_file_required")


def _directory(path):
    path = Path(path)
    if not path.is_absolute():
        raise BackupError("backup_absolute_path_required")
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        _private(os.fstat(fd), directory=True)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _file(directory, name, limit, *, contents=False):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    try:
        before = os.fstat(fd)
        _private(before)
        if not 1 <= before.st_size <= limit:
            raise BackupError("backup_file_limit")
        hasher, size, parts, header = hashlib.sha256(), 0, [], b""
        while chunk := os.read(fd, 65536):
            size += len(chunk)
            if size > limit:
                raise BackupError("backup_file_limit")
            hasher.update(chunk)
            if len(header) < 5:
                header = (header + chunk)[:5]
            if contents:
                parts.append(chunk)
        after = os.fstat(fd)
        if size != before.st_size or (after.st_size, after.st_mtime_ns) != (
            before.st_size,
            before.st_mtime_ns,
        ):
            raise BackupError("backup_file_changed")
        return {"bytes": size, "sha256": hasher.hexdigest()}, b"".join(parts), header
    finally:
        os.close(fd)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise BackupError()
        result[key] = value
    return result


def _bad_constant(_):
    raise BackupError()


def _check(path):
    directory = _directory(path)
    try:
        with os.scandir(directory) as entries:
            if {entry.name for entry in entries} != _FILES:
                raise BackupError("backup_files_mismatch")
        _, data, _ = _file(directory, "manifest.json", 65536, contents=True)
        manifest = _Manifest.model_validate(
            json.loads(data, object_pairs_hook=_pairs, parse_constant=_bad_constant)
        )
        if set(manifest.files) != {"database.dump", "deletions.json"}:
            raise BackupError()
        actual, _, header = _file(directory, "database.dump", _MAX_DUMP_BYTES)
        if actual != manifest.files["database.dump"].model_dump() or header != b"PGDMP":
            raise BackupError("backup_dump_mismatch")
        actual, data, _ = _file(directory, "deletions.json", MAX_ARCHIVE_BYTES, contents=True)
        archive = load_archive_bytes(data)
        if (
            actual != manifest.files["deletions.json"].model_dump()
            or archive.content_hash != manifest.deletion_archive_hash
        ):
            raise BackupError("backup_deletions_mismatch")
        return {
            "integrity_verified": True,
            "restore_verified": False,
            "latest_deletions_verified": False,
            "schema_revision": manifest.schema_revision,
            "manifest_hash": hashlib.sha256(
                canonical(manifest.model_dump(mode="json")).encode()
            ).hexdigest(),
            "dump_bytes": manifest.files["database.dump"].bytes,
            "deletion_archive_hash": archive.content_hash,
            "receipt_count": len(archive.receipts),
            "member_count": sum(len(r.members) for r in archive.receipts),
        }
    finally:
        os.close(directory)


def check_backup(path):
    return _public(lambda: _check(path))


def _postgres_environment(url):
    if (
        url.drivername != "postgresql+psycopg"
        or not url.host
        or any(c in url.host for c in ", \t\r\n")
        or not url.username
        or not url.database
        or _DATABASE.fullmatch(url.database) is None
        or set(url.query) - set(_SSL)
        or any(type(v) is not str for v in url.query.values())
    ):
        raise BackupError("backup_connection_unsupported")
    if url.query.get("sslmode", "prefer") not in {
        "disable",
        "allow",
        "prefer",
        "require",
        "verify-ca",
        "verify-full",
    }:
        raise BackupError("backup_connection_unsupported")
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "LC_ALL": "C",
        "PGHOST": url.host,
        "PGPORT": str(url.port or 5432),
        "PGUSER": url.username,
        "PGPASSWORD": url.password or "",
        "PGDATABASE": url.database,
        "PGCONNECT_TIMEOUT": "3",
        "PGPASSFILE": os.devnull,
        "PGSSLMODE": "prefer",
    }
    env.update({_SSL[k]: v for k, v in url.query.items()})
    if any("\0" in value for value in env.values()):
        raise BackupError("backup_connection_unsupported")
    return env


def _remove_owned(path, identity):
    try:
        info = Path(path).lstat()
        if (info.st_dev, info.st_ino) == identity:
            Path(path).unlink()
    except FileNotFoundError:
        pass


def _dump_impl(executable, path, snapshot, env, timeout):
    process, complete = None, False
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    identity = (info.st_dev, info.st_ino)
    try:
        process = subprocess.Popen(
            [
                executable,
                "--format=custom",
                "--no-owner",
                "--no-acl",
                "--no-password",
                f"--snapshot={snapshot}",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            start_new_session=True,
        )
        deadline = time.monotonic() + timeout
        size, stderr_size = 0, 0
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "out")
            selector.register(process.stderr, selectors.EVENT_READ, "err")
            while selector.get_map():
                left = deadline - time.monotonic()
                if left <= 0:
                    raise BackupError("backup_tool_timeout")
                for key, _ in selector.select(left):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    elif key.data == "err":
                        stderr_size += len(chunk)
                        if stderr_size > 65536:
                            raise BackupError("backup_tool_failed")
                    else:
                        size += len(chunk)
                        if size > _MAX_DUMP_BYTES:
                            raise BackupError("backup_file_limit")
                        view = memoryview(chunk)
                        while view:
                            written = os.write(fd, view)
                            view = view[written:]
        left = deadline - time.monotonic()
        if left <= 0:
            raise BackupError("backup_tool_timeout")
        if process.wait(timeout=left) != 0 or stderr_size or size < 5:
            raise BackupError("backup_tool_failed")
        os.fsync(fd)
        complete = True
    finally:
        try:
            try:
                os.close(fd)
            finally:
                if process is not None:
                    # The leader may have exited while descendants still own the pipes.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=1)
        except BaseException:
            complete = False
            raise
        finally:
            if process is not None:
                process.stdout.close()
                process.stderr.close()
            if not complete:
                _remove_owned(path, identity)
    return identity


def _dump(executable, path, snapshot, env, timeout):
    return _public(lambda: _dump_impl(executable, path, snapshot, env, timeout))


def _write(path, payload):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    identity = (info.st_dev, info.st_ino)
    complete = False
    try:
        with os.fdopen(fd, "wb", closefd=False) as out:
            out.write(payload)
            out.flush()
            os.fsync(fd)
        complete = True
    finally:
        try:
            os.close(fd)
        except BaseException:
            complete = False
            raise
        finally:
            if not complete:
                _remove_owned(path, identity)
    return identity


def _create(factory, path, pg_dump, timeout_seconds):
    path = Path(path)
    if not path.is_absolute():
        raise BackupError("backup_absolute_path_required")
    if type(timeout_seconds) not in {int, float} or not 1 <= timeout_seconds <= 120:
        raise BackupError("backup_timeout_invalid")
    if type(pg_dump) is not str or (pg_dump != "pg_dump" and not Path(pg_dump).is_absolute()):
        raise BackupError("backup_tool_invalid")
    env = _postgres_environment(factory.kw["bind"].url)
    path.mkdir(mode=0o700)
    owned, complete = [], False

    def remember(name, identity):
        owned.append((name, *identity))
        p = path / name
        info = p.lstat()
        if (info.st_dev, info.st_ino) != identity:
            raise BackupError("backup_file_changed")

    try:
        with factory() as db:
            db.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"))
            db.execute(text("SET LOCAL statement_timeout='5s'"))
            db.execute(text("SET LOCAL lock_timeout='2s'"))
            version = int(db.scalar(text("SHOW server_version_num")))
            if not 170000 <= version < 180000:
                raise BackupError("backup_postgres_version_unsupported")
            schema_revision = check_archive_schema(db)
            archive = export_deletions_in_snapshot(db)
            snapshot = db.scalar(text("SELECT pg_export_snapshot()"))
            remember("deletions.json", write_archive(path / "deletions.json", archive))
            remember(
                "database.dump",
                _dump(pg_dump, path / "database.dump", snapshot, env, timeout_seconds),
            )
            directory = _directory(path)
            try:
                files = {
                    name: _file(directory, name, _MAX_DUMP_BYTES)[0]
                    for name in ("database.dump", "deletions.json")
                }
            finally:
                os.close(directory)
            manifest = {
                "schema_version": "backup_bundle_v1",
                "created_at": datetime.now(UTC).isoformat(),
                "schema_revision": schema_revision,
                "postgres_version": version,
                "source_database": env["PGDATABASE"],
                "deletion_archive_hash": archive.content_hash,
                "files": files,
            }
            remember(
                "manifest.json",
                _write(path / "manifest.json", (canonical(manifest) + "\n").encode()),
            )
            directory = _directory(path)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            result = check_backup(path)
        complete = True
        return {**result, "created": True}
    finally:
        if not complete:
            for name, device, inode in reversed(owned):
                try:
                    p = path / name
                    info = p.lstat()
                    if (info.st_dev, info.st_ino) == (device, inode):
                        p.unlink()
                except FileNotFoundError:
                    pass
            try:
                path.rmdir()
            except OSError:
                pass


def create_backup(factory, path, *, pg_dump="pg_dump", timeout_seconds=30):
    return _public(lambda: _create(factory, path, pg_dump, timeout_seconds))
