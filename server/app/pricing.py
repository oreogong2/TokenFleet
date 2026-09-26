"""Price lookup and bounded repricing; original usage keys are never rewritten."""
from __future__ import annotations

import hashlib
import json
import re
from collections import defaultdict
from datetime import date, timedelta
from typing import Sequence
from zoneinfo import ZoneInfo

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import DailyUsage, Organization, PriceVersion, utcnow


def normalize_tool(value: str) -> str:
    return value.strip().casefold()


def normalize_model(value: str) -> str:
    """Only proven spelling/presentation variants, never local/private routing.

    Prefixes must identify a recognizable public model family. Arbitrary routers,
    custom-local/local deployments, preview tiers and unknown models stay distinct.
    """
    name = value.strip().casefold().replace('_', '-')
    for prefix in ('anthropic/', 'openai/', 'public/', 'cursor-', 'cb-'):
        if name.startswith(prefix):
            candidate = name[len(prefix):]
            if re.match(r'^(?:gpt-\d|claude-(?:opus|sonnet|haiku|fable|mythos)-\d)', candidate):
                name = candidate
                break
    snapshot = re.search(r'-(20\d{2}-\d{2}-\d{2}|20\d{6})$', name)
    if snapshot:
        stamp = snapshot.group(1)
        try:
            date.fromisoformat(stamp)
        except ValueError:
            pass
        else:
            name = name[:snapshot.start()]
    name = re.sub(r'^(gpt)-(\d+)-(\d+)(?=-|$)', r'\1-\2.\3', name)
    name = re.sub(r'^(claude-(?:opus|sonnet|haiku|fable|mythos))-(\d+)[.-](\d+)$', r'\1-\2.\3', name)
    return name


def load_prices(session: Session, org_id: str) -> list[PriceVersion]:
    return list(session.scalars(select(PriceVersion).where(PriceVersion.org_id == org_id)))


def find_price(
    session: Session, *, org_id: str, tool: str, model: str, usage_date: date,
    catalog: Sequence[PriceVersion] | None = None, public_only: bool = False,
) -> PriceVersion | None:
    prices = catalog if catalog is not None else load_prices(session, org_id)
    matches = [p for p in prices if p.org_id == org_id
               and p.effective_from <= usage_date
               and normalize_model(p.model) == normalize_model(model)
               and (not public_only or p.public_estimate)]
    # A verified official catalog supersedes legacy public estimates for the
    # same model. Private negotiated prices retain their tool-specific scope.
    if any(p.public_estimate and p.source_url and p.source_checked_at and p.effective_basis for p in matches):
        matches = [p for p in matches if not p.public_estimate
                   or (p.source_url and p.source_checked_at and p.effective_basis)]
    for target_tool in (normalize_tool(tool), '*'):
        candidates = [p for p in matches if normalize_tool(p.tool) == target_tool]
        if not candidates:
            continue
        effective = max(p.effective_from for p in candidates)
        newest = [p for p in candidates if p.effective_from == effective]
        # Case/alias-equivalent versions with conflicting rates cannot silently
        # choose a price by insertion order. Operators must resolve the ambiguity.
        rates = {(p.currency, p.input_per_million, p.output_per_million,
                  p.cache_read_per_million, p.cache_write_per_million) for p in newest}
        if len(rates) != 1:
            return None
        return max(newest, key=lambda p: (p.created_at, p.id))
    return None


