from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
import hashlib
from ipaddress import ip_address
from typing import Annotated
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from sqlalchemy import delete, func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .config import Settings
from .dependencies import (
    get_current_user,
    get_device_principal,
    get_session,
    get_settings,
)
from .models import (
    DailyUsage,
    CommunityShareGrant,
    Device,
    EnrollmentToken,
    InvitationBatch,
    Organization,
    PriceVersion,
    User,
    UserRole,
    utcnow,
)
from .middleware import trusted_client_ip
from .schemas import (
    DailyUsageIngestResponse,
    DailyUsageReport,
    CommunityShareGrantIssueRequest,
    CommunityShareGrantRedeemRequest,
    CommunityShareGrantRedeemResponse,
    CommunityShareGrantResponse,
    DeviceCommunityRankResponse,
    DeviceEnrollRequest,
    DeviceEnrollResponse,
    DeviceResponse,
    DeviceStatusUpdate,
    EnrollmentTokenCreate,
    EnrollmentTokenResponse,
    HealthResponse,
    InvitationBatchClaim,
    InvitationBatchClaimResponse,
    InvitationBatchCreate,
    InvitationBatchCreateResponse,
    InvitationBatchSummary,
    OrganizationSettingsResponse,
    OrganizationSettingsUpdate,
    ParticipantCreate,
    ParticipantEnrollmentResponse,
    PriceCreate,
    PriceResponse,
    PriceVisibilityUpdate,
    PublicCapabilitiesResponse,
    PublicLeaderboardResponse,
    PublicMemberDetailResponse,
    PublicMetric,
    PublicPeriod,
    TokenRequest,
    TokenResponse,
    UsageDashboardResponse,
    UsageRow,
    UsageTotals,
    UserCreate,
    UserResponse,
    UserStatusUpdate,
    validate_label_characters,
    validate_public_nickname,
)
from .public_projection import (
    build_device_community_rank,
    build_public_capabilities,
    build_public_leaderboard,
    build_public_member_detail,
    period_bounds,
    resolve_public_organization,
)
from .security import (
    DevicePrincipal,
    create_access_token,
    derive_device_signing_key,
    generate_community_share_grant,
    generate_device_secret,
    generate_enrollment_token,
    hash_password,
    login_dummy_password_hash,
    opaque_token_hash,
    require_admin,
    verify_password,
)
from .services import ingest_daily_usage

router = APIRouter()


