"""Private deletion snapshots, independent of the older database being restored."""

import json
import os
import tempfile
from datetime import UTC
from pathlib import Path
from typing import Literal, get_args
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator
from sqlalchemy import select, text

from simontalk_api.models import PracticeDeletionReceipt, PracticeSession
from simontalk_api.practice_completion import canonical
from simontalk_api.practice_deletion import _version
from simontalk_api.security import digest, now

MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
MAX_ARCHIVE_RECEIPTS = 100_000
MAX_ARCHIVE_MEMBERS = 1_000_000
ArchiveSchemaRevision = Literal[
    "4f6a58cd2e32", "56bd3c921ab4", "329ce39bc5a2", "7cfa81b28360", "19d7a3ec0b51"
]
_SUPPORTED_SCHEMA_REVISIONS = frozenset(get_args(ArchiveSchemaRevision))


class DeletionArchiveError(ValueError):
    def __init__(self, code="deletion_archive_invalid"):
        self.code = code
        super().__init__(code)


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class ArchiveMember(_Strict):
    id: UUID
    kind: Literal["ordinary", "rehearsal"]
    parent: UUID | None

    @property
    def source_session_id(self):
        return self.parent

    @model_validator(mode="after")
    def relationship(self):
        if (self.kind == "ordinary") != (self.parent is None) or self.parent == self.id:
            raise ValueError("Invalid relationship")
        return self


class ArchiveReceipt(_Strict):
    account_id: UUID
    session_id: UUID
    request_key: UUID
    scope_version: str = Field(pattern=r"^[a-f0-9]{64}$")
    record_count: int = Field(strict=True, ge=1, le=MAX_ARCHIVE_MEMBERS)
    rehearsal_count: int = Field(strict=True, ge=0, le=MAX_ARCHIVE_MEMBERS)
    connection_pending: bool = Field(strict=True)
    deleted_at: AwareDatetime
    members: list[ArchiveMember] = Field(min_length=1, max_length=MAX_ARCHIVE_MEMBERS)

    @field_validator("deleted_at")
    @classmethod
    def utc(cls, value):
        return value.astimezone(UTC)

    @model_validator(mode="after")
    def membership(self):
        ids = [m.id for m in self.members]
        root = next((m for m in self.members if m.id == self.session_id), None)
        if (
            ids != sorted(set(ids))
            or root is None
            or len(ids) != self.record_count
            or sum(m.kind == "rehearsal" for m in self.members) != self.rehearsal_count
            or _version(self.session_id, self.members) != self.scope_version
        ):
            raise ValueError("Invalid deletion scope")
        if root.kind == "rehearsal":
            if len(ids) != 1:
                raise ValueError("Rehearsals cannot have descendants")
        elif any(
            m.id != root.id and (m.kind != "rehearsal" or m.parent != root.id) for m in self.members
        ):
            raise ValueError("Invalid first-level scope")
        return self


class DeletionArchive(_Strict):
    schema_version: Literal["deletion_archive_v1"]
    exported_at: AwareDatetime
    receipts: list[ArchiveReceipt] = Field(max_length=MAX_ARCHIVE_RECEIPTS)
    content_hash: str = Field(pattern=r"^[a-f0-9]{64}$")

    @field_validator("exported_at")
    @classmethod
    def utc(cls, value):
        return value.astimezone(UTC)

    @model_validator(mode="after")
    def complete(self):
        ordering = [(r.deleted_at, r.session_id, r.request_key) for r in self.receipts]
        keys = [(r.account_id, r.request_key) for r in self.receipts]
        ids = [m.id for r in self.receipts for m in r.members]
        if (
            ordering != sorted(ordering)
            or len(keys) != len(set(keys))
            or len(ids) > MAX_ARCHIVE_MEMBERS
            or len(ids) != len(set(ids))
            or any(r.deleted_at > self.exported_at for r in self.receipts)
            or digest(canonical(self.model_dump(mode="json", exclude={"content_hash"})))
            != self.content_hash
        ):
            raise ValueError("Incomplete or damaged deletion archive")
        return self


def check_archive_schema(db):
    revisions = db.scalars(text("SELECT version_num FROM alembic_version")).all()
    if len(revisions) != 1 or revisions[0] not in _SUPPORTED_SCHEMA_REVISIONS:
        raise DeletionArchiveError("deletion_archive_schema_mismatch")
    return revisions[0]


def export_deletions(factory):
    with factory() as db:
        db.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"))
        return export_deletions_in_snapshot(db)


