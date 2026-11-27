"""Support durable topic-guided ordinary practice alongside free chat."""

import sqlalchemy as sa

from alembic import op

revision = "329ce39bc5a2"
down_revision = "56bd3c921ab4"
branch_labels = None
depends_on = None


def upgrade():
    op.drop_constraint("practice_mode", "practice_sessions", type_="check")
    op.create_check_constraint(
        "practice_mode",
        "practice_sessions",
        "(mode = 'free_chat' AND NOT (configuration ? 'topic')) OR "
        "(mode = 'daily_topic' AND kind = 'ordinary' AND "
        "((deleted_at IS NULL AND (jsonb_typeof(configuration -> 'topic') = 'object') IS TRUE) "
        "OR (deleted_at IS NOT NULL AND NOT (configuration ? 'topic'))))",
    )


def downgrade():
    db = op.get_bind()
    db.execute(sa.text("LOCK TABLE practice_sessions IN ACCESS EXCLUSIVE MODE"))
    if db.scalar(
        sa.text("SELECT EXISTS(SELECT 1 FROM practice_sessions WHERE mode='daily_topic')")
    ):
        raise RuntimeError("Refusing to discard recorded practice topics")
    op.drop_constraint("practice_mode", "practice_sessions", type_="check")
    op.create_check_constraint("practice_mode", "practice_sessions", "mode = 'free_chat'")
