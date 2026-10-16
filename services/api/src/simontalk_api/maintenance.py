from datetime import timedelta

from sqlalchemy import select, update

from simontalk_api.models import AuthSession, Invite, PasswordResetGrant, User
from simontalk_api.security import digest, new_token, now


def issue_invite(db):
    token = new_token()
    db.add(Invite(token_digest=digest(token), expires_at=now() + timedelta(hours=72)))
    return token


def issue_reset(db, username: str):
    user = db.scalar(
        select(User)
        .where(
            User.username == username.lower(),
            User.disabled_at.is_(None),
        )
        .with_for_update()
    )
    if user is None:
        raise ValueError("Account unavailable")
    token = new_token()
    db.add(
        PasswordResetGrant(
            user_id=user.id,
            token_digest=digest(token),
            expires_at=now() + timedelta(minutes=15),
        )
    )
    return token


def disable_user(db, username: str):
    user = db.scalar(select(User).where(User.username == username.lower()).with_for_update())
    if user is None:
        raise ValueError("Account unavailable")
    timestamp = now()
    user.disabled_at = timestamp
    db.execute(
        update(AuthSession)
        .where(
            AuthSession.user_id == user.id,
            AuthSession.revoked_at.is_(None),
        )
        .values(revoked_at=timestamp)
    )