def export_deletions_in_snapshot(db):
    if (
        db.scalar(text("SHOW transaction_isolation")) != "repeatable read"
        or db.scalar(text("SHOW transaction_read_only")) != "on"
    ):
        raise DeletionArchiveError("deletion_archive_snapshot_required")
    check_archive_schema(db)
    receipts = list(
        db.scalars(
            select(PracticeDeletionReceipt)
            .order_by(
                PracticeDeletionReceipt.deleted_at,
                PracticeDeletionReceipt.session_id,
                PracticeDeletionReceipt.request_key,
            )
            .limit(MAX_ARCHIVE_RECEIPTS + 1)
        )
    )
    if len(receipts) > MAX_ARCHIVE_RECEIPTS:
        raise DeletionArchiveError("deletion_archive_limit")
    entries = []
    for receipt in receipts:
        entries.append(
            {
                "account_id": str(receipt.user_id),
                **{
                    k: getattr(receipt, k)
                    for k in (
                        "session_id",
                        "request_key",
                        "scope_version",
                        "record_count",
                        "rehearsal_count",
                        "connection_pending",
                        "deleted_at",
                    )
                },
                "members": receipt.members,
            }
        )
    try:
        parsed = [ArchiveReceipt.model_validate(e).model_dump(mode="json") for e in entries]
        payload = {
            "schema_version": "deletion_archive_v1",
            "exported_at": now().isoformat().replace("+00:00", "Z"),
            "receipts": parsed,
        }
        archive = DeletionArchive.model_validate(
            {**payload, "content_hash": digest(canonical(payload))}
        )
    except (ValueError, TypeError, OverflowError):
        raise DeletionArchiveError("deletion_archive_incomplete") from None
    covered = {m.id: (r, m) for r in archive.receipts for m in r.members}
    tombstones = set(
        db.scalars(
            select(PracticeSession.id)
            .where(PracticeSession.deleted_at.is_not(None))
            .limit(MAX_ARCHIVE_MEMBERS + 1)
        )
    )
    if not tombstones.issubset(covered):
        raise DeletionArchiveError("deletion_archive_incomplete")
    ids = list(covered)
    for start in range(0, len(ids), 400):
        for row in db.scalars(
            select(PracticeSession).where(PracticeSession.id.in_(ids[start : start + 400]))
        ):
            entry, member = covered[row.id]
            if (
                row.user_id != entry.account_id
                or row.deleted_at != entry.deleted_at
                or row.kind != member.kind
                or row.source_session_id != member.parent
            ):
                raise DeletionArchiveError("deletion_archive_incomplete")
    if len(canonical(archive.model_dump(mode="json")).encode()) > MAX_ARCHIVE_BYTES:
        raise DeletionArchiveError("deletion_archive_limit")
    return archive


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def load_archive_bytes(value):
    if not isinstance(value, bytes) or len(value) > MAX_ARCHIVE_BYTES:
        raise DeletionArchiveError("deletion_archive_limit")
    try:
        return DeletionArchive.model_validate(json.loads(value, object_pairs_hook=_unique_object))
    except (ValueError, TypeError, OverflowError, RecursionError):
        raise DeletionArchiveError() from None


def read_archive(path):
    try:
        with Path(path).open("rb") as stream:
            return load_archive_bytes(stream.read(MAX_ARCHIVE_BYTES + 1))
    except OSError:
        raise DeletionArchiveError("deletion_archive_file_unavailable") from None


def write_archive(path, archive):
    path = Path(path)
    if not path.is_absolute():
        raise DeletionArchiveError("deletion_archive_absolute_path_required")
    verified = load_archive_bytes(canonical(archive.model_dump(mode="json")).encode())
    payload = (canonical(verified.model_dump(mode="json")) + "\n").encode()
    if len(payload) > MAX_ARCHIVE_BYTES:
        raise DeletionArchiveError("deletion_archive_limit")
    temporary, published, complete = None, None, False
    try:
        with tempfile.NamedTemporaryFile(
            dir=path.parent, prefix=".deletions-", delete=False
        ) as stream:
            temporary = Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        # link is atomic and refuses to replace an existing file or symlink.
        os.link(temporary, path)
        info = temporary.stat()
        published = (info.st_dev, info.st_ino)
        temporary.unlink()
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        complete = True
    except OSError:
        raise DeletionArchiveError("deletion_archive_file_unavailable") from None
    finally:
        if not complete and published is not None:
            try:
                info = path.lstat()
                if (info.st_dev, info.st_ino) == published:
                    path.unlink()
            except OSError:
                pass
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return published
