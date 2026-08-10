from __future__ import annotations

from collections.abc import Generator

from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import Settings
from .models import User
from .security import DevicePrincipal, authenticate_device_request, decode_access_token

bearer = HTTPBearer(auto_error=False)


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


def get_session(request: Request) -> Generator[Session, None, None]:
    factory = request.app.state.session_factory
    with factory() as session:
        yield session


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> User:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=401,
            detail="bearer access token required",
            headers={"WWW-Authenticate": "Bearer"},
        )
    payload = decode_access_token(credentials.credentials, settings)
    user_id = str(payload["sub"])
    org_id = str(payload["org"])
    user = session.scalar(select(User).where(User.id == user_id, User.org_id == org_id))
    if user is None or not user.is_active:
        raise HTTPException(status_code=401, detail="user is disabled or no longer exists")
    return user


async def get_device_principal(
    request: Request,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> DevicePrincipal:
    return await authenticate_device_request(request, session, settings)
