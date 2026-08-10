from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal, DecimalException, ROUND_HALF_UP, localcontext
from zoneinfo import ZoneInfo

from fastapi import HTTPException
from sqlalchemy import func, select, update
from sqlalchemy.dialects.postgresql import insert as postgresql_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.orm import Session

from .models import DailyUsage, Device, Organization, PriceVersion, new_id, utcnow
from .schemas import DailyUsageReport, UsageBucket

USAGE_NATURAL_KEY_COLUMNS = [
    "org_id",
    "user_id",
    "device_id",
    "usage_date",
    "timezone",
    "tool",
    "model",
    "source",
]
INT64_MAX = 9_223_372_036_854_775_807
COMPLETENESS_RANK = {
    "fallback_estimate": 0,
    "legacy_marginal": 1,
    "exact": 2,
}
COST_DECIMAL_PRECISION = 64
COST_OVERFLOW_DETAIL = "derived cost exceeds the supported signed 64-bit range"


def find_price(
    session: Session, *, org_id: str, tool: str, model: str, usage_date
) -> PriceVersion | None:
    return session.scalar(
        select(PriceVersion)
        .where(
            PriceVersion.org_id == org_id,
            PriceVersion.tool == tool,
            PriceVersion.model == model,
            PriceVersion.effective_from <= usage_date,
        )
        .order_by(PriceVersion.effective_from.desc(), PriceVersion.created_at.desc())
        .limit(1)
    )


def derived_cost_microunits(bucket: UsageBucket, price: PriceVersion) -> int:
    # A rate expressed in currency units per million tokens has the same numeric
    # multiplier when the result is expressed in micro-currency units.
    # The schema permits 16-digit token counters and 20-digit rates. Four exact
    # products plus a carry need more than Decimal's default 28-digit context,
    # so use an explicit precision that covers every schema-valid combination.
    try:
        with localcontext() as context:
            context.prec = COST_DECIMAL_PRECISION
            total = (
                Decimal(bucket.input_tokens) * price.input_per_million
                + Decimal(bucket.output_tokens) * price.output_per_million
                + Decimal(bucket.cache_read_tokens) * price.cache_read_per_million
                + Decimal(bucket.cache_write_tokens) * price.cache_write_per_million
            )
            rounded_decimal = total.to_integral_value(rounding=ROUND_HALF_UP)
    except DecimalException as exc:
        raise HTTPException(
            status_code=422,
            detail="derived cost cannot be represented safely",
        ) from exc
    if not rounded_decimal.is_finite() or rounded_decimal > Decimal(INT64_MAX):
        raise HTTPException(
            status_code=422,
            detail=COST_OVERFLOW_DETAIL,
        )
    return int(rounded_decimal)


def _natural_key_predicate(
    *, org_id: str, user_id: str, device_id: str, bucket: UsageBucket
):
    return (
        DailyUsage.org_id == org_id,
        DailyUsage.user_id == user_id,
        DailyUsage.device_id == device_id,
        DailyUsage.usage_date == bucket.date,
        DailyUsage.timezone == bucket.timezone,
        DailyUsage.tool == bucket.tool,
        DailyUsage.model == bucket.model,
        DailyUsage.source == bucket.source,
    )


def _mutable_state(values: dict[str, object]) -> tuple[object, ...]:
    return (
        values["input_tokens"],
        values["output_tokens"],
        values["cache_read_tokens"],
        values["cache_write_tokens"],
        values["is_deleted"],
        values["report_schema_version"],
        values["collector_version"],
        values["completeness"],
        values["price_version_id"],
        values["cost_microunits"],
        values["cost_currency"],
    )


def _existing_mutable_state(existing: DailyUsage) -> tuple[object, ...]:
    return (
        existing.input_tokens,
        existing.output_tokens,
        existing.cache_read_tokens,
        existing.cache_write_tokens,
        existing.is_deleted,
        existing.report_schema_version,
        existing.collector_version,
        existing.completeness,
        existing.price_version_id,
        existing.cost_microunits,
        existing.cost_currency,
    )


def _utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _insert_usage_if_absent(session: Session, values: dict[str, object]) -> str | None:
    dialect = session.get_bind().dialect.name
    if dialect == "sqlite":
        statement = sqlite_insert(DailyUsage).values(**values)
        statement = statement.on_conflict_do_nothing(
            index_elements=USAGE_NATURAL_KEY_COLUMNS
        )
    elif dialect == "postgresql":
        statement = postgresql_insert(DailyUsage).values(**values)
        statement = statement.on_conflict_do_nothing(
            index_elements=USAGE_NATURAL_KEY_COLUMNS
        )
    else:
        raise RuntimeError(f"unsupported database dialect for atomic upsert: {dialect}")
    return session.scalar(statement.returning(DailyUsage.id))


