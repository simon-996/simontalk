"""Bind translation requests to a specific final turn revision."""

import sqlalchemy as sa

from alembic import op

revision = "19d7a3ec0b51"
down_revision = "7cfa81b28360"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("assistance_jobs", sa.Column("source_turn_id", sa.Uuid()))
    op.add_column("assistance_jobs", sa.Column("source_turn_revision", sa.Integer()))
    op.create_check_constraint(
        "assistance_selection",
        "assistance_jobs",
        "(kind = 'english_starter' AND source_turn_id IS NULL AND source_turn_revision IS NULL)"
        " OR (kind = 'translation' AND source_turn_id IS NOT NULL "
        "AND source_turn_revision IS NOT NULL AND source_turn_revision > 0)",
    )
    op.create_index("assistance_action_job", "assistance_actions", ["job_id"])


def downgrade():
    db = op.get_bind()
    db.execute(sa.text("LOCK TABLE assistance_jobs IN ACCESS EXCLUSIVE MODE"))
    if db.scalar(sa.text("SELECT EXISTS(SELECT 1 FROM assistance_jobs WHERE kind='translation')")):
        raise RuntimeError("Refusing to discard recorded translation requests")
    op.drop_index("assistance_action_job", table_name="assistance_actions")
    op.drop_constraint("assistance_selection", "assistance_jobs", type_="check")
    op.drop_column("assistance_jobs", "source_turn_revision")
    op.drop_column("assistance_jobs", "source_turn_id")
