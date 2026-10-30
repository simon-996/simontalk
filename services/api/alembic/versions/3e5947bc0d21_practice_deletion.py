"""Delete content while retaining safety tombstones and request receipts."""

import sqlalchemy as sa

from alembic import op

revision = "3e5947bc0d21"
down_revision = "2d4836ab9c10"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("practice_sessions", sa.Column("deleted_at", sa.DateTime(timezone=True)))
    op.create_table(
        "practice_deletion_receipts",
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
        ),
        sa.Column("request_key", sa.Uuid(), primary_key=True),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("scope_version", sa.String(64), nullable=False),
        sa.Column("record_count", sa.Integer(), nullable=False),
        sa.Column("rehearsal_count", sa.Integer(), nullable=False),
        sa.Column("connection_pending", sa.Boolean(), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("scope_version ~ '^[a-f0-9]{64}$'", name="deletion_scope_digest"),
        sa.CheckConstraint(
            "record_count > 0 AND rehearsal_count >= 0 AND rehearsal_count <= record_count",
            name="deletion_counts",
        ),
    )


def downgrade():
    if op.get_bind().scalar(
        sa.text(
            "SELECT EXISTS(SELECT 1 FROM practice_sessions WHERE deleted_at IS NOT NULL) "
            "OR EXISTS(SELECT 1 FROM practice_deletion_receipts)"
        )
    ):
        raise RuntimeError(
            "Refusing to remove deletion visibility and receipts from a nonempty database"
        )
    op.drop_table("practice_deletion_receipts")
    op.drop_column("practice_sessions", "deleted_at")
