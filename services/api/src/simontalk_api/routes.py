from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from simontalk_api.db import database_session
from simontalk_api.errors import APIError
from simontalk_api.models import AuthSession, Invite, PasswordResetGrant, User, UserPreferences
from simontalk_api.rate_limit import rate_limit
from simontalk_api.schemas import (
    LoginInput,
    PreferencesOutput,
    PreferencesPatch,
    RegisterInput,
    ResetInput,
    UserOutput,
)
from simontalk_api.security import (
    CSRF_COOKIE,
    DUMMY_HASH,
    PASSWORD_HASHER,
    SESSION_COOKIE,
    cookie_options,
    create_session,
    digest,
    new_token,
    now,
    protect_mutation,
    session_identity,
    set_session_cookie,
    verify_password,
)

router = APIRouter(prefix="/v1")


def auth_output(user, token, platform, response, settings):
    result = {"user": UserOutput.model_validate(user).model_dump(mode="json")}
    if platform == "web":
        set_session_cookie(response, token, settings)
    else:
        result["access_token"] = token
    return result


@router.get("/auth/csrf")
def csrf(request: Request, response: Response):
    rate_limit(request, "csrf")
    token = new_token()
    response.set_cookie(CSRF_COOKIE, token, **cookie_options(request.app.state.settings))
    return {"csrf_token": token}


@router.post("/auth/register", status_code=201)
def register(
    payload: RegisterInput,
    request: Request,
    response: Response,
    db: Session = Depends(database_session),
):
    protect_mutation(request, payload.platform)
    rate_limit(request, "register", payload.username)
    invite = db.scalar(
        select(Invite)
        .where(
            Invite.token_digest == digest(payload.invite_code.get_secret_value()),
            Invite.consumed_at.is_(None),
            Invite.expires_at > now(),
        )
        .with_for_update()
    )
    if invite is None:
        raise APIError(400, "invite_invalid", "邀请码无效或已过期，请联系维护者。")
    user = User(
        username=payload.username,
        display_name=payload.display_name,
        password_hash=PASSWORD_HASHER.hash(payload.password.get_secret_value()),
    )
    try:
        db.add(user)
        db.flush()
        db.add(UserPreferences(user_id=user.id))
        invite.consumed_at, invite.consumed_by = now(), user.id
        token = create_session(db, user, payload.platform)
        db.commit()
    except IntegrityError:
        db.rollback()
        raise APIError(400, "registration_failed", "无法注册，请检查输入或联系维护者。") from None
    return auth_output(user, token, payload.platform, response, request.app.state.settings)


@router.post("/auth/login")
def login(
    payload: LoginInput,
    request: Request,
    response: Response,
    db: Session = Depends(database_session),
):
    protect_mutation(request, payload.platform)
    rate_limit(request, "login", payload.username)
    user = db.scalar(select(User).where(User.username == payload.username).with_for_update())
    valid = verify_password(
        user.password_hash if user else DUMMY_HASH, payload.password.get_secret_value()
    )
    if not user or not valid or user.disabled_at is not None:
        raise APIError(401, "invalid_credentials", "用户名或密码不正确。")
    if PASSWORD_HASHER.check_needs_rehash(user.password_hash):
        user.password_hash = PASSWORD_HASHER.hash(payload.password.get_secret_value())
    token = create_session(db, user, payload.platform)
    db.commit()
    return auth_output(user, token, payload.platform, response, request.app.state.settings)


@router.post("/auth/logout", status_code=204)
def logout(request: Request, response: Response, db: Session = Depends(database_session)):
    protect_mutation(request)
    identity = session_identity(request, db, optional=True)
    if identity:
        identity[0].revoked_at = now()
        db.commit()
    response.delete_cookie(SESSION_COOKIE, **cookie_options(request.app.state.settings))


@router.post("/auth/password-reset/confirm", status_code=204)
def reset_password(payload: ResetInput, request: Request, db: Session = Depends(database_session)):
    protect_mutation(request)
    token_digest = digest(payload.reset_token.get_secret_value())
    rate_limit(request, "reset")
    grant = db.scalar(
        select(PasswordResetGrant).where(PasswordResetGrant.token_digest == token_digest)
    )
    invalid = APIError(400, "reset_invalid", "重设凭证无效或已过期，请联系维护者。")
    if grant is None:
        raise invalid
    rate_limit(request, "reset", str(grant.user_id), include_ip=False)
    # Lock the user before any grant: simultaneous grants for this account serialize safely.
    user = db.scalar(select(User).where(User.id == grant.user_id).with_for_update())
    db.refresh(grant)
    if user.disabled_at is not None or grant.consumed_at is not None or grant.expires_at <= now():
        raise invalid
    timestamp = now()
    user.password_hash = PASSWORD_HASHER.hash(payload.new_password.get_secret_value())
    db.execute(
        update(AuthSession)
        .where(
            AuthSession.user_id == user.id,
            AuthSession.revoked_at.is_(None),
        )
        .values(revoked_at=timestamp)
    )
    db.execute(
        update(PasswordResetGrant)
        .where(
            PasswordResetGrant.user_id == user.id,
            PasswordResetGrant.consumed_at.is_(None),
        )
        .values(consumed_at=timestamp)
    )
    db.commit()


@router.get("/me", response_model=UserOutput)
def me(request: Request, db: Session = Depends(database_session)):
    return session_identity(request, db)[1]


@router.get("/me/preferences", response_model=PreferencesOutput)
def preferences(request: Request, db: Session = Depends(database_session)):
    user = session_identity(request, db)[1]
    return db.get(UserPreferences, user.id)


@router.patch("/me/preferences", response_model=PreferencesOutput)
def update_preferences(
    payload: PreferencesPatch,
    request: Request,
    db: Session = Depends(database_session),
):
    protect_mutation(request)
    user = session_identity(request, db)[1]
    values = payload.model_dump(exclude_unset=True, exclude={"version"})
    result = db.scalar(
        update(UserPreferences)
        .where(
            UserPreferences.user_id == user.id,
            UserPreferences.version == payload.version,
        )
        .values(**values, version=UserPreferences.version + 1)
        .returning(UserPreferences)
    )
    if result is None:
        raise APIError(409, "preferences_conflict", "偏好已在其他页面更改，请重新加载后核对。")
    db.commit()
    return result
