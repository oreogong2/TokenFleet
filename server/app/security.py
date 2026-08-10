from __future__ import annotations

import base64
import hashlib
import hmac
import re
import secrets
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import HTTPException, Request, status
from jwt import InvalidTokenError
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .config import Settings
from .models import Device, DeviceNonce, Organization, User, UserRole, utcnow

SIGNING_KEY_PREFIX = b"TokenFleet-HMAC-v1:\n"
LOGIN_DUMMY_SALT = b"TokenFleetLogin!"
LOGIN_DUMMY_DIGEST = bytes(32)
NONCE_PATTERN = re.compile(r"^[A-Za-z0-9._~-]{16,128}$")
SIGNATURE_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def hash_password(password: str, iterations: int) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return "pbkdf2_sha256${}${}${}".format(
        iterations,
        base64.urlsafe_b64encode(salt).decode("ascii"),
        base64.urlsafe_b64encode(digest).decode("ascii"),
    )


def verify_password(password: str, encoded: str) -> bool:
    try:
        algorithm, iteration_text, salt_text, digest_text = encoded.split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        salt = base64.urlsafe_b64decode(salt_text.encode("ascii"))
        expected = base64.urlsafe_b64decode(digest_text.encode("ascii"))
        candidate = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), salt, int(iteration_text)
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(candidate, expected)


def login_dummy_password_hash(iterations: int) -> str:
    """Return a syntactically valid non-user hash for constant-work login checks.

    The fixed all-zero digest is intentionally not the hash of a known password.
    ``verify_password`` still performs the configured PBKDF2 work when an account
    lookup misses, while constructing this placeholder is constant-time and cheap.
    """

    return "pbkdf2_sha256${}${}${}".format(
        iterations,
        base64.urlsafe_b64encode(LOGIN_DUMMY_SALT).decode("ascii"),
        base64.urlsafe_b64encode(LOGIN_DUMMY_DIGEST).decode("ascii"),
    )


def create_access_token(user: User, settings: Settings) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user.id,
        "org": user.org_id,
        "role": user.role.value,
        "iss": settings.jwt_issuer,
        "aud": settings.jwt_audience,
        "iat": now,
        "exp": now + timedelta(seconds=settings.jwt_ttl_seconds),
        "jti": secrets.token_hex(16),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256")


def decode_access_token(token: str, settings: Settings) -> dict[str, object]:
    try:
        return jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=["HS256"],
            issuer=settings.jwt_issuer,
            audience=settings.jwt_audience,
            options={
                "require": ["sub", "org", "role", "iss", "aud", "iat", "exp", "jti"]
            },
        )
    except InvalidTokenError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid or expired access token",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc


def generate_enrollment_token() -> str:
    return secrets.token_urlsafe(32)


def opaque_token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def generate_device_secret() -> str:
    return secrets.token_urlsafe(32)


def derive_device_signing_key(device_secret: str) -> bytes:
    return hashlib.sha256(SIGNING_KEY_PREFIX + device_secret.encode("utf-8")).digest()


