"""Add owner-bound first-level rehearsals without changing existing records."""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision = "1a6de74c9f20"
down_revision = "8b2731f5ca90"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "practice_sessions",
        sa.Column("kind", sa.String(16), nullable=False, server_default="ordinary"),
    )
    for name in ("source_session_id", "source_review_item_id"):
        op.add_column("practice_sessions", sa.Column(name, sa.Uuid(), nullable=True))
    op.add_column("practice_sessions", sa.Column("source_kind", sa.String(16), nullable=True))
    op.add_column(
        "practice_sessions",
        sa.Column("rehearsal_target", postgresql.JSONB(none_as_null=True), nullable=True),
    )
    op.add_column(
        "practice_sessions", sa.Column("rehearsal_target_hash", sa.String(64), nullable=True)
    )
    op.create_unique_constraint(
        "practice_id_owner_kind", "practice_sessions", ["id", "user_id", "kind"]
    )
    op.create_foreign_key(
        "practice_rehearsal_source",
        "practice_sessions",
        "practice_sessions",
        ["source_session_id", "user_id", "source_kind"],
        ["id", "user_id", "kind"],
        ondelete="CASCADE",
    )
    op.create_check_constraint(
        "practice_rehearsal_shape",
        "practice_sessions",
        "(kind = 'ordinary' AND source_session_id IS NULL AND source_kind IS NULL "
        "AND source_review_item_id IS NULL AND rehearsal_target IS NULL "
        "AND rehearsal_target_hash IS NULL) OR "
        "(kind = 'rehearsal' AND source_session_id IS NOT NULL "
        "AND source_kind IS NOT NULL AND source_kind = 'ordinary' "
        "AND source_session_id <> id AND source_review_item_id IS NOT NULL "
        "AND rehearsal_target IS NOT NULL AND jsonb_typeof(rehearsal_target) = 'object' "
        "AND rehearsal_target_hash IS NOT NULL AND rehearsal_target_hash ~ '^[a-f0-9]{64}$')",
    )

    op.create_index(
        "rehearsal_parent_seek",
        "practice_sessions",
        ["source_session_id", "user_id", "created_at", "id"],
        postgresql_where=sa.text("kind = 'rehearsal'"),
    )


def downgrade():
    if op.get_bind().scalar(
        sa.text("SELECT EXISTS (SELECT 1 FROM practice_sessions WHERE kind='rehearsal')")
    ):
        raise RuntimeError(
            "Cannot downgrade while rehearsal records exist; preserve their source and targets"
        )
    op.drop_index("rehearsal_parent_seek", table_name="practice_sessions", if_exists=True)
    op.drop_constraint("practice_rehearsal_shape", "practice_sessions", type_="check")
    op.drop_constraint("practice_rehearsal_source", "practice_sessions", type_="foreignkey")
    op.drop_constraint("practice_id_owner_kind", "practice_sessions", type_="unique")
    for name in (
        "rehearsal_target_hash",
        "rehearsal_target",
        "source_review_item_id",
        "source_kind",
        "source_session_id",
        "kind",
    ):
        op.drop_column("practice_sessions", name)
