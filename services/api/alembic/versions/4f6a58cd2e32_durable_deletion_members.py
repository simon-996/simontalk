"""Retain complete deletion decisions across restores predating their members."""

import hashlib
import json

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

from alembic import op

revision = "4f6a58cd2e32"
down_revision = "3e5947bc0d21"
branch_labels = None
depends_on = None


def upgrade():
    db = op.get_bind()
    op.add_column("practice_deletion_receipts", sa.Column("members", JSONB()))
    for receipt in db.execute(sa.text("SELECT * FROM practice_deletion_receipts")).mappings():
        members = [
            {
                "id": str(row.id),
                "kind": row.kind,
                "parent": str(row.source_session_id) if row.source_session_id else None,
            }
            for row in db.execute(
                sa.text(
                    "SELECT id,kind,source_session_id FROM practice_sessions "
                    "WHERE user_id=:owner AND deleted_at=:stamp "
                    "AND (id=:target OR source_session_id=:target) ORDER BY id"
                ),
                {
                    "owner": receipt.user_id,
                    "stamp": receipt.deleted_at,
                    "target": receipt.session_id,
                },
            )
        ]
        payload = json.dumps(
            {"target": str(receipt.session_id), "members": members},
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
        )
        if (
            len(members) != receipt.record_count
            or sum(m["kind"] == "rehearsal" for m in members) != receipt.rehearsal_count
            or hashlib.sha256(payload.encode()).hexdigest() != receipt.scope_version
        ):
            raise RuntimeError("Cannot reconstruct complete deletion membership; migration refused")
        db.execute(
            sa.text(
                "UPDATE practice_deletion_receipts SET members=CAST(:members AS jsonb) "
                "WHERE user_id=:owner AND request_key=:key"
            ),
            {"members": json.dumps(members), "owner": receipt.user_id, "key": receipt.request_key},
        )
    op.alter_column("practice_deletion_receipts", "members", nullable=False)
    op.create_check_constraint(
        "deletion_member_count",
        "practice_deletion_receipts",
        "jsonb_typeof(members) = 'array' AND jsonb_array_length(members) = record_count",
    )
    for foreign_key in sa.inspect(db).get_foreign_keys("practice_deletion_receipts"):
        if foreign_key["constrained_columns"] == ["user_id"]:
            op.drop_constraint(
                foreign_key["name"], "practice_deletion_receipts", type_="foreignkey"
            )


def downgrade():
    if op.get_bind().scalar(sa.text("SELECT EXISTS(SELECT 1 FROM practice_deletion_receipts)")):
        raise RuntimeError(
            "Refusing to discard complete deletion decisions from a nonempty database"
        )
    op.create_foreign_key(
        "practice_deletion_receipts_user_id_fkey",
        "practice_deletion_receipts",
        "users",
        ["user_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.drop_constraint("deletion_member_count", "practice_deletion_receipts", type_="check")
    op.drop_column("practice_deletion_receipts", "members")