def _values_for_bucket(
    *,
    device: Device,
    report: DailyUsageReport,
    bucket: UsageBucket,
    price: PriceVersion | None,
    now: datetime,
) -> dict[str, object]:
    return {
        "id": new_id(),
        "org_id": device.org_id,
        "user_id": device.user_id,
        "device_id": device.id,
        "usage_date": bucket.date,
        "timezone": bucket.timezone,
        "tool": bucket.tool,
        "model": bucket.model,
        "source": bucket.source,
        "is_deleted": bucket.deleted,
        "completeness": bucket.completeness,
        "input_tokens": bucket.input_tokens,
        "output_tokens": bucket.output_tokens,
        "cache_read_tokens": bucket.cache_read_tokens,
        "cache_write_tokens": bucket.cache_write_tokens,
        "report_schema_version": report.schema_version,
        "collector_version": report.collector_version,
        "reported_generated_at": _utc(report.generated_at),
        "price_version_id": price.id if price else None,
        "cost_microunits": (
            derived_cost_microunits(bucket, price)
            if price is not None and not bucket.deleted
            else None
        ),
        "cost_currency": (
            price.currency if price is not None and not bucket.deleted else None
        ),
        "created_at": now,
        "updated_at": now,
    }


def ingest_daily_usage(
    session: Session,
    *,
    device: Device,
    report: DailyUsageReport,
    max_rows_per_device: int,
    max_rows_per_org: int,
) -> tuple[int, int, int, int]:
    if max_rows_per_device < 1 or max_rows_per_org < 1:
        raise ValueError("usage row quotas must be positive")
    created = 0
    updated = 0
    unchanged = 0
    inserted_rows = 0
    now = utcnow()
    organization = session.scalar(
        select(Organization)
        .where(Organization.id == device.org_id)
        .with_for_update()
    )
    if organization is None:  # pragma: no cover - protected by foreign keys
        raise RuntimeError("device organization disappeared during ingestion")
    locked_device = session.scalar(
        select(Device)
        .where(Device.id == device.id, Device.org_id == organization.id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if locked_device is None:  # pragma: no cover - protected by foreign keys
        raise RuntimeError("device disappeared during ingestion")
    device = locked_device
    existing_device_rows = session.scalar(
        select(func.count())
        .select_from(DailyUsage)
        .where(DailyUsage.device_id == device.id)
    ) or 0
    existing_org_rows = session.scalar(
        select(func.count())
        .select_from(DailyUsage)
        .where(DailyUsage.org_id == device.org_id)
    ) or 0
    device_row_capacity = max(max_rows_per_device - existing_device_rows, 0)
    org_row_capacity = max(max_rows_per_org - existing_org_rows, 0)

    def enforce_row_quota() -> None:
        scope: str | None = None
        if inserted_rows > device_row_capacity:
            scope = "device"
        elif inserted_rows > org_row_capacity:
            scope = "organization"
        if scope is None:
            return
        # Every insert and update in this report is part of this transaction.
        # Explicit rollback guarantees no partial usage, ledger-version, or
        # last-successful-sync effects escape a quota rejection.
        session.rollback()
        raise HTTPException(
            status_code=422,
            detail={
                "code": "usage_row_quota_exceeded",
                "scope": scope,
                "message": (
                    "the report would add natural keys beyond the configured "
                    f"{scope} usage-row quota"
                ),
            },
        )

    retention_cutoff = now.astimezone(
        ZoneInfo(organization.default_timezone)
    ).date() - timedelta(days=organization.retention_days)

    # A stable lock order avoids deadlocks when PostgreSQL receives overlapping
    # batches whose clients happened to serialize buckets differently.
    buckets = sorted(
        report.buckets,
        key=lambda bucket: (
            bucket.date,
            bucket.timezone,
            bucket.tool,
            bucket.model,
            bucket.source,
        ),
    )
    for bucket in buckets:
        if bucket.date < retention_cutoff:
            # Retention is enforced at write time as well as by the purge job.
            # A force sync must never recreate history already outside policy.
            unchanged += 1
            continue
        new_price = (
            find_price(
                session,
                org_id=device.org_id,
                tool=bucket.tool,
                model=bucket.model,
                usage_date=bucket.date,
            )
            if bucket.completeness == "exact" and not bucket.deleted
            else None
        )
        new_values = _values_for_bucket(
            device=device,
            report=report,
            bucket=bucket,
            price=new_price,
            now=now,
        )
        inserted_id = _insert_usage_if_absent(session, new_values)
        if inserted_id is not None:
            inserted_rows += 1
            enforce_row_quota()
            if bucket.deleted:
                # A marker is a persisted version change even when no visible
                # row preceded it. It must block older offline snapshots.
                updated += 1
            else:
                created += 1
            continue

        existing = session.scalar(
            select(DailyUsage)
            .where(
                *_natural_key_predicate(
                    org_id=device.org_id,
                    user_id=device.user_id,
                    device_id=device.id,
                    bucket=bucket,
                )
            )
            .with_for_update()
        )
        if existing is None:  # pragma: no cover - defensive against external deletes
            raise RuntimeError("usage row disappeared during conflict resolution")
        incoming_generated_at = _utc(report.generated_at)
        existing_generated_at = _utc(existing.reported_generated_at)
        existing_quality = COMPLETENESS_RANK[existing.completeness]
        incoming_quality = COMPLETENESS_RANK[bucket.completeness]
        marker_version_advance = False

        if existing.is_deleted or bucket.deleted:
            if existing.is_deleted and bucket.deleted:
                # Marker versions are strictly ordered by generated_at.
                if incoming_generated_at <= existing_generated_at:
                    unchanged += 1
                    continue
                marker_version_advance = True
            elif bucket.deleted:
                # An older marker cannot erase a newer visible snapshot; at an
                # equal timestamp the tombstone wins deterministically.
                if incoming_generated_at < existing_generated_at:
                    unchanged += 1
                    continue
            else:
                # Resurrection is explicit: it must be an exact snapshot whose
                # version is strictly newer than the persisted marker.
                if (
                    bucket.completeness != "exact"
                    or incoming_generated_at <= existing_generated_at
                ):
                    unchanged += 1
                    continue
        elif incoming_quality < existing_quality:
            # Quality is the primary version dimension for two visible rows. A
            # newer estimate must never erase a more trustworthy exact row.
            unchanged += 1
            continue

        quality_upgrade = incoming_quality > existing_quality
        if (
            not existing.is_deleted
            and not bucket.deleted
            and not quality_upgrade
            and incoming_generated_at < existing_generated_at
        ):
            unchanged += 1
            continue
        if bucket.deleted:
            price = (
                session.scalar(
                    select(PriceVersion).where(
                        PriceVersion.id == existing.price_version_id,
                        PriceVersion.org_id == device.org_id,
                    )
                )
                if existing.price_version_id is not None
                else None
            )
        elif bucket.completeness != "exact":
            price = None
        elif existing.price_version_id is not None:
            price = session.scalar(
                select(PriceVersion).where(
                    PriceVersion.id == existing.price_version_id,
                    PriceVersion.org_id == device.org_id,
                )
            )
        elif existing.is_deleted:
            # A marker with no frozen price may represent an absent row or a
            # previously unpriced exact row. Keep it unpriced rather than using
            # delete/resurrect as an implicit historical repricing workflow.
            price = None
        elif existing.completeness != "exact":
            # A non-exact bucket is intentionally unpriced. Its later exact
            # replacement may select the effective price at that point.
            price = new_price
        else:
            # An unpriced historical bucket remains unpriced until an explicit
            # repricing workflow is introduced.
            price = None
        values = _values_for_bucket(
            device=device,
            report=report,
            bucket=bucket,
            price=price,
            now=now,
        )
        existing_state = _existing_mutable_state(existing)
        incoming_state = _mutable_state(values)
        if (
            not existing.is_deleted
            and not bucket.deleted
            and not quality_upgrade
            and incoming_generated_at == existing_generated_at
            and (
                existing_state != incoming_state
            )
        ):
            raise HTTPException(
                status_code=409,
                detail=(
                    "a different snapshot already exists for this natural key "
                    "and generated_at"
                ),
            )
        if existing_state == incoming_state:
            if incoming_generated_at > _utc(existing.reported_generated_at):
                # Full-write even when token values are unchanged. Holding the
                # row lock makes the timestamp and snapshot one atomic state.
                for key, value in values.items():
                    if key not in {
                        "id",
                        "org_id",
                        "user_id",
                        "device_id",
                        "usage_date",
                        "timezone",
                        "tool",
                        "model",
                        "source",
                        "created_at",
                    }:
                        setattr(existing, key, value)
            if marker_version_advance:
                updated += 1
            else:
                unchanged += 1
        else:
            for key in (
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "is_deleted",
                "report_schema_version",
                "collector_version",
                "completeness",
                "reported_generated_at",
                "price_version_id",
                "cost_microunits",
                "cost_currency",
                "updated_at",
            ):
                setattr(existing, key, values[key])
            updated += 1

    if created or updated:
        session.execute(
            update(Organization)
            .where(Organization.id == device.org_id)
            .values(ledger_version=Organization.ledger_version + 1)
        )
    device.collector_version = report.collector_version
    device.last_successful_sync_at = utcnow()
    session.commit()
    ledger_version = session.scalar(
        select(Organization.ledger_version).where(Organization.id == device.org_id)
    )
    if ledger_version is None:
        raise RuntimeError("device organization disappeared during ingestion")
    return created, updated, unchanged, ledger_version
