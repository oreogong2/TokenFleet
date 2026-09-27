"""Existing-member device codes with a separate, reissue-only credential."""
from datetime import timedelta
import re
import secrets
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import Field, field_validator
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .api import _create_enrollment_token
from .dependencies import bearer, get_current_user, get_session
from .models import EnrollmentManagementCredential, Organization, User, UserRole, utcnow
from .schemas import EnrollmentTokenCreate, EnrollmentTokenResponse, StrictModel, validate_public_nickname
from .security import opaque_token_hash, require_admin

router = APIRouter()


class CredentialCreate(StrictModel):
    expires_in_days: Annotated[int, Field(strict=True, ge=1, le=90)] = 90


class MemberReissue(StrictModel):
    display_name: Annotated[str, Field(min_length=1, max_length=128)]

    @field_validator("display_name")
    @classmethod
    def valid_nickname(cls, value: str) -> str:
        return validate_public_nickname(value)


def reissue_owner(credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
                  session: Session = Depends(get_session)) -> User:
    token = credentials.credentials if credentials and credentials.scheme.lower() == "bearer" else ""
    if not re.fullmatch(r"tfreissue_[A-Za-z0-9_-]{43}", token):
        raise HTTPException(401, "reissue credential required")
    row = session.scalar(select(EnrollmentManagementCredential).where(
        EnrollmentManagementCredential.token_hash == opaque_token_hash(token),
        EnrollmentManagementCredential.is_active.is_(True),
        EnrollmentManagementCredential.expires_at > utcnow()))
    owner = session.scalar(select(User).where(User.id == row.created_by_user_id,
        User.org_id == row.org_id)) if row else None
    if owner is None or not owner.is_active or owner.role != UserRole.ADMIN:
        raise HTTPException(401, "invalid or expired reissue credential")
    return owner


@router.post("/api/v1/enrollment-management/credentials", status_code=201)
def issue_credential(payload: CredentialCreate, response: Response,
                     admin: User = Depends(get_current_user), session: Session = Depends(get_session)) -> dict:
    require_admin(admin)
    session.scalar(select(Organization).where(Organization.id == admin.org_id).with_for_update())
    count = session.scalar(select(func.count()).select_from(EnrollmentManagementCredential).where(
        EnrollmentManagementCredential.org_id == admin.org_id,
        EnrollmentManagementCredential.is_active.is_(True),
        EnrollmentManagementCredential.expires_at > utcnow())) or 0
    if count >= 20:
        raise HTTPException(409, "revoke an existing reissue credential first")
    token = "tfreissue_" + secrets.token_urlsafe(32)
    row = EnrollmentManagementCredential(org_id=admin.org_id, created_by_user_id=admin.id,
        token_hash=opaque_token_hash(token), expires_at=utcnow() + timedelta(days=payload.expires_in_days))
    session.add(row)
    session.commit()
    response.headers["Cache-Control"] = "no-store"
    return {"id": row.id, "credential": token, "expires_at": row.expires_at, "scope": "members:reissue-only"}


@router.delete("/api/v1/enrollment-management/credentials/{credential_id}", status_code=204)
def revoke_credential(credential_id: UUID, admin: User = Depends(get_current_user),
                      session: Session = Depends(get_session)) -> Response:
    require_admin(admin)
    row = session.scalar(select(EnrollmentManagementCredential).where(
        EnrollmentManagementCredential.id == str(credential_id),
        EnrollmentManagementCredential.org_id == admin.org_id))
    if row is None:
        raise HTTPException(404, "reissue credential not found")
    row.is_active = False
    session.commit()
    return Response(status_code=204, headers={"Cache-Control": "no-store"})


@router.post("/api/v1/enrollment-management/reissue", response_model=EnrollmentTokenResponse, status_code=201)
def reissue(payload: MemberReissue, response: Response, owner: User = Depends(reissue_owner),
            session: Session = Depends(get_session)) -> EnrollmentTokenResponse:
    # Exact nickname only: this credential cannot search/list members, choose an
    # organization, create identities, change profiles, or mint other credentials.
    member = session.scalar(select(User).where(User.org_id == owner.org_id,
        User.display_name == payload.display_name, User.role == UserRole.MEMBER,
        User.is_active.is_(True)))
    if member is None:
        raise HTTPException(404, "active member not found")
    result = _create_enrollment_token(EnrollmentTokenCreate(user_id=UUID(member.id)), owner, session)
    response.headers["Cache-Control"] = "no-store"
    return result
