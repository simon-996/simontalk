"""Persist single-use signalling intent without retaining SDP."""

import sqlalchemy as sa

from alembic import op

revision = "e19bd728ca41"
down_revision = "c43a7de028f1"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("realtime_connections", sa.Column("offer_digest", sa.String(64), nullable=True))
    op.add_column(
        "realtime_connections",
        sa.Column("signalling_started_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "realtime_connections",
        sa.Column("signalling_finished_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_check_constraint(
        "signalling_intent_evidence",
        "realtime_connections",
        "(offer_digest IS NULL) = (signalling_started_at IS NULL) AND "
        "(offer_digest IS NULL OR offer_digest ~ '^[a-f0-9]{64}$') AND "
        "(signalling_finished_at IS NULL OR (signalling_started_at IS NOT NULL "
        "AND signalling_finished_at >= signalling_started_at))",
    )
    op.create_check_constraint(
        "signalling_termination_evidence",
        "realtime_connections",
        "offer_digest IS NULL OR termination_status <> 'not_started'",
    )


def downgrade():
    op.drop_constraint("signalling_termination_evidence", "realtime_connections", type_="check")
    op.drop_constraint("signalling_intent_evidence", "realtime_connections", type_="check")
    op.drop_column("realtime_connections", "signalling_finished_at")
    op.drop_column("realtime_connections", "signalling_started_at")
    op.drop_column("realtime_connections", "offer_digest")
