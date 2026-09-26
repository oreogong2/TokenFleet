"""Verified public catalog and narrowly scoped price-maintenance API.

Weekly imports are immutable price versions plus missing-only exact backfills.
They never use an administrator login or alter usage labels/identities/tokens.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
import hashlib
import json
import re
import secrets
from typing import Annotated, Literal
from urllib.parse import urlsplit
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import Field, field_validator, model_validator
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .api import _consume_public_read_limit
from .config import Settings
from .dependencies import bearer, get_current_user, get_device_principal, get_session, get_settings
from .models import DailyUsage, Organization, PriceManagementCredential, PriceVersion, User, UserRole, utcnow
from .pricing import catalog_fingerprint, find_price, load_prices, normalize_model, normalize_tool, reprice_usage
from .public_projection import resolve_public_organization
from .schemas import PriceCreate, StrictModel
from .security import DevicePrincipal, opaque_token_hash, require_admin

router = APIRouter()
OFFICIAL_PAGES = {
    'developers.openai.com': ('/api/docs/pricing',),
    'platform.openai.com': ('/docs/pricing',),
    'openai.com': ('/api/pricing',),
    'platform.claude.com': ('/docs/en/about-claude/pricing',),
    'docs.anthropic.com': ('/en/docs/about-claude/pricing',),
    'docs.z.ai': ('/guides/overview/pricing',),
    'api-docs.deepseek.com': ('/quick_start/pricing', '/updates/'),
}


class OfficialPriceImport(PriceCreate):
    tool: Literal['*'] = '*'
    public_estimate: Literal[True] = True
    effective_from: date | None = None
    effective_basis: Literal['official_date', 'ledger_first_seen']
    source_url: Annotated[str, Field(min_length=1, max_length=512)]
    source_checked_at: date

    @field_validator('source_url')
    @classmethod
    def official_public_page(cls, value: str) -> str:
        parsed = urlsplit(value)
        paths = OFFICIAL_PAGES.get(parsed.hostname or '', ())
        if (parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port
                or parsed.query or parsed.fragment
                or not any(parsed.path.rstrip('/') == p.rstrip('/')
                           or (p.endswith('/') and parsed.path.startswith(p)) for p in paths)):
            raise ValueError('an allowlisted official public pricing page is required')
        return value

    @field_validator('source_checked_at')
    @classmethod
    def checked_date_is_not_future(cls, value: date) -> date:
        if value > utcnow().date():
            raise ValueError('source_checked_at cannot be in the future')
        return value

    @model_validator(mode='after')
    def verified_scope(self) -> 'OfficialPriceImport':
        canonical = normalize_model(self.model)
        host = urlsplit(self.source_url).hostname or ''
        families = ('gpt-', 'o1', 'o3', 'o4') if host.endswith('openai.com') else (
            ('claude-',) if host in ('platform.claude.com', 'docs.anthropic.com') else
            ('glm-',) if host == 'docs.z.ai' else ('deepseek-',))
        if not canonical.startswith(families) or not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,127}', canonical):
            raise ValueError('model family does not match the official price source')
        if (self.effective_basis == 'official_date') != (self.effective_from is not None):
            raise ValueError('official_date requires a date; ledger_first_seen is resolved by the server')
        return self


class PriceCredentialCreate(StrictModel):
    expires_in_days: Annotated[int, Field(strict=True, ge=1, le=90)] = 30


@dataclass(frozen=True)
class PricePrincipal:
    org_id: str
    user_id: str


def get_price_principal(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    session: Session = Depends(get_session), settings: Settings = Depends(get_settings),
) -> PricePrincipal:
    if credentials is None or credentials.scheme.lower() != 'bearer':
        raise HTTPException(status_code=401, detail='price credential required')
    token = credentials.credentials
    if not token.startswith('tfprice_'):
        admin = get_current_user(credentials, session, settings)
        require_admin(admin)
        return PricePrincipal(admin.org_id, admin.id)
    if not re.fullmatch(r'tfprice_[A-Za-z0-9_-]{43}', token):
        raise HTTPException(status_code=401, detail='invalid price credential')
    row = session.scalar(select(PriceManagementCredential).where(
        PriceManagementCredential.token_hash == opaque_token_hash(token),
        PriceManagementCredential.is_active.is_(True),
        PriceManagementCredential.expires_at > utcnow(),
    ))
    owner = session.scalar(select(User).where(User.id == row.created_by_user_id,
                                            User.org_id == row.org_id)) if row else None
    if owner is None or not owner.is_active or owner.role != UserRole.ADMIN:
        raise HTTPException(status_code=401, detail='invalid or expired price credential')
    return PricePrincipal(row.org_id, owner.id)


@router.post('/api/v1/price-management/credentials', status_code=201)
def issue_credential(payload: PriceCredentialCreate, response: Response,
                     admin: User = Depends(get_current_user), session: Session = Depends(get_session)) -> dict:
    require_admin(admin)
    # Serialize credential issuance per organization, as with price writes.
    session.scalar(select(Organization).where(Organization.id == admin.org_id).with_for_update())
    count = session.scalar(select(func.count()).select_from(PriceManagementCredential).where(
        PriceManagementCredential.org_id == admin.org_id,
        PriceManagementCredential.is_active.is_(True), PriceManagementCredential.expires_at > utcnow())) or 0
    if count >= 20:
        raise HTTPException(status_code=409, detail='revoke an existing price credential first')
    token = 'tfprice_' + secrets.token_urlsafe(32)
    row = PriceManagementCredential(org_id=admin.org_id, created_by_user_id=admin.id,
        token_hash=opaque_token_hash(token), expires_at=utcnow() + timedelta(days=payload.expires_in_days))
    session.add(row)
    session.commit()
    response.headers['Cache-Control'] = 'no-store'
    return {'id': row.id, 'credential': token, 'expires_at': row.expires_at, 'scope': 'prices:missing-only'}


@router.delete('/api/v1/price-management/credentials/{credential_id}', status_code=204)
def revoke_credential(credential_id: UUID, admin: User = Depends(get_current_user),
                      session: Session = Depends(get_session)) -> Response:
    require_admin(admin)
    row = session.scalar(select(PriceManagementCredential).where(
        PriceManagementCredential.id == str(credential_id), PriceManagementCredential.org_id == admin.org_id))
    if row is None:
        raise HTTPException(status_code=404, detail='price credential not found')
    row.is_active = False
    session.commit()
    return Response(status_code=204, headers={'Cache-Control': 'no-store'})


def verified_prices(session: Session, org_id: str) -> list[PriceVersion]:
    return [p for p in load_prices(session, org_id)
            if p.public_estimate and p.source_url and p.source_checked_at and p.effective_basis]


def public_catalog(session: Session, org_id: str) -> dict:
    prices = verified_prices(session, org_id)
    fields = ('id', 'tool', 'model', 'currency', 'input_per_million', 'output_per_million',
              'cache_read_per_million', 'cache_write_per_million', 'effective_from',
              'source_url', 'source_checked_at', 'effective_basis')
    entries = [{k: str(getattr(p, k)) for k in fields}
               for p in sorted(prices, key=lambda p: (p.tool, p.model, p.effective_from, p.id))]
    # No organization/user identifiers or private-price fingerprints are published.
    org = session.get(Organization, org_id)
    if org is None:
        raise HTTPException(status_code=404, detail='organization not found')
    body = {'schema_version': 1, 'normalization_version': 1, 'revision': org.price_catalog_revision,
            'basis': 'standard_api_equivalent', 'prices': entries}
    body['version'] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return body


@router.get('/api/v1/public/price-catalog')
def read_public_catalog(request: Request, session: Session = Depends(get_session),
                        settings: Settings = Depends(get_settings)) -> Response:
    _consume_public_read_limit(request)
    org = resolve_public_organization(session, settings.public_org_slug)
    result = public_catalog(session, org.id)
    headers = {'ETag': '"' + result['version'] + '"', 'Cache-Control': 'public, max-age=60'}
    if request.headers.get('If-None-Match') == headers['ETag']:
        return Response(status_code=304, headers=headers)
    return JSONResponse(result, headers=headers)


@router.get('/api/v1/device/price-catalog')
def read_device_catalog(principal: DevicePrincipal = Depends(get_device_principal),
                        session: Session = Depends(get_session)) -> dict:
    return public_catalog(session, principal.device.org_id)


def first_seen_dates(session: Session, org_id: str) -> dict[str, date]:
    rows = session.execute(select(DailyUsage.model, func.min(DailyUsage.usage_date)).where(
        DailyUsage.org_id == org_id, DailyUsage.is_deleted.is_(False)).group_by(DailyUsage.model).limit(10_001)).all()
    if len(rows) > 10_000:
        raise HTTPException(status_code=422, detail='model inventory exceeds inspection bound')
    result: dict[str, date] = {}
    for raw, day in rows:
        canonical = normalize_model(raw)
        result[canonical] = min(result.get(canonical, day), day)
    return result


@router.get('/api/v1/price-management/catalog')
def management_catalog(actor: PricePrincipal = Depends(get_price_principal),
                       session: Session = Depends(get_session)) -> dict:
    return public_catalog(session, actor.org_id)


@router.get('/api/v1/price-management/missing')
def missing_prices(actor: PricePrincipal = Depends(get_price_principal),
                   session: Session = Depends(get_session)) -> dict:
    org = session.get(Organization, actor.org_id)
    if org is None:
        raise HTTPException(status_code=404, detail='organization not found')
    cutoff = utcnow().astimezone(ZoneInfo(org.default_timezone)).date() - timedelta(days=org.retention_days)
    rows = list(session.scalars(select(DailyUsage).where(
        DailyUsage.org_id == actor.org_id, DailyUsage.usage_date >= cutoff,
        DailyUsage.is_deleted.is_(False), DailyUsage.completeness == 'exact',
        DailyUsage.price_version_id.is_(None), DailyUsage.cost_microunits.is_(None),
        DailyUsage.cost_currency.is_(None)).limit(250_001)))
    if len(rows) > 250_000:
        raise HTTPException(status_code=422, detail='missing-price inventory exceeds inspection bound')
    first = first_seen_dates(session, actor.org_id)
    prices = load_prices(session, actor.org_id)
    groups: dict[str, dict] = {}
    for row in rows:
        name = normalize_model(row.model)
        group = groups.setdefault(name, {'model': name, 'first_seen': first[name].isoformat(),
                                        'unpriced_exact_rows': 0, 'token_total': 0,
                                        'catalog_backfillable_rows': 0})
        group['unpriced_exact_rows'] += 1
        group['token_total'] += row.input_tokens + row.output_tokens + row.cache_read_tokens + row.cache_write_tokens
        if find_price(session, org_id=actor.org_id, tool=row.tool, model=row.model,
                      usage_date=row.usage_date, catalog=prices, public_only=True):
            group['catalog_backfillable_rows'] += 1
    for group in groups.values():
        group['token_total'] = str(group['token_total'])
    return {'models': sorted(groups.values(), key=lambda g: g['model']), 'retention_cutoff': cutoff.isoformat()}


@router.post('/api/v1/price-management/versions')
def import_price(payload: OfficialPriceImport, actor: PricePrincipal = Depends(get_price_principal),
                 session: Session = Depends(get_session)) -> dict:
    org = session.scalar(select(Organization).where(Organization.id == actor.org_id).with_for_update())
    if org is None:
        raise HTTPException(status_code=404, detail='organization not found')
    model = normalize_model(payload.model)
    effective = payload.effective_from
    if effective is None:
        effective = first_seen_dates(session, actor.org_id).get(model)
        if effective is None:
            raise HTTPException(status_code=422, detail='model has no ledger first appearance; supply an official date')
    values = payload.model_dump(exclude={'effective_from'})
    values['model'], values['effective_from'] = model, effective
    candidates = [p for p in load_prices(session, actor.org_id) if normalize_tool(p.tool) == '*'
                  and normalize_model(p.model) == model and p.effective_from == effective]
    if candidates:
        if len(candidates) != 1 or any(getattr(candidates[0], k) != v for k, v in values.items() if k != 'source_checked_at'):
            raise HTTPException(status_code=409, detail='immutable price version conflicts; existing values were not changed')
        price = candidates[0]
        created = False
    else:
        price = PriceVersion(org_id=actor.org_id, created_by_user_id=actor.user_id, **values)
        session.add(price)
        org.price_catalog_revision += 1
        session.flush()
        created = True
    today = utcnow().astimezone(ZoneInfo(org.default_timezone)).date()
    start = today - timedelta(days=org.retention_days)
    # Preview and apply hold one organization lock and transaction. The caller
    # cannot opt into repricing existing rows or widen organization/model scope.
    preview = reprice_usage(session, org_id=actor.org_id, start_date=start,
                            end_date=today + timedelta(days=2), model=model)
    result = reprice_usage(session, org_id=actor.org_id, start_date=start,
        end_date=today + timedelta(days=2), model=model, apply=True,
        expected_ledger_version=preview['ledger_version_before'],
        expected_catalog_fingerprint=preview['catalog_fingerprint'],
        expected_plan_fingerprint=preview['plan_fingerprint'])
    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(status_code=409, detail='price import conflict; retry safely') from exc
    return {'price_version_id': price.id, 'created': created, 'effective_from': effective.isoformat(),
            'effective_basis': price.effective_basis, 'backfill': result,
            'catalog_version': public_catalog(session, actor.org_id)['version']}
