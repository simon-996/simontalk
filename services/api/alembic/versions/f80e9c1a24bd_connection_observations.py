"""Append bounded client observations without changing connection state."""

import sqlalchemy as sa

from alembic import op

revision = "f80e9c1a24bd"
down_revision = "e19bd728ca41"
branch_labels = None
depends_on = None


def upgrade():
    op.create_unique_constraint(
        "connection_observation_identity",
        "realtime_connections",
        ["id", "client_instance_id", "epoch"],
    )
    op.create_table(
        "connection_observations",
        sa.Column("connection_id", sa.Uuid(), nullable=False),
        sa.Column("event_id", sa.Uuid(), nullable=False),
        sa.Column("client_instance_id", sa.Uuid(), nullable=False),
        sa.Column("epoch", sa.Integer(), nullable=False),
        sa.Column("sequence", sa.Integer(), nullable=False),
        sa.Column("code", sa.String(32), nullable=False),
        sa.Column("elapsed_ms", sa.Integer(), nullable=False),
        sa.Column("reason", sa.String(32), nullable=True),
        sa.Column("event_digest", sa.String(64), nullable=False),
        sa.Column("source", sa.String(16), server_default="client_observed", nullable=False),
        sa.Column(
            "received_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.PrimaryKeyConstraint("connection_id", "event_id"),
        sa.ForeignKeyConstraint(
            ["connection_id", "client_instance_id", "epoch"],
            [
                "realtime_connections.id",
                "realtime_connections.client_instance_id",
                "realtime_connections.epoch",
            ],
            name="observation_connection_identity",
            ondelete="CASCADE",
        ),
        sa.UniqueConstraint("connection_id", "sequence", name="observation_sequence"),
        sa.CheckConstraint(
            "sequence > 0 AND elapsed_ms BETWEEN 0 AND 86400000", name="observation_numeric_bounds"
        ),
        sa.CheckConstraint("source = 'client_observed'", name="observation_source"),
        sa.CheckConstraint("event_digest ~ '^[a-f0-9]{64}$'", name="observation_digest"),
        sa.CheckConstraint(
            "code IN ('requesting_microphone','negotiating','transport_connected',"
            "'configuration_confirmed','microphone_active','playback_waiting','playback_blocked',"
            "'playback_playing','playback_paused','muted','unmuted','local_closed')",
            name="observation_code",
        ),
        sa.CheckConstraint(
            "reason IS NULL OR (code = 'local_closed' AND reason IN "
            "('user_stop','background','disposed','account_changed','lease_expired',"
            "'connection_failed','configuration_failed','other'))",
            name="observation_reason",
        ),
    )


def downgrade():
    op.drop_table("connection_observations")
    op.drop_constraint("connection_observation_identity", "realtime_connections", type_="unique")