def body_sha256(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def canonical_request(
    *, timestamp_text: str, nonce: str, method: str, path: str, body: bytes
) -> bytes:
    return (
        f"{timestamp_text}\n{nonce}\n{method.upper()}\n{path}\n{body_sha256(body)}"
    ).encode("utf-8")


def sign_device_request(
    *,
    device_secret: str,
    timestamp_text: str,
    nonce: str,
    method: str,
    path: str,
    body: bytes,
) -> str:
    signing_key = derive_device_signing_key(device_secret)
    canonical = canonical_request(
        timestamp_text=timestamp_text,
        nonce=nonce,
        method=method,
        path=path,
        body=body,
    )
    return hmac.new(signing_key, canonical, hashlib.sha256).hexdigest()


@dataclass(frozen=True, slots=True)
class DevicePrincipal:
    device: Device
    user: User


async def authenticate_device_request(
    request: Request,
    session: Session,
    settings: Settings,
) -> DevicePrincipal:
    device_id = request.headers.get("X-Device-ID")
    timestamp_text = request.headers.get("X-Timestamp")
    nonce = request.headers.get("X-Nonce")
    signature = request.headers.get("X-Signature")
    if not all((device_id, timestamp_text, nonce, signature)):
        raise HTTPException(status_code=401, detail="missing device authentication headers")
    assert timestamp_text is not None and nonce is not None and signature is not None
    if request.url.query:
        raise HTTPException(status_code=400, detail="signed usage requests cannot contain a query string")
    content_encoding = request.headers.get("Content-Encoding")
    if content_encoding and content_encoding.lower() != "identity":
        raise HTTPException(status_code=400, detail="content encoding is not supported")
    if any(
        len(value) > 256
        for value in (device_id or "", timestamp_text, nonce, signature)
    ):
        raise HTTPException(status_code=401, detail="device authentication header is too long")
    content_length = request.headers.get("Content-Length")
    if content_length:
        try:
            if int(content_length) > 2 * 1024 * 1024:
                raise HTTPException(status_code=413, detail="request body exceeds two MiB")
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="invalid content length") from exc
    if not NONCE_PATTERN.fullmatch(nonce):
        raise HTTPException(status_code=401, detail="invalid nonce")
    if not SIGNATURE_PATTERN.fullmatch(signature):
        raise HTTPException(status_code=401, detail="invalid signature encoding")
    try:
        request_timestamp = int(timestamp_text)
    except ValueError as exc:
        raise HTTPException(status_code=401, detail="invalid timestamp") from exc
    if abs(int(time.time()) - request_timestamp) > settings.hmac_max_clock_skew_seconds:
        raise HTTPException(status_code=401, detail="request timestamp is outside the allowed window")

    device = session.scalar(select(Device).where(Device.id == device_id))
    if device is None:
        raise HTTPException(status_code=401, detail="unknown device")
    user = session.scalar(
        select(User).where(User.id == device.user_id, User.org_id == device.org_id)
    )
    if not device.is_active or user is None or not user.is_active:
        raise HTTPException(status_code=403, detail="device or member is disabled")

    body = await request.body()
    if len(body) > 2 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="request body exceeds two MiB")
    expected = hmac.new(
        bytes.fromhex(device.signing_key),
        canonical_request(
            timestamp_text=timestamp_text,
            nonce=nonce,
            method=request.method,
            path=request.url.path,
            body=body,
        ),
        hashlib.sha256,
    ).hexdigest()
    if not hmac.compare_digest(expected, signature):
        raise HTTPException(status_code=401, detail="invalid request signature")

    # PostgreSQL serializes all authenticated usage requests in an organization
    # before applying the shared device/organization sliding-window limits. The
    # fixed organization -> device lock order is also used by ledger ingestion.
    # SQLite ignores FOR UPDATE but still retains the same transactional contract
    # for local/single-process development.
    organization = session.scalar(
        select(Organization)
        .where(Organization.id == device.org_id)
        .with_for_update()
    )
    locked_device = session.scalar(
        select(Device)
        .where(Device.id == device.id, Device.org_id == device.org_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if organization is None or locked_device is None:
        session.rollback()
        raise HTTPException(status_code=401, detail="unknown device")

    # Re-check against the locked row so a concurrent re-enrollment cannot make
    # a request signed with the superseded credential succeed after key rotation.
    locked_expected = hmac.new(
        bytes.fromhex(locked_device.signing_key),
        canonical_request(
            timestamp_text=timestamp_text,
            nonce=nonce,
            method=request.method,
            path=request.url.path,
            body=body,
        ),
        hashlib.sha256,
    ).hexdigest()
    if not hmac.compare_digest(locked_expected, signature):
        session.rollback()
        raise HTTPException(status_code=401, detail="invalid request signature")
    if not locked_device.is_active:
        session.rollback()
        raise HTTPException(status_code=403, detail="device or member is disabled")

    now = utcnow()
    rate_cutoff = now - timedelta(
        seconds=settings.usage_rate_limit_window_seconds
    )
    device_attempts = session.scalar(
        select(func.count())
        .select_from(DeviceNonce)
        .where(
            DeviceNonce.device_id == locked_device.id,
            DeviceNonce.created_at > rate_cutoff,
        )
    ) or 0
    organization_attempts = session.scalar(
        select(func.count())
        .select_from(DeviceNonce)
        .join(Device, Device.id == DeviceNonce.device_id)
        .where(
            Device.org_id == locked_device.org_id,
            DeviceNonce.created_at > rate_cutoff,
        )
    ) or 0
    if (
        device_attempts >= settings.usage_rate_limit_device_attempts
        or organization_attempts >= settings.usage_rate_limit_org_attempts
    ):
        session.rollback()
        raise HTTPException(
            status_code=429,
            detail="too many usage upload attempts",
            headers={
                "Retry-After": str(settings.usage_rate_limit_window_seconds)
            },
        )

    # Authentication success consumes the nonce even if payload validation later
    # fails. Committing here prevents a later endpoint rollback from reopening it.
    # Cleanup is organization-scoped to avoid cross-tenant lock contention.
    retention_cutoff = now - timedelta(seconds=settings.nonce_retention_seconds)
    organization_device_ids = select(Device.id).where(
        Device.org_id == locked_device.org_id
    )
    session.execute(
        delete(DeviceNonce).where(
            DeviceNonce.created_at < retention_cutoff,
            DeviceNonce.device_id.in_(organization_device_ids),
        )
    )
    session.add(
        DeviceNonce(
            device_id=locked_device.id,
            nonce=nonce,
            request_timestamp=request_timestamp,
        )
    )
    locked_device.last_seen_at = now
    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(status_code=409, detail="request nonce has already been used") from exc
    return DevicePrincipal(device=locked_device, user=user)


def require_admin(user: User) -> None:
    if user.role != UserRole.ADMIN:
        raise HTTPException(status_code=403, detail="administrator role required")
