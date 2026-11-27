"""Persist no-content provider usage against the original WebSocket claim."""

from dataclasses import asdict

from sqlalchemy import literal, select, text
from sqlalchemy.dialects.postgresql import insert

from simontalk_api.models import RealtimeConnection, VoiceResponseUsage


def record_response_usage(session_factory, claim, measurement):
    connection = RealtimeConnection
    table = VoiceResponseUsage.__table__
    values = asdict(measurement)
    original_connection = select(
        connection.id,
        *(literal(value, type_=table.c[name].type) for name, value in values.items()),
    ).where(
        connection.id == claim.connection_id,
        connection.user_id == claim.user_id,
        connection.session_id == claim.session_id,
        connection.client_instance_id == claim.client_instance_id,
        connection.epoch == claim.epoch,
        connection.offer_digest == claim.fingerprint,
        connection.configuration == dict(claim.configuration),
        connection.signalling_finished_at.is_not(None),
    )
    statement = (
        insert(table)
        .from_select(["connection_id", *values], original_connection)
        .on_conflict_do_nothing(index_elements=[table.c.connection_id, table.c.response_digest])
        .returning(table.c.connection_id)
    )
    with session_factory() as db:
        db.execute(text("SET LOCAL lock_timeout = '750ms'"))
        db.execute(text("SET LOCAL statement_timeout = '2s'"))
        written = db.scalar(statement) is not None
        db.commit()
    return written