@router.get("/healthz", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok")


@router.get("/readyz", response_model=HealthResponse)
def readiness(
    session: Session = Depends(get_session),
) -> HealthResponse:
    try:
        # Touch columns introduced by the initial migration so a connection to
        # an empty or materially stale database is never reported as ready.
        session.execute(
            select(
                Organization.id,
                Organization.default_timezone,
                Organization.retention_days,
                Organization.ledger_version,
            ).limit(1)
        )
        # Touch the column introduced by the current Alembic head. Merely
        # checking the initial organization table would let a database that is
        # one migration behind advertise readiness and then fail on usage I/O.
        session.execute(
            select(
                DailyUsage.is_deleted,
                User.public_id,
                User.public_profile_enabled,
                User.normalized_display_name,
                PriceVersion.public_estimate,
                InvitationBatch.claimed_count,
                CommunityShareGrant.expires_at,
            )
            .select_from(DailyUsage)
            .outerjoin(User, User.id == DailyUsage.user_id)
            .outerjoin(PriceVersion, PriceVersion.id == DailyUsage.price_version_id)
            .outerjoin(InvitationBatch, InvitationBatch.org_id == DailyUsage.org_id)
            .outerjoin(CommunityShareGrant, CommunityShareGrant.org_id == DailyUsage.org_id)
            .limit(1)
        )
    except Exception as exc:  # pragma: no cover - backend-specific failure path
        raise HTTPException(status_code=503, detail="database is not ready") from exc
    return HealthResponse(status="ready")


def _client_rate_key(request: Request) -> str:
    trusted_proxy_networks = request.app.state.trusted_proxy_networks
    if trusted_proxy_networks:
        client_host = trusted_client_ip(
            request.scope,
            trusted_proxy_networks=trusted_proxy_networks,
            trusted_proxy_hops=request.app.state.trusted_proxy_hops,
        )
        if client_host is None:
            # A configured proxy boundary with an unparseable/missing chain is
            # hostile input. Reject it instead of either bypassing the limiter
            # or collapsing every unresolved caller into a global DoS bucket.
            raise HTTPException(
                status_code=400,
                detail="invalid client network identity",
            )
    else:
        raw_client = request.scope.get("client")
        if raw_client is None:
            raise HTTPException(
                status_code=400,
                detail="client network identity is unavailable",
            )
        try:
            raw_peer = str(raw_client[0]).strip()
        except (IndexError, TypeError):
            raise HTTPException(
                status_code=400,
                detail="client network identity is unavailable",
            )
        if not raw_peer or len(raw_peer) > 255 or any(
            ord(character) < 0x20 or ord(character) == 0x7F
            for character in raw_peer
        ):
            raise HTTPException(
                status_code=400,
                detail="client network identity is unavailable",
            )
        try:
            client_host = ip_address(raw_peer).compressed
        except ValueError:
            # ASGI test servers and some direct transports expose a bounded,
            # server-supplied peer label instead of an IP. It is not derived
            # from forwarding headers, so it remains a safe local limiter key.
            client_host = "peer:" + raw_peer
    return "ip:" + hashlib.sha256(client_host.encode("utf-8")).hexdigest()


def _consume_public_read_limit(request: Request) -> None:
    limiter_key = _client_rate_key(request)
    retry_after = request.app.state.public_rate_limiter.consume(limiter_key)
    if retry_after is not None:
        raise HTTPException(
            status_code=429,
            detail="too many public leaderboard requests",
            headers={"Retry-After": str(retry_after)},
        )


def _consume_community_share_grant_issue_limit(
    request: Request, principal: DevicePrincipal
) -> None:
    # Device-authenticated issuance is additionally bounded per device.  The
    # limiter key contains only a SHA-256 digest, never an enrollment secret or
    # a browser bridge grant.
    limiter_key = "device:" + hashlib.sha256(
        principal.device.id.encode("utf-8")
    ).hexdigest()
    retry_after = request.app.state.community_share_grant_issue_rate_limiter.consume(
        limiter_key
    )
    if retry_after is not None:
        raise HTTPException(
            status_code=429,
            detail="too many community share-grant attempts",
            headers={"Retry-After": str(retry_after)},
        )


def _consume_community_share_grant_redeem_limit(request: Request) -> None:
    limiter_key = _client_rate_key(request)
    retry_after = request.app.state.community_share_grant_redeem_rate_limiter.consume(
        limiter_key
    )
    if retry_after is not None:
        raise HTTPException(
            status_code=429,
            detail="too many community share-grant redemptions",
            headers={"Retry-After": str(retry_after)},
        )


def _consume_enrollment_limit(request: Request) -> None:
    limiter_key = _client_rate_key(request)
    retry_after = request.app.state.enrollment_rate_limiter.consume(limiter_key)
    if retry_after is not None:
        raise HTTPException(
            status_code=429,
            detail="too many device enrollment attempts",
            headers={"Retry-After": str(retry_after)},
        )


def _consume_claim_limit(request: Request) -> None:
    limiter_key = _client_rate_key(request)
    retry_after = request.app.state.claim_rate_limiter.consume(limiter_key)
    if retry_after is not None:
        raise HTTPException(
            status_code=429,
            detail="too many invitation batch claim attempts",
            headers={"Retry-After": str(retry_after)},
        )


def _normalized_public_filter(value: str | None, field_name: str) -> str | None:
    if value is None:
        return None
    normalized = value.strip()
    if not normalized:
        raise HTTPException(status_code=422, detail=f"{field_name} must not be blank")
    try:
        validate_label_characters(normalized)
    except ValueError as exc:
        raise HTTPException(
            status_code=422,
            detail=f"{field_name} contains unsupported characters",
        ) from exc
    return normalized


def _public_cache_control(settings: Settings) -> str:
    ttl = settings.public_cache_ttl_seconds
    return f"public, max-age={ttl}, s-maxage={ttl}"


def _public_projection_cache_key(
    *,
    projection: str,
    organization: Organization,
    period: PublicPeriod,
    metric: PublicMetric,
    tool: str | None,
    model: str | None,
    public_id: str | None = None,
) -> tuple[object, ...]:
    start_date, end_date = period_bounds(organization, period)
    return (
        projection,
        organization.id,
        organization.ledger_version,
        period,
        start_date,
        end_date,
        metric,
        tool,
        model,
        public_id,
    )


def _advance_public_projection_version(session: Session, org_id: str) -> None:
    session.execute(
        update(Organization)
        .where(Organization.id == org_id)
        .values(ledger_version=Organization.ledger_version + 1)
        .execution_options(synchronize_session="fetch")
    )


@router.get(
    "/api/v1/public/capabilities",
    response_model=PublicCapabilitiesResponse,
)
def public_capabilities(
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> PublicCapabilitiesResponse:
    _consume_public_read_limit(request)
    organization = resolve_public_organization(session, settings.public_org_slug)
    _start_date, end_date = period_bounds(organization, "all")
    cache_key = (
        "capabilities",
        organization.id,
        organization.ledger_version,
        end_date,
    )
    cached = request.app.state.public_projection_cache.get(
        cache_key, PublicCapabilitiesResponse
    )
    if cached is None:
        cached = build_public_capabilities(
            session,
            organization=organization,
            max_scan_rows=settings.public_max_scan_rows,
        )
        request.app.state.public_projection_cache.put(cache_key, cached)
    response.headers["Cache-Control"] = _public_cache_control(settings)
    return cached


@router.get(
    "/api/v1/public/leaderboard",
    response_model=PublicLeaderboardResponse,
)
def public_leaderboard(
    request: Request,
    response: Response,
    period: PublicPeriod = "today",
    metric: PublicMetric = "tokens",
    tool: Annotated[str | None, Query(min_length=1, max_length=128)] = None,
    model: Annotated[str | None, Query(min_length=1, max_length=128)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 100,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> PublicLeaderboardResponse:
    _consume_public_read_limit(request)
    normalized_tool = _normalized_public_filter(tool, "tool")
    normalized_model = _normalized_public_filter(model, "model")
    organization = resolve_public_organization(session, settings.public_org_slug)
    cache_key = _public_projection_cache_key(
        projection="leaderboard",
        organization=organization,
        period=period,
        metric=metric,
        tool=normalized_tool,
        model=normalized_model,
    )
    cached = request.app.state.public_projection_cache.get(
        cache_key, PublicLeaderboardResponse
    )
    if cached is None:
        cached = build_public_leaderboard(
            session,
            organization=organization,
            period=period,
            metric=metric,
            tool=normalized_tool,
            model=normalized_model,
            # Limit is deliberately excluded from the cache key. Cache the
            # canonical maximum once and slice it per response below.
            limit=100,
            max_scan_rows=settings.public_max_scan_rows,
        )
        request.app.state.public_projection_cache.put(cache_key, cached)
    response.headers["Cache-Control"] = _public_cache_control(settings)
    if limit == 100:
        return cached
    return cached.model_copy(update={"entries": cached.entries[:limit]})


@router.get(
    "/api/v1/public/members/{public_id}",
    response_model=PublicMemberDetailResponse,
)
def public_member_detail(
    public_id: str,
    request: Request,
    response: Response,
    period: PublicPeriod = "today",
    metric: PublicMetric = "tokens",
    tool: Annotated[str | None, Query(min_length=1, max_length=128)] = None,
    model: Annotated[str | None, Query(min_length=1, max_length=128)] = None,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> PublicMemberDetailResponse:
    _consume_public_read_limit(request)
    normalized_tool = _normalized_public_filter(tool, "tool")
    normalized_model = _normalized_public_filter(model, "model")
    try:
        canonical_public_id = str(UUID(public_id))
    except (TypeError, ValueError, AttributeError):
        raise HTTPException(status_code=404, detail="public profile not found") from None
    if public_id != canonical_public_id:
        raise HTTPException(status_code=404, detail="public profile not found")
    organization = resolve_public_organization(session, settings.public_org_slug)
    cache_key = _public_projection_cache_key(
        projection="member-detail",
        organization=organization,
        public_id=canonical_public_id,
        period=period,
        metric=metric,
        tool=normalized_tool,
        model=normalized_model,
    )
    cached = request.app.state.public_projection_cache.get(
        cache_key, PublicMemberDetailResponse
    )
    if cached is None:
        cached = build_public_member_detail(
            session,
            organization=organization,
            public_id=canonical_public_id,
            period=period,
            metric=metric,
            tool=normalized_tool,
            model=normalized_model,
            max_scan_rows=settings.public_max_scan_rows,
        )
        request.app.state.public_projection_cache.put(cache_key, cached)
    response.headers["Cache-Control"] = _public_cache_control(settings)
    return cached


@router.post("/api/v1/auth/login", response_model=TokenResponse, include_in_schema=False)
@router.post("/api/v1/auth/token", response_model=TokenResponse)
def login(
    payload: TokenRequest,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> TokenResponse:
    normalized_email = payload.email.lower()
    account_limiter_key = "account:" + hashlib.sha256(
        (
            payload.org_slug.lower()
            + "\n"
            + normalized_email
        ).encode("utf-8")
    ).hexdigest()
    ip_limiter_key = _client_rate_key(request)
    retry_after = request.app.state.login_rate_limiter.consume(
        account_limiter_key, ip_limiter_key
    )
    if retry_after is not None:
        raise HTTPException(
            status_code=429,
            detail="too many login attempts",
            headers={"Retry-After": str(retry_after)},
        )
    user = session.scalar(
        select(User)
        .join(Organization, Organization.id == User.org_id)
        .where(Organization.slug == payload.org_slug, User.email == normalized_email)
    )
    password_hash = (
        user.password_hash
        if user is not None and user.password_hash is not None
        else login_dummy_password_hash(settings.pbkdf2_iterations)
    )
    password_is_valid = verify_password(payload.password, password_hash)
    if (
        user is None
        or not user.can_login
        or not user.is_active
        or not password_is_valid
    ):
        raise HTTPException(status_code=401, detail="invalid credentials")
    request.app.state.login_rate_limiter.clear(account_limiter_key)
    response.headers["Cache-Control"] = "no-store"
    return TokenResponse(
        access_token=create_access_token(user, settings),
        expires_in=settings.jwt_ttl_seconds,
    )


@router.get("/api/v1/me", response_model=UserResponse)
def me(user: User = Depends(get_current_user)) -> User:
    return user


@router.get("/api/v1/organization", response_model=OrganizationSettingsResponse, include_in_schema=False)
@router.get("/api/v1/organization/settings", response_model=OrganizationSettingsResponse)
def organization_settings(
    user: User = Depends(get_current_user), session: Session = Depends(get_session)
) -> Organization:
    organization = session.scalar(select(Organization).where(Organization.id == user.org_id))
    if organization is None:  # pragma: no cover - protected by foreign keys
        raise HTTPException(status_code=404, detail="organization not found")
    return organization


@router.patch("/api/v1/organization", response_model=OrganizationSettingsResponse, include_in_schema=False)
@router.patch("/api/v1/organization/settings", response_model=OrganizationSettingsResponse)
def update_organization_settings(
    payload: OrganizationSettingsUpdate,
    admin: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> Organization:
    require_admin(admin)
    organization = session.scalar(
        select(Organization).where(Organization.id == admin.org_id)
    )
    if organization is None:  # pragma: no cover - protected by foreign keys
        raise HTTPException(status_code=404, detail="organization not found")
    previous_timezone = organization.default_timezone
    if payload.name is not None:
        organization.name = payload.name
    if payload.default_timezone is not None:
        organization.default_timezone = payload.default_timezone
    if payload.retention_days is not None:
        organization.retention_days = payload.retention_days
    if organization.default_timezone != previous_timezone:
        _advance_public_projection_version(session, organization.id)
    session.commit()
    session.refresh(organization)
    return organization


@router.post("/api/v1/users", response_model=UserResponse, status_code=201, include_in_schema=False)
@router.post("/api/v1/admin/users", response_model=UserResponse, status_code=201)
def create_user(
    payload: UserCreate,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> User:
    require_admin(user)
    new_user = User(
        org_id=user.org_id,
        email=payload.email.lower(),
        display_name=payload.display_name,
        role=UserRole(payload.role),
        password_hash=hash_password(payload.password, settings.pbkdf2_iterations),
    )
    session.add(new_user)
    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(status_code=409, detail="email already exists in organization") from exc
    session.refresh(new_user)
    return new_user


@router.post(
    "/api/v1/admin/participants",
    response_model=ParticipantEnrollmentResponse,
    status_code=201,
)
def create_participant_with_enrollment(
    payload: ParticipantCreate,
    response: Response,
    admin: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> ParticipantEnrollmentResponse:
    require_admin(admin)
    raw_token = generate_enrollment_token()
    expires_at = utcnow() + timedelta(minutes=payload.expires_in_minutes)
    participant = User(
        org_id=admin.org_id,
        email=None,
        password_hash=None,
        display_name=payload.display_name,
        role=UserRole.MEMBER,
        public_profile_enabled=payload.public_profile_enabled,
    )
    session.add(participant)
    try:
        session.flush()
        session.add(
            EnrollmentToken(
                org_id=admin.org_id,
                user_id=participant.id,
                created_by_user_id=admin.id,
                token_hash=opaque_token_hash(raw_token),
                expires_at=expires_at,
            )
        )
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(
            status_code=409,
            detail="participant could not be created",
        ) from exc
    session.refresh(participant)
    response.headers["Cache-Control"] = "no-store"
    return ParticipantEnrollmentResponse(
        participant=UserResponse.model_validate(participant),
        enrollment_token=raw_token,
        expires_at=expires_at,
    )


def _aware_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _invitation_batch_status(
    batch: InvitationBatch, *, now: datetime | None = None
) -> str:
    current = now or utcnow()
    if batch.closed_at is not None:
        return "closed"
    if _aware_utc(batch.expires_at) <= current:
        return "expired"
    if batch.claimed_count >= batch.capacity:
        return "full"
    return "open"


def _invitation_batch_summary(batch: InvitationBatch) -> InvitationBatchSummary:
    return InvitationBatchSummary(
        id=batch.id,
        capacity=batch.capacity,
        claimed_count=batch.claimed_count,
        expires_at=batch.expires_at,
        closed_at=batch.closed_at,
        created_at=batch.created_at,
        status=_invitation_batch_status(batch),
    )


@router.post(
    "/api/v1/admin/invitation-batches",
    response_model=InvitationBatchCreateResponse,
    status_code=201,
)
def create_invitation_batch(
    payload: InvitationBatchCreate,
    response: Response,
    admin: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> InvitationBatchCreateResponse:
    require_admin(admin)
    raw_token = generate_enrollment_token()
    batch = InvitationBatch(
        org_id=admin.org_id,
        created_by_user_id=admin.id,
        token_hash=opaque_token_hash(raw_token),
        capacity=payload.capacity,
        claimed_count=0,
        expires_at=utcnow() + timedelta(hours=payload.expires_in_hours),
    )
    session.add(batch)
    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(
            status_code=409,
            detail="invitation batch could not be created",
        ) from exc
    session.refresh(batch)
    response.headers["Cache-Control"] = "no-store"
    return InvitationBatchCreateResponse(
        batch=_invitation_batch_summary(batch),
        invitation_token=raw_token,
    )


@router.get(
    "/api/v1/admin/invitation-batches",
    response_model=list[InvitationBatchSummary],
)
def list_invitation_batches(
    response: Response,
    limit: Annotated[int, Query(ge=1, le=100)] = 100,
    admin: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> list[InvitationBatchSummary]:
    require_admin(admin)
    batches = session.scalars(
        select(InvitationBatch)
        .where(InvitationBatch.org_id == admin.org_id)
        .order_by(InvitationBatch.created_at.desc(), InvitationBatch.id.desc())
        .limit(limit)
    ).all()
    response.headers["Cache-Control"] = "no-store"
    return [_invitation_batch_summary(batch) for batch in batches]


@router.post(
    "/api/v1/admin/invitation-batches/{batch_id}/close",
    response_model=InvitationBatchSummary,
)
def close_invitation_batch(
    batch_id: UUID,
    response: Response,
    admin: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> InvitationBatchSummary:
    require_admin(admin)
    batch = session.scalar(
        select(InvitationBatch)
        .where(
            InvitationBatch.id == str(batch_id),
            InvitationBatch.org_id == admin.org_id,
        )
        .with_for_update()
    )
    if batch is None:
        raise HTTPException(status_code=404, detail="invitation batch not found")
    if batch.closed_at is None:
        batch.closed_at = utcnow()
        session.commit()
        session.refresh(batch)
    response.headers["Cache-Control"] = "no-store"
    return _invitation_batch_summary(batch)


@router.post(
    "/api/v1/public/invitation-batches/claim",
    response_model=InvitationBatchClaimResponse,
    status_code=201,
)
def claim_invitation_batch(
    payload: InvitationBatchClaim,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
) -> InvitationBatchClaimResponse:
    _consume_claim_limit(request)
    now = utcnow()
    batch = session.scalar(
        select(InvitationBatch)
        .where(
            InvitationBatch.token_hash
            == opaque_token_hash(payload.invitation_token)
        )
        .with_for_update()
    )
    if batch is None or _invitation_batch_status(batch, now=now) != "open":
        session.rollback()
        raise HTTPException(status_code=409, detail="invitation batch unavailable")

    enrollment_token = generate_enrollment_token()
    enrollment_expires_at = now + timedelta(minutes=60)
    participant = User(
        org_id=batch.org_id,
        email=None,
        password_hash=None,
        display_name=payload.display_name,
        role=UserRole.MEMBER,
        public_profile_enabled=payload.public_profile_enabled,
    )
    session.add(participant)
    try:
        session.flush()
        session.add(
            EnrollmentToken(
                org_id=batch.org_id,
                user_id=participant.id,
                created_by_user_id=batch.created_by_user_id,
                token_hash=opaque_token_hash(enrollment_token),
                expires_at=enrollment_expires_at,
            )
        )
        batch.claimed_count += 1
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(
            status_code=409,
            detail="nickname unavailable",
        ) from exc
    response.headers["Cache-Control"] = "no-store"
    return InvitationBatchClaimResponse(
        nickname=participant.display_name or "",
        enrollment_token=enrollment_token,
        expires_at=enrollment_expires_at,
    )


def _list_users(admin: User, session: Session) -> list[User]:
    require_admin(admin)
    return list(
        session.scalars(
            select(User)
            .where(User.org_id == admin.org_id)
            .order_by(User.email.is_(None), User.email, User.id)
        )
    )


@router.get("/api/v1/admin/users", response_model=list[UserResponse])
def list_users(
    admin: User = Depends(get_current_user), session: Session = Depends(get_session)
) -> list[User]:
    return _list_users(admin, session)


@router.get("/api/v1/users", response_model=list[UserResponse], include_in_schema=False)
def list_users_alias(
    admin: User = Depends(get_current_user), session: Session = Depends(get_session)
) -> list[User]:
    return _list_users(admin, session)


@router.get("/api/v1/users/{user_id}", response_model=UserResponse)
def get_user(
    user_id: UUID,
    actor: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> User:
    query = select(User).where(User.org_id == actor.org_id, User.id == str(user_id))
    if actor.role == UserRole.MEMBER:
        query = query.where(User.id == actor.id)
    result = session.scalar(query)
    if result is None:
        raise HTTPException(status_code=404, detail="user not found")
    return result


@router.patch("/api/v1/users/{user_id}", response_model=UserResponse)
def update_user_status(
    user_id: UUID,
    payload: UserStatusUpdate,
    admin: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> User:
    require_admin(admin)
    target = session.scalar(
        select(User).where(User.org_id == admin.org_id, User.id == str(user_id))
    )
    if target is None:
        raise HTTPException(status_code=404, detail="user not found")
    if target.id == admin.id and payload.is_active is False:
        raise HTTPException(
            status_code=409,
            detail="an administrator cannot disable their own account",
        )
    desired_active = (
        payload.is_active if payload.is_active is not None else target.is_active
    )
    desired_display_name = (
        payload.display_name
        if "display_name" in payload.model_fields_set
        else target.display_name
    )
    desired_public_profile = (
        payload.public_profile_enabled
        if payload.public_profile_enabled is not None
        else target.public_profile_enabled
    )
    previous_public_projection = (
        target.is_active,
        target.public_profile_enabled,
        target.display_name,
    )
    # Disabling a member also closes the public projection. Re-enabling the
    # account cannot silently republish history; an admin must opt in again.
    if not desired_active:
        desired_public_profile = False
    if desired_public_profile:
        if target.role != UserRole.MEMBER:
            raise HTTPException(
                status_code=409,
                detail="only members can have a public profile",
            )
        if desired_display_name is None or not desired_display_name.strip():
            raise HTTPException(
                status_code=409,
                detail="public profile requires a display name",
            )
        try:
            validate_public_nickname(desired_display_name.strip())
        except ValueError as exc:
            raise HTTPException(
                status_code=409,
                detail="public profile requires a safe display name",
            ) from exc
    target.is_active = desired_active
    target.display_name = desired_display_name
    target.public_profile_enabled = desired_public_profile
    current_public_projection = (
        target.is_active,
        target.public_profile_enabled,
        target.display_name,
    )
    if (
        target.role == UserRole.MEMBER
        and current_public_projection != previous_public_projection
    ):
        _advance_public_projection_version(session, target.org_id)
    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(
            status_code=409,
            detail="user could not be updated",
        ) from exc
    session.refresh(target)
    return target


def _create_enrollment_token(
    payload: EnrollmentTokenCreate,
    admin: User,
    session: Session,
) -> EnrollmentTokenResponse:
    require_admin(admin)
    now = utcnow()
    target_user = session.scalar(
        select(User)
        .where(User.id == str(payload.user_id), User.org_id == admin.org_id)
        .with_for_update()
    )
    if (
        target_user is None
        or not target_user.is_active
        or target_user.role != UserRole.MEMBER
    ):
        raise HTTPException(status_code=404, detail="active member not found")
    # Serialize reissues per member, then expire only credentials that are both
    # unused and still live. Used rows remain unchanged for auditability. The
    # member lock also means concurrent reissues leave exactly one live code.
    session.execute(
        update(EnrollmentToken)
        .where(
            EnrollmentToken.org_id == admin.org_id,
            EnrollmentToken.user_id == target_user.id,
            EnrollmentToken.used_at.is_(None),
            EnrollmentToken.expires_at > now,
        )
        .values(expires_at=now)
        .execution_options(synchronize_session=False)
    )
    raw_token = generate_enrollment_token()
    expires_at = now + timedelta(minutes=payload.expires_in_minutes)
    session.add(
        EnrollmentToken(
            org_id=admin.org_id,
            user_id=target_user.id,
            created_by_user_id=admin.id,
            token_hash=opaque_token_hash(raw_token),
            expires_at=expires_at,
        )
    )
    session.commit()
    return EnrollmentTokenResponse(enrollment_token=raw_token, expires_at=expires_at)


@router.post(
    "/api/v1/enrollment-tokens", response_model=EnrollmentTokenResponse, status_code=201
)
def create_enrollment_token(
    payload: EnrollmentTokenCreate,
    response: Response,
    admin: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> EnrollmentTokenResponse:
    result = _create_enrollment_token(payload, admin, session)
    response.headers["Cache-Control"] = "no-store"
    return result


@router.post(
    "/api/v1/admin/enrollment-tokens",
    response_model=EnrollmentTokenResponse,
    status_code=201,
    include_in_schema=False,
)
def create_enrollment_token_alias(
    payload: EnrollmentTokenCreate,
    response: Response,
    admin: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> EnrollmentTokenResponse:
    result = _create_enrollment_token(payload, admin, session)
    response.headers["Cache-Control"] = "no-store"
    return result


@router.post("/api/v1/devices/enroll", response_model=DeviceEnrollResponse, status_code=201)
def enroll_device(
    payload: DeviceEnrollRequest,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
) -> DeviceEnrollResponse:
    # Consume the anonymous network bucket before touching the token table.
    # One-time codes are high entropy, but this closes the database-amplification
    # path and is deliberately independent from whether a code is valid.
    _consume_enrollment_limit(request)
    now = utcnow()
    claimed = session.execute(
        update(EnrollmentToken)
        .where(
            EnrollmentToken.token_hash
            == opaque_token_hash(payload.enrollment_token),
            EnrollmentToken.used_at.is_(None),
            EnrollmentToken.expires_at > now,
        )
        .values(used_at=now)
        .returning(
            EnrollmentToken.id,
            EnrollmentToken.org_id,
            EnrollmentToken.user_id,
        )
        .execution_options(synchronize_session=False)
    )
    token = claimed.one_or_none()
    if token is None:
        session.rollback()
        raise HTTPException(status_code=400, detail="invalid, expired, or already used enrollment token")
    target_user = session.scalar(
        select(User).where(User.id == token.user_id, User.org_id == token.org_id)
    )
    if (
        target_user is None
        or not target_user.is_active
        or target_user.role != UserRole.MEMBER
    ):
        raise HTTPException(status_code=403, detail="member is disabled")

    device_secret = generate_device_secret()
    signing_key = derive_device_signing_key(device_secret).hex()
    device = session.scalar(
        select(Device)
        .where(
            Device.org_id == token.org_id,
            Device.device_public_id == str(payload.device_public_id),
        )
        .with_for_update()
    )
    if device is not None:
        if device.user_id != token.user_id:
            session.rollback()
            raise HTTPException(
                status_code=409,
                detail="device identifier is already owned by another member",
            )
        # Re-enrollment preserves the stable device identity and usage foreign
        # keys while invalidating the previous credential immediately.
        device.platform = payload.platform
        device.app_version = payload.app_version
        device.collector_version = payload.collector_version
        device.signing_key = signing_key
        device.is_active = True
        device.disabled_at = None
    else:
        device = Device(
            org_id=token.org_id,
            user_id=token.user_id,
            device_public_id=str(payload.device_public_id),
            platform=payload.platform,
            app_version=payload.app_version,
            collector_version=payload.collector_version,
            signing_key=signing_key,
        )
        session.add(device)
    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(status_code=409, detail="device is already enrolled") from exc
    response.headers["Cache-Control"] = "no-store"
    return DeviceEnrollResponse(
        device_id=device.id,
        device_public_id=device.device_public_id,
        device_secret=device_secret,
    )


@router.get("/api/v1/devices", response_model=list[DeviceResponse])
def list_devices(
    user: User = Depends(get_current_user), session: Session = Depends(get_session)
) -> list[Device]:
    query = select(Device).where(Device.org_id == user.org_id)
    if user.role == UserRole.MEMBER:
        query = query.where(Device.user_id == user.id)
    return list(session.scalars(query.order_by(Device.created_at, Device.id)))


@router.get(
    "/api/v1/devices/me/community-rank",
    response_model=DeviceCommunityRankResponse,
)
def device_community_rank(
    response: Response,
    principal: DevicePrincipal = Depends(get_device_principal),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> DeviceCommunityRankResponse:
    organization = resolve_public_organization(session, settings.public_org_slug)
    if principal.user.org_id != organization.id:
        raise HTTPException(status_code=404, detail="public leaderboard not found")
    response.headers["Cache-Control"] = "no-store"
    return build_device_community_rank(
        session,
        organization=organization,
        user=principal.user,
        max_scan_rows=settings.public_max_scan_rows,
    )


@router.post(
    "/api/v1/devices/me/community-share-grants",
    response_model=CommunityShareGrantResponse,
    status_code=201,
)
def issue_community_share_grant(
    _payload: CommunityShareGrantIssueRequest,
    request: Request,
    response: Response,
    principal: DevicePrincipal = Depends(get_device_principal),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> CommunityShareGrantResponse:
    """Mint a one-time bridge for this device's already-public rank only."""

    _consume_community_share_grant_issue_limit(request, principal)
    organization = resolve_public_organization(session, settings.public_org_slug)
    if principal.user.org_id != organization.id:
        raise HTTPException(status_code=404, detail="public leaderboard not found")

    # Device authentication consumed its nonce in a separate transaction. Lock
    # current rows again so disable/public-profile changes between auth and
    # issuance cannot receive a fresh bridge.
    device = session.scalar(
        select(Device)
        .where(Device.id == principal.device.id, Device.org_id == organization.id)
        .with_for_update()
    )
    user = session.scalar(
        select(User)
        .where(User.id == principal.user.id, User.org_id == organization.id)
        .with_for_update()
    )
    if (
        device is None
        or user is None
        or device.user_id != user.id
        or not device.is_active
        or not user.is_active
        or not user.public_profile_enabled
    ):
        session.rollback()
        raise HTTPException(status_code=403, detail="community share is unavailable")

    rank = build_device_community_rank(
        session,
        organization=organization,
        user=user,
        max_scan_rows=settings.public_max_scan_rows,
    )
    if not rank.public_profile_enabled or rank.rank is None or rank.nickname is None:
        session.rollback()
        raise HTTPException(status_code=403, detail="community share is unavailable")

    now = utcnow()
    # Retain a small, bounded audit window while allowing lazy cleanup without
    # a separate scheduler. Expired raw values can never be reconstructed from
    # the stored hashes.
    session.execute(
        delete(CommunityShareGrant).where(
            CommunityShareGrant.expires_at < now - timedelta(days=1)
        )
    )
    session.execute(
        update(CommunityShareGrant)
        .where(
            CommunityShareGrant.device_id == device.id,
            CommunityShareGrant.consumed_at.is_(None),
            CommunityShareGrant.expires_at > now,
        )
        .values(consumed_at=now)
    )

    expires_at = now + timedelta(seconds=settings.community_share_grant_ttl_seconds)
    # Hash collisions from 32 CSPRNG bytes are astronomically unlikely; the
    # bounded retry still turns the uniqueness constraint into a fail-closed
    # guarantee rather than an accidental 500.
    for _ in range(settings.community_share_grant_issue_attempts):
        raw_grant = generate_community_share_grant()
        grant = CommunityShareGrant(
            org_id=organization.id,
            user_id=user.id,
            device_id=device.id,
            grant_hash=opaque_token_hash(raw_grant),
            expires_at=expires_at,
        )
        session.add(grant)
        try:
            session.commit()
        except IntegrityError:
            session.rollback()
            continue
        response.headers["Cache-Control"] = "no-store"
        return CommunityShareGrantResponse(
            grant=raw_grant,
            expires_at=expires_at,
            public_id=rank.public_id,
        )
    raise HTTPException(status_code=503, detail="community share is temporarily unavailable")


@router.post(
    "/api/v1/public/community-share-grants/redeem",
    response_model=CommunityShareGrantRedeemResponse,
)
def redeem_community_share_grant(
    payload: CommunityShareGrantRedeemRequest,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> CommunityShareGrantRedeemResponse:
    """Consume an opaque bridge without creating a browser login session."""

    _consume_community_share_grant_redeem_limit(request)
    organization = resolve_public_organization(session, settings.public_org_slug)
    now = utcnow()
    grant_hash = opaque_token_hash(payload.grant)
    eligible_device_ids = (
        select(Device.id)
        .join(
            User,
            (User.id == Device.user_id) & (User.org_id == Device.org_id),
        )
        .where(
            Device.org_id == organization.id,
            Device.is_active.is_(True),
            User.org_id == organization.id,
            User.role == UserRole.MEMBER,
            User.is_active.is_(True),
            User.public_profile_enabled.is_(True),
            User.display_name.is_not(None),
        )
    )
    consumed = session.execute(
        update(CommunityShareGrant)
        .where(
            CommunityShareGrant.grant_hash == grant_hash,
            CommunityShareGrant.org_id == organization.id,
            CommunityShareGrant.consumed_at.is_(None),
            CommunityShareGrant.expires_at > now,
            CommunityShareGrant.device_id.in_(eligible_device_ids),
        )
        .values(consumed_at=now)
        .returning(CommunityShareGrant.user_id)
    ).scalar_one_or_none()
    if consumed is None:
        session.rollback()
        raise HTTPException(status_code=403, detail="community share is unavailable")

    user = session.scalar(
        select(User).where(User.id == consumed, User.org_id == organization.id)
    )
    if user is None:
        session.rollback()
        raise HTTPException(status_code=403, detail="community share is unavailable")
    rank = build_device_community_rank(
        session,
        organization=organization,
        user=user,
        max_scan_rows=settings.public_max_scan_rows,
    )
    if not rank.public_profile_enabled or rank.rank is None or rank.nickname is None:
        session.rollback()
        raise HTTPException(status_code=403, detail="community share is unavailable")
    session.commit()
    response.headers["Cache-Control"] = "no-store"
    return CommunityShareGrantRedeemResponse(public_id=rank.public_id)


def _set_device_status(
    *, device_id: str, desired_status: bool, actor: User, session: Session
) -> Device:
    query = select(Device).where(Device.org_id == actor.org_id, Device.id == device_id)
    if actor.role == UserRole.MEMBER:
        query = query.where(Device.user_id == actor.id)
    device = session.scalar(query)
    if device is None:
        raise HTTPException(status_code=404, detail="device not found")
    if desired_status and actor.role != UserRole.ADMIN:
        raise HTTPException(status_code=403, detail="only an administrator can re-enable a device")
    device.is_active = desired_status
    device.disabled_at = None if desired_status else utcnow()
    session.commit()
    session.refresh(device)
    return device


@router.patch("/api/v1/devices/{device_id}", response_model=DeviceResponse)
def update_device_status(
    device_id: UUID,
    payload: DeviceStatusUpdate,
    actor: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> Device:
    return _set_device_status(
        device_id=str(device_id), desired_status=payload.is_active, actor=actor, session=session
    )


@router.post("/api/v1/devices/{device_id}/disable", response_model=DeviceResponse)
def disable_device(
    device_id: UUID,
    actor: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> Device:
    return _set_device_status(
        device_id=str(device_id), desired_status=False, actor=actor, session=session
    )


@router.post("/api/v1/usage/daily", response_model=DailyUsageIngestResponse)
def upload_daily_usage(
    report: DailyUsageReport,
    principal: DevicePrincipal = Depends(get_device_principal),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> DailyUsageIngestResponse:
    created, updated, unchanged, ledger_version = ingest_daily_usage(
        session,
        device=principal.device,
        report=report,
        max_rows_per_device=settings.usage_max_rows_per_device,
        max_rows_per_org=settings.usage_max_rows_per_org,
    )
    return DailyUsageIngestResponse(
        created=created,
        updated=updated,
        unchanged=unchanged,
        ledger_version=ledger_version,
    )


@router.post("/api/v1/pricing", response_model=PriceResponse, status_code=201, include_in_schema=False)
@router.post("/api/v1/prices", response_model=PriceResponse, status_code=201)
def create_price(
    payload: PriceCreate,
    admin: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> PriceVersion:
    require_admin(admin)
    price = PriceVersion(
        org_id=admin.org_id,
        tool=payload.tool,
        model=payload.model,
        currency=payload.currency,
        public_estimate=payload.public_estimate,
        input_per_million=payload.input_per_million,
        output_per_million=payload.output_per_million,
        cache_read_per_million=payload.cache_read_per_million,
        cache_write_per_million=payload.cache_write_per_million,
        effective_from=payload.effective_from,
        created_by_user_id=admin.id,
    )
    session.add(price)
    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(status_code=409, detail="price version already exists") from exc
    session.refresh(price)
    return price


@router.get("/api/v1/pricing", response_model=list[PriceResponse], include_in_schema=False)
@router.get("/api/v1/prices", response_model=list[PriceResponse])
def list_prices(
    user: User = Depends(get_current_user), session: Session = Depends(get_session)
) -> list[PriceVersion]:
    require_admin(user)
    return list(
        session.scalars(
            select(PriceVersion)
            .where(PriceVersion.org_id == user.org_id)
            .order_by(PriceVersion.tool, PriceVersion.model, PriceVersion.effective_from)
        )
    )


@router.patch("/api/v1/prices/{price_id}", response_model=PriceResponse)
def update_price_visibility(
    price_id: UUID,
    payload: PriceVisibilityUpdate,
    admin: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> PriceVersion:
    require_admin(admin)
    price = session.scalar(
        select(PriceVersion).where(
            PriceVersion.id == str(price_id),
            PriceVersion.org_id == admin.org_id,
        )
    )
    if price is None:
        raise HTTPException(status_code=404, detail="price version not found")
    visibility_changed = price.public_estimate != payload.public_estimate
    price.public_estimate = payload.public_estimate
    if visibility_changed:
        _advance_public_projection_version(session, price.org_id)
    session.commit()
    session.refresh(price)
    return price


@router.get("/api/v1/usage", response_model=UsageDashboardResponse, include_in_schema=False)
@router.get("/api/v1/dashboard", response_model=UsageDashboardResponse, include_in_schema=False)
@router.get("/api/v1/dashboard/usage", response_model=UsageDashboardResponse)
def dashboard_usage(
    user_id: UUID | None = None,
    device_id: UUID | None = None,
    tool: Annotated[str | None, Query(min_length=1, max_length=128)] = None,
    model: Annotated[str | None, Query(min_length=1, max_length=128)] = None,
    source: Annotated[str | None, Query(min_length=1, max_length=128)] = None,
    timezone_name: Annotated[
        str | None, Query(alias="timezone", min_length=1, max_length=64)
    ] = None,
    start_date: date | None = None,
    end_date: date | None = None,
    actor: User = Depends(get_current_user),
    session: Session = Depends(get_session),
) -> UsageDashboardResponse:
    organization = session.scalar(
        select(Organization).where(Organization.id == actor.org_id)
    )
    if organization is None:  # pragma: no cover - protected by foreign keys
        raise HTTPException(status_code=404, detail="organization not found")
    organization_timezone = organization.default_timezone
    today = utcnow().astimezone(ZoneInfo(organization_timezone)).date()
    start_date = start_date or today - timedelta(days=29)
    end_date = end_date or today
    if start_date > end_date:
        raise HTTPException(status_code=422, detail="start_date must not be after end_date")
    if (end_date - start_date).days > 366:
        raise HTTPException(status_code=422, detail="date range cannot exceed 366 days")
    if timezone_name is not None:
        try:
            ZoneInfo(timezone_name)
        except ZoneInfoNotFoundError as exc:
            raise HTTPException(status_code=422, detail="unknown IANA timezone") from exc

    query = select(DailyUsage).where(
        DailyUsage.org_id == actor.org_id,
        DailyUsage.is_deleted.is_(False),
        DailyUsage.usage_date >= start_date,
        DailyUsage.usage_date <= end_date,
    )
    if actor.role == UserRole.MEMBER:
        if user_id is not None and str(user_id) != actor.id:
            raise HTTPException(status_code=403, detail="members can only query their own usage")
        query = query.where(DailyUsage.user_id == actor.id)
    elif user_id is not None:
        query = query.where(DailyUsage.user_id == str(user_id))
    if device_id is not None:
        query = query.where(DailyUsage.device_id == str(device_id))
    if tool is not None:
        query = query.where(DailyUsage.tool == tool.strip())
    if model is not None:
        query = query.where(DailyUsage.model == model.strip())
    if source is not None:
        query = query.where(DailyUsage.source == source.strip())
    if timezone_name is not None:
        query = query.where(DailyUsage.timezone == timezone_name)

    row_count = session.scalar(select(func.count()).select_from(query.subquery())) or 0
    if row_count > 5_000:
        raise HTTPException(
            status_code=422,
            detail="query matches more than 5000 rows; narrow the date range or filters",
        )
    usage_rows = list(
        session.scalars(
            query.order_by(
                DailyUsage.usage_date,
                DailyUsage.user_id,
                DailyUsage.device_id,
                DailyUsage.tool,
                DailyUsage.model,
                DailyUsage.source,
            )
        )
    )
    rows = [
        UsageRow(
            date=row.usage_date,
            timezone=row.timezone,
            user_id=row.user_id,
            device_id=row.device_id,
            tool=row.tool,
            model=row.model,
            source=row.source,
            completeness=row.completeness,
            input_tokens=row.input_tokens,
            output_tokens=row.output_tokens,
            cache_read_tokens=row.cache_read_tokens,
            cache_write_tokens=row.cache_write_tokens,
            total_tokens=(
                row.input_tokens
                + row.output_tokens
                + row.cache_read_tokens
                + row.cache_write_tokens
            ),
            schema_version=row.report_schema_version,
            collector_version=row.collector_version,
            price_version_id=row.price_version_id,
            cost_microunits=row.cost_microunits,
            cost_currency=row.cost_currency,
        )
        for row in usage_rows
    ]
    priced_costs: dict[str, int] = defaultdict(int)
    unpriced_rows = 0
    for row in usage_rows:
        if row.cost_microunits is None or row.cost_currency is None:
            unpriced_rows += 1
        else:
            priced_costs[row.cost_currency] += row.cost_microunits
    seen_timezones = {row.timezone for row in usage_rows}
    timezone_warning = None
    if len(seen_timezones) > 1 or (
        seen_timezones and organization_timezone not in seen_timezones
    ):
        timezone_warning = (
            "Dates are device-local daily buckets and cannot be losslessly regrouped "
            "into another timezone; filter by timezone for like-for-like totals."
        )
    return UsageDashboardResponse(
        rows=rows,
        totals=UsageTotals(
            input_tokens=sum(row.input_tokens for row in usage_rows),
            output_tokens=sum(row.output_tokens for row in usage_rows),
            cache_read_tokens=sum(row.cache_read_tokens for row in usage_rows),
            cache_write_tokens=sum(row.cache_write_tokens for row in usage_rows),
            total_tokens=sum(
                row.input_tokens
                + row.output_tokens
                + row.cache_read_tokens
                + row.cache_write_tokens
                for row in usage_rows
            ),
            priced_costs_microunits=dict(priced_costs),
            unpriced_rows=unpriced_rows,
        ),
        organization_timezone=organization_timezone,
        mixed_timezones=len(seen_timezones) > 1,
        timezone_warning=timezone_warning,
    )
