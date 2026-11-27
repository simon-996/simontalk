"""Preflight and atomic replay against a stopped, restored database."""

from sqlalchemy import or_, select, text, tuple_

from simontalk_api.deletion_archive import (
    DeletionArchiveError,
    check_archive_schema,
    load_archive_bytes,
)
from simontalk_api.models import PracticeDeletionReceipt, PracticeSession, User
from simontalk_api.practice_completion import canonical
from simontalk_api.practice_deletion import purge_practice_content


def _chunks(values, size=400):
    for i in range(0, len(values), size):
        yield values[i : i + size]


def _receipt_values(entry):
    return {
        "user_id": entry.account_id,
        "members": [m.model_dump(mode="json") for m in entry.members],
        **{
            name: getattr(entry, name)
            for name in (
                "session_id",
                "request_key",
                "scope_version",
                "record_count",
                "rehearsal_count",
                "connection_pending",
                "deleted_at",
            )
        },
    }


def replay_deletions(factory, archive, *, apply=False, confirm_database=None):
    # Revalidate mutable lists even if the caller supplied a previously parsed model.
    archive = load_archive_bytes(canonical(archive.model_dump(mode="json")).encode())
    with factory() as db:
        if apply and confirm_database != db.get_bind().url.database:
            raise DeletionArchiveError("restore_database_confirmation_required")
        db.execute(text("SET LOCAL transaction_timeout = '30s'"))
        db.execute(text("SET LOCAL statement_timeout = '5s'"))
        db.execute(text("SET LOCAL lock_timeout = '1s'"))
        revision = check_archive_schema(db)
        owners = sorted({r.account_id for r in archive.receipts})
        present_owners = {
            owner
            for owner in owners
            if db.scalar(select(User.id).where(User.id == owner).with_for_update()) is not None
        }
        ids = sorted({m.id for r in archive.receipts for m in r.members})
        ordinary = {
            r.session_id
            for r in archive.receipts
            if next(m for m in r.members if m.id == r.session_id).kind == "ordinary"
        }
        existing = {}
        for chunk in _chunks(ids):
            query = (
                select(PracticeSession)
                .where(
                    or_(
                        PracticeSession.id.in_(chunk),
                        PracticeSession.source_session_id.in_(ordinary.intersection(chunk)),
                    )
                )
                .order_by(PracticeSession.id)
                .with_for_update()
                .execution_options(populate_existing=True)
            )
            existing.update({r.id: r for r in db.scalars(query)})
        keys = [(r.account_id, r.request_key) for r in archive.receipts]
        receipts = {}
        for chunk in _chunks(keys):
            receipts.update(
                {
                    (r.user_id, r.request_key): r
                    for r in db.scalars(
                        select(PracticeDeletionReceipt)
                        .where(
                            tuple_(
                                PracticeDeletionReceipt.user_id, PracticeDeletionReceipt.request_key
                            ).in_(chunk)
                        )
                        .with_for_update()
                    )
                }
            )
        virtual_deleted = {r.id for r in existing.values() if r.deleted_at is not None}
        plans, present, newly_hidden = [], 0, 0
        for entry in archive.receipts:
            known = {m.id for m in entry.members}
            members = []
            for member in entry.members:
                row = existing.get(member.id)
                if row is None:
                    continue
                if (
                    row.user_id != entry.account_id
                    or row.kind != member.kind
                    or row.source_session_id != member.parent
                    or row.deleted_at is not None
                    and row.deleted_at != entry.deleted_at
                ):
                    raise DeletionArchiveError("restore_member_conflict")
                members.append(row)
            if entry.session_id in ordinary and any(
                row.source_session_id == entry.session_id
                and row.id not in virtual_deleted
                and row.id not in known
                for row in existing.values()
            ):
                raise DeletionArchiveError("restore_scope_conflict")
            previous = receipts.get((entry.account_id, entry.request_key))
            values = _receipt_values(entry)
            if previous is not None and any(
                getattr(previous, name) != value for name, value in values.items()
            ):
                raise DeletionArchiveError("restore_receipt_conflict")
            present += len(members)
            newly_hidden += sum(row.deleted_at is None for row in members)
            virtual_deleted.update(known)
            plans.append((entry, members, previous))
        result = {
            "applied": bool(apply),
            "archive_hash": archive.content_hash,
            "receipt_count": len(archive.receipts),
            "member_count": len(ids),
            "present_records": present,
            "newly_hidden_records": newly_hidden,
            "missing_records": len(ids) - present,
            "missing_accounts": len(owners) - len(present_owners),
        }
        if not apply:
            db.rollback()
            return result
        for entry, members, previous in plans:
            if members:
                purge_practice_content(
                    db,
                    entry.account_id,
                    members,
                    entry.deleted_at,
                    has_assistance=revision in {"7cfa81b28360", "19d7a3ec0b51"},
                )
            if previous is None:
                db.add(PracticeDeletionReceipt(**_receipt_values(entry)))
        db.commit()
        return result