def catalog_fingerprint(prices: Sequence[PriceVersion]) -> str:
    fields = ('id', 'org_id', 'tool', 'model', 'currency', 'public_estimate',
              'input_per_million', 'output_per_million', 'cache_read_per_million',
              'cache_write_per_million', 'effective_from', 'source_url',
              'source_checked_at', 'effective_basis')
    rows = [{f: str(getattr(p, f)) for f in fields} for p in sorted(prices, key=lambda p: p.id)]
    return hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def reprice_usage(
    session: Session, *, org_id: str, start_date: date, end_date: date,
    model: str | None = None, tool: str | None = None,
    unpriced_only: bool = True, apply: bool = False,
    expected_ledger_version: int | None = None,
    expected_catalog_fingerprint: str | None = None,
    expected_plan_fingerprint: str | None = None,
    max_scan_rows: int = 250_000,
) -> dict[str, object]:
    """Preview/apply public prices only, with the same org lock as ingestion.

    The caller owns commit/rollback. Preview returns no member/device identifiers.
    Weekly backfills use unpriced_only; an explicit historical correction may
    replace a public frozen price, but never a private invoice/negotiated price.
    """
    from .schemas import UsageBucket
    from .services import derived_cost_microunits

    if start_date > end_date or max_scan_rows < 1:
        raise HTTPException(status_code=422, detail='invalid repricing date range or scan bound')
    organization = session.scalar(select(Organization).where(Organization.id == org_id).with_for_update())
    if organization is None:
        raise HTTPException(status_code=404, detail='organization not found')
    prices = load_prices(session, org_id)
    fingerprint = catalog_fingerprint(prices)
    cutoff = utcnow().astimezone(ZoneInfo(organization.default_timezone)).date() - timedelta(days=organization.retention_days)
    scope = {'org_id': org_id, 'start': start_date.isoformat(), 'end': end_date.isoformat(),
             'model': normalize_model(model) if model is not None else None,
             'tool': normalize_tool(tool) if tool is not None else None,
             'unpriced_only': unpriced_only, 'cutoff': cutoff.isoformat(),
             'catalog': fingerprint, 'ledger': organization.ledger_version}
    plan_fingerprint = hashlib.sha256(json.dumps(scope, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if apply and (expected_ledger_version != organization.ledger_version
                  or expected_catalog_fingerprint != fingerprint
                  or expected_plan_fingerprint != plan_fingerprint):
        raise HTTPException(status_code=409, detail='repricing preview is stale; preview again')
    rows = list(session.scalars(select(DailyUsage).where(
        DailyUsage.org_id == org_id,
        DailyUsage.usage_date.between(start_date, end_date),
        DailyUsage.usage_date >= cutoff,
        DailyUsage.is_deleted.is_(False), DailyUsage.completeness == 'exact',
    ).order_by(DailyUsage.id).limit(max_scan_rows + 1)))
    if len(rows) > max_scan_rows:
        raise HTTPException(status_code=422, detail='repricing scope exceeds scan bound; narrow dates')
    by_id = {p.id: p for p in prices}
    before, after = defaultdict(int), defaultdict(int)
    matched = changed = no_price = preserved = 0
    token_total = before_priced_tokens = after_priced_tokens = 0
    changes = []
    for row in rows:
        if model is not None and normalize_model(row.model) != normalize_model(model):
            continue
        if tool is not None and normalize_tool(row.tool) != normalize_tool(tool):
            continue
        old_price = by_id.get(row.price_version_id)
        # Exclude private prices entirely, even if this maintenance request is
        # correcting existing public history.
        if old_price is not None and not old_price.public_estimate:
            preserved += 1
            continue
        matched += 1
        tokens = row.input_tokens + row.output_tokens + row.cache_read_tokens + row.cache_write_tokens
        token_total += tokens
        old_priced = row.cost_microunits is not None and row.cost_currency is not None
        if old_priced:
            before[row.cost_currency] += row.cost_microunits
            before_priced_tokens += tokens
        truly_unpriced = row.price_version_id is None and row.cost_microunits is None and row.cost_currency is None
        if unpriced_only and not truly_unpriced:
            preserved += 1
            if old_priced:
                after[row.cost_currency] += row.cost_microunits
                after_priced_tokens += tokens
            continue
        price = find_price(session, org_id=org_id, tool=row.tool, model=row.model,
                           usage_date=row.usage_date, catalog=prices, public_only=True)
        if price is None:
            no_price += 1
            if old_priced:
                after[row.cost_currency] += row.cost_microunits
                after_priced_tokens += tokens
            continue
        bucket = UsageBucket(date=row.usage_date, timezone=row.timezone,
                             tool=row.tool, model=row.model, source=row.source,
                             input_tokens=row.input_tokens, output_tokens=row.output_tokens,
                             cache_read_tokens=row.cache_read_tokens, cache_write_tokens=row.cache_write_tokens,
                             completeness='exact')
        cost = derived_cost_microunits(bucket, price)
        after[price.currency] += cost
        after_priced_tokens += tokens
        if (row.price_version_id, row.cost_microunits, row.cost_currency) != (price.id, cost, price.currency):
            changed += 1
            changes.append((row, price, cost))
    ledger_before = organization.ledger_version
    if apply and changes:
        now = utcnow()
        for row, price, cost in changes:
            row.price_version_id, row.cost_microunits, row.cost_currency = price.id, cost, price.currency
            row.updated_at = now
        organization.ledger_version += 1
        session.flush()
    return {
        'mode': 'apply' if apply else 'dry-run', 'unpriced_only': unpriced_only,
        'start_date': start_date.isoformat(), 'end_date': end_date.isoformat(),
        'model': model, 'tool': tool, 'scanned_exact_rows': len(rows),
        'matched_rows': matched, 'changed_rows': changed, 'no_price_rows': no_price,
        'preserved_rows': preserved, 'token_total': str(token_total),
        'priced_tokens_before': str(before_priced_tokens), 'priced_tokens_after': str(after_priced_tokens),
        'costs_before_microunits': {k: str(v) for k, v in before.items()},
        'costs_after_microunits': {k: str(v) for k, v in after.items()},
        'ledger_version_before': ledger_before,
        'ledger_version_after': organization.ledger_version,
        'catalog_fingerprint': fingerprint, 'plan_fingerprint': plan_fingerprint,
        'retention_cutoff': cutoff.isoformat(),
    }
