"""Database session verification for a future browser WebSocket; no route or I/O."""

from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import func, select

from simontalk_api.models import AuthSession, User
from simontalk_api.security import now
from simontalk_api.websocket_handshake import HandshakeError, HandshakeIdentity


@dataclass(frozen=True, slots=True)
class LockedWebSocketIdentity:
    user_id: UUID
    auth_id: UUID


def lock_websocket_identity(db, identity):
    """Validate and lock owner then auth row within the caller's transaction.

    The caller must complete its own connection ownership/claim checks before
    committing. Lock release does not prevent later revocation or expiry.
    """
    if type(identity) is not HandshakeIdentity:
        raise HandshakeError("handshake_rejected")
    auth_id = db.scalar(
        select(AuthSession.id)
        .join(User, User.id == AuthSession.user_id)
        .where(
            User.id == identity.account_id,
            User.disabled_at.is_(None),
            AuthSession.token_digest == identity.session_digest,
            AuthSession.platform == "web",
            AuthSession.revoked_at.is_(None),
            AuthSession.expires_at > now(),
        )
    )
    if auth_id is None:
        raise HandshakeError("handshake_rejected")
    user_id = db.scalar(
        select(User.id)
        .where(User.id == identity.account_id, User.disabled_at.is_(None))
        .with_for_update()
    )
    if user_id is None:
        raise HandshakeError("handshake_rejected")
    verified_auth_id = db.scalar(
        select(AuthSession.id)
        .where(
            AuthSession.id == auth_id,
            AuthSession.user_id == user_id,
            AuthSession.token_digest == identity.session_digest,
            AuthSession.platform == "web",
            AuthSession.revoked_at.is_(None),
            AuthSession.expires_at > now(),
        )
        .with_for_update()
    )
    if verified_auth_id is None:
        raise HandshakeError("handshake_rejected")
    # A row lock can wait past the session's expiry. Recheck after it has
    # actually been acquired, with the database's current wall clock.
    still_valid = db.scalar(
        select(AuthSession.id).where(
            AuthSession.id == verified_auth_id,
            AuthSession.revoked_at.is_(None),
            AuthSession.expires_at > func.clock_timestamp(),
        )
    )
    if still_valid is None:
        raise HandshakeError("handshake_rejected")
    return LockedWebSocketIdentity(user_id, verified_auth_id)
