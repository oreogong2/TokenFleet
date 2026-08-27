from __future__ import annotations

from collections import OrderedDict, defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta
import threading
import time
from typing import Hashable, Iterable, TypeVar
from zoneinfo import ZoneInfo

from fastapi import HTTPException
from sqlalchemy import Numeric, Select, and_, case, cast, func, literal, select
from sqlalchemy.orm import Session

from .models import DailyUsage, Organization, PriceVersion, User, UserRole, utcnow
from .schemas import (
    DeviceCommunityRankResponse,
    PublicDailyTrendItem,
    PublicDistributionItem,
    PublicLeaderboardEntry,
    PublicLeaderboardResponse,
    PublicMemberDetailResponse,
    PublicMetric,
    PublicPeriod,
    PublicUsageTotals,
    validate_public_nickname,
)

PUBLIC_DISTRIBUTION_LIMIT = 100
PUBLIC_SCAN_LIMIT_CODE = "public_projection_scan_limit_exceeded"
MIXED_TIMEZONE_WARNING = (
    "Daily usage uses device-local date buckets and has not been recalculated "
    "across time zones."
)
METRIC_DEFINITIONS = {
    "tokens": (
        "input_tokens + output_tokens + cache_read_tokens + "
        "cache_write_tokens"
    ),
    "norm": "input_tokens + output_tokens",
    "cost": (
        "fully priced estimated cost in one currency, expressed in microunits; "
        "null when any matching bucket is unpriced or currencies are mixed"
    ),
}
PublicProjectionResponse = PublicLeaderboardResponse | PublicMemberDetailResponse
ResponseT = TypeVar("ResponseT", bound=PublicProjectionResponse)


@dataclass(frozen=True, slots=True)
class _CachedProjection:
    expires_at: float
    response: PublicProjectionResponse


class PublicProjectionCache:
    """Small process-local TTL cache keyed by the durable ledger version."""

    def __init__(self, *, ttl_seconds: int, max_entries: int) -> None:
        self.ttl_seconds = ttl_seconds
        self.max_entries = max_entries
        self._entries: OrderedDict[Hashable, _CachedProjection] = OrderedDict()
        self._lock = threading.Lock()

    def get(self, key: Hashable, response_type: type[ResponseT]) -> ResponseT | None:
        now = time.monotonic()
        with self._lock:
            cached = self._entries.pop(key, None)
            if cached is None:
                return None
            if cached.expires_at <= now:
                return None
            self._entries[key] = cached
            if not isinstance(cached.response, response_type):
                return None
            return cached.response

    def put(self, key: Hashable, response: PublicProjectionResponse) -> None:
        with self._lock:
            self._entries.pop(key, None)
            self._entries[key] = _CachedProjection(
                expires_at=time.monotonic() + self.ttl_seconds,
                response=response,
            )
            while len(self._entries) > self.max_entries:
                self._entries.popitem(last=False)


class _SQLiteExactIntegerSum:
    """SQLite aggregate that never overflows signed 64-bit SUM()."""

    def __init__(self) -> None:
        self.total = 0

    def step(self, value: object | None) -> None:
        if value is not None:
            self.total += int(value)

    def finalize(self) -> str:
        return str(self.total)


@dataclass(slots=True)
class UsageAggregate:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    costs: dict[str, int] = field(default_factory=lambda: defaultdict(int))
    unpriced: bool = False
    first_timezone: str | None = None
    mixed_timezones: bool = False

    @property
    def norm_tokens(self) -> int:
        # Product contract: cache reads/writes never contribute to norm.
        return self.input_tokens + self.output_tokens

    @property
    def total_tokens(self) -> int:
        return (
            self.input_tokens
            + self.output_tokens
            + self.cache_read_tokens
            + self.cache_write_tokens
        )

    @property
    def mixed_currency(self) -> bool:
        return len(self.costs) > 1

    def add_group(self, row) -> None:
        self.input_tokens += int(row.input_tokens or 0)
        self.output_tokens += int(row.output_tokens or 0)
        self.cache_read_tokens += int(row.cache_read_tokens or 0)
        self.cache_write_tokens += int(row.cache_write_tokens or 0)
        self._add_timezone(row.first_timezone)
        self._add_timezone(row.last_timezone)
        if bool(row.unpriced):
            self.unpriced = True
        elif row.cost_currency is not None:
            self.costs[str(row.cost_currency)] += int(row.cost_microunits or 0)

    def _add_timezone(self, raw_value: str | None) -> None:
        if raw_value is None:
            return
        timezone_name = str(raw_value)
        if self.first_timezone is None:
            self.first_timezone = timezone_name
        elif timezone_name != self.first_timezone:
            self.mixed_timezones = True

    def comparable_cost(self) -> tuple[str, int] | None:
        if self.unpriced or self.mixed_currency or len(self.costs) != 1:
            return None
        return next(iter(self.costs.items()))

    def as_response(self) -> PublicUsageTotals:
        comparable_cost = self.comparable_cost()
        return PublicUsageTotals(
            input_tokens=str(self.input_tokens),
            output_tokens=str(self.output_tokens),
            cache_read_tokens=str(self.cache_read_tokens),
            cache_write_tokens=str(self.cache_write_tokens),
            norm_tokens=str(self.norm_tokens),
            total_tokens=str(self.total_tokens),
            estimated_cost_microunits=(
                str(comparable_cost[1]) if comparable_cost is not None else None
            ),
            cost_currency=(
                comparable_cost[0] if comparable_cost is not None else None
            ),
            unpriced=self.unpriced,
            mixed_currency=self.mixed_currency,
        )


@dataclass(slots=True)
class TimezoneAggregate:
    first_timezone: str | None = None
    mixed_timezones: bool = False

    def add(self, timezone_name: str) -> None:
        if self.first_timezone is None:
            self.first_timezone = timezone_name
        elif timezone_name != self.first_timezone:
            self.mixed_timezones = True


@dataclass(slots=True)
class MemberAggregate:
    public_id: str
    nickname: str
    usage: UsageAggregate = field(default_factory=UsageAggregate)
    tools: dict[str, UsageAggregate] = field(default_factory=dict)
    models: dict[str, UsageAggregate] = field(default_factory=dict)
    model_labels: dict[str, str] = field(default_factory=dict, repr=False)


def resolve_public_organization(
    session: Session, public_org_slug: str
) -> Organization:
    configured_slug = public_org_slug.strip()
    if not configured_slug:
        raise HTTPException(status_code=404, detail="public leaderboard not found")
    organizations = list(
        session.scalars(
            select(Organization)
            .where(Organization.slug == configured_slug)
            .limit(2)
        )
    )
    if len(organizations) != 1:
        raise HTTPException(status_code=404, detail="public leaderboard not found")
    return organizations[0]


def period_bounds(
    organization: Organization, period: PublicPeriod
) -> tuple[date | None, date]:
    today = utcnow().astimezone(ZoneInfo(organization.default_timezone)).date()
    if period == "all":
        return None, today
    if period == "yesterday":
        yesterday = today - timedelta(days=1)
        return yesterday, yesterday
    days = {
        "today": 1,
        "3d": 3,
        "7d": 7,
        "30d": 30,
        "90d": 90,
    }[period]
    return today - timedelta(days=days - 1), today


def _base_public_usage_query(
    *,
    organization: Organization,
    start_date: date | None,
    end_date: date,
    tool: str | None,
    model: str | None,
    public_id: str | None = None,
) -> Select:
    query = (
        select(
            User.public_id.label("public_id"),
            User.display_name.label("nickname"),
            DailyUsage.usage_date,
            DailyUsage.timezone,
            DailyUsage.tool,
            DailyUsage.model,
            DailyUsage.input_tokens,
            DailyUsage.output_tokens,
            DailyUsage.cache_read_tokens,
            DailyUsage.cache_write_tokens,
            DailyUsage.cost_microunits,
            DailyUsage.cost_currency,
            PriceVersion.public_estimate,
        )
        .join(
            User,
            (User.id == DailyUsage.user_id)
            & (User.org_id == DailyUsage.org_id),
        )
        .outerjoin(
            PriceVersion,
            (PriceVersion.id == DailyUsage.price_version_id)
            & (PriceVersion.org_id == DailyUsage.org_id),
        )
        .where(
            DailyUsage.org_id == organization.id,
            User.org_id == organization.id,
            User.role == UserRole.MEMBER,
            User.is_active.is_(True),
            User.public_profile_enabled.is_(True),
            User.display_name.is_not(None),
            DailyUsage.is_deleted.is_(False),
            DailyUsage.completeness == "exact",
            DailyUsage.usage_date <= end_date,
        )
    )
    if start_date is not None:
        query = query.where(DailyUsage.usage_date >= start_date)
    if tool is not None:
        query = query.where(DailyUsage.tool == tool)
    if model is not None:
        query = query.where(_model_matches(model))
    if public_id is not None:
        query = query.where(User.public_id == public_id)
    return query


def _safe_nickname(raw_value: str | None) -> str | None:
    if raw_value is None:
        return None
    value = raw_value.strip()
    if not value:
        return None
    try:
        return validate_public_nickname(value)
    except ValueError:
        # Database corruption or legacy unsafe names fail closed rather than
        # crossing the anonymous boundary.
        return None


def _enforce_scan_limit(
    session: Session, query: Select, max_scan_rows: int
) -> None:
    # Bound the count itself so an anonymous `period=all` request cannot consume
    # the entire unfiltered public candidate scope merely to learn that the
    # response limit was exceeded.
    bounded_rows = (
        query.with_only_columns(literal(1), maintain_column_froms=True)
        .order_by(None)
        .limit(max_scan_rows + 1)
        .subquery()
    )
    row_count = session.scalar(
        select(func.count()).select_from(bounded_rows)
    ) or 0
    if row_count > max_scan_rows:
        raise HTTPException(
            status_code=503,
            detail={
                "code": PUBLIC_SCAN_LIMIT_CODE,
                "message": (
                    "public projection is temporarily unavailable for this "
                    "period; use a shorter period"
                ),
            },
        )


def _exact_sum(session: Session, expression):
    """Return a database aggregate with exact integer semantics on both backends."""

    bind = session.get_bind()
    if bind.dialect.name == "sqlite":
        connection = session.connection().connection.driver_connection
        connection.create_aggregate(
            "tokenfleet_exact_integer_sum", 1, _SQLiteExactIntegerSum
        )
        return func.tokenfleet_exact_integer_sum(expression)
    # PostgreSQL SUM(bigint) already returns NUMERIC. The explicit cast also
    # documents and locks the precision contract for future supported engines.
    return func.sum(cast(expression, Numeric(38, 0)))


def _grouped_usage_query(
    session: Session,
    query: Select,
    *,
    dimensions: tuple[object, ...],
) -> Select:
    public_cost = and_(
        PriceVersion.public_estimate.is_(True),
        DailyUsage.cost_microunits.is_not(None),
        DailyUsage.cost_currency.is_not(None),
    )
    grouped_currency = case(
        (public_cost, DailyUsage.cost_currency),
        else_=None,
    )
    grouped_cost = case(
        (public_cost, DailyUsage.cost_microunits),
        else_=0,
    )
    return (
        query.with_only_columns(
            *dimensions,
            _exact_sum(session, DailyUsage.input_tokens).label("input_tokens"),
            _exact_sum(session, DailyUsage.output_tokens).label("output_tokens"),
            _exact_sum(session, DailyUsage.cache_read_tokens).label(
                "cache_read_tokens"
            ),
            _exact_sum(session, DailyUsage.cache_write_tokens).label(
                "cache_write_tokens"
            ),
            func.min(DailyUsage.timezone).label("first_timezone"),
            func.max(DailyUsage.timezone).label("last_timezone"),
            grouped_currency.label("cost_currency"),
            _exact_sum(session, grouped_cost).label("cost_microunits"),
            func.max(case((public_cost, 0), else_=1)).label("unpriced"),
            maintain_column_froms=True,
        )
        .order_by(None)
        .group_by(*dimensions, grouped_currency)
    )


def _preflight_cost_currency(
    session: Session,
    query: Select,
    metric: PublicMetric,
) -> None:
    if metric != "cost":
        return
    public_cost = and_(
        PriceVersion.public_estimate.is_(True),
        DailyUsage.cost_microunits.is_not(None),
        DailyUsage.cost_currency.is_not(None),
    )
    comparable_members = (
        query.with_only_columns(
            User.public_id,
            func.min(DailyUsage.cost_currency).label("cost_currency"),
            maintain_column_froms=True,
        )
        .order_by(None)
        .group_by(User.public_id)
        .having(func.max(case((public_cost, 0), else_=1)) == 0)
        .having(func.count(func.distinct(DailyUsage.cost_currency)) == 1)
        .subquery()
    )
    currencies = list(
        session.scalars(
            select(comparable_members.c.cost_currency)
            .distinct()
            .limit(2)
        )
    )
    if len(currencies) > 1:
        raise HTTPException(
            status_code=422,
            detail=(
                "metric=cost requires one currency across all fully priced "
                "matching members"
            ),
        )


def _most_recent_daily_scope(query: Select) -> Select:
    recent_dates = (
        query.with_only_columns(
            DailyUsage.usage_date,
            maintain_column_froms=True,
        )
        .order_by(None)
        .distinct()
        .order_by(DailyUsage.usage_date.desc())
        .limit(PUBLIC_DISTRIBUTION_LIMIT)
        .subquery()
    )
    selected_date = next(iter(recent_dates.c))
    return query.where(DailyUsage.usage_date.in_(select(selected_date)))


def _member_aggregates(
    session: Session, query: Select
) -> dict[str, MemberAggregate]:
    members: dict[str, MemberAggregate] = {}
    grouped_query = _grouped_usage_query(
        session,
        query,
        dimensions=(
            User.public_id,
            User.display_name,
            DailyUsage.tool,
            DailyUsage.model,
        ),
    )
    for row in session.execute(grouped_query):
        nickname = _safe_nickname(row.display_name)
        if nickname is None:
            continue
        public_id = str(row.public_id)
        member = members.setdefault(
            public_id,
            MemberAggregate(public_id=public_id, nickname=nickname),
        )
        member.usage.add_group(row)
        tool_name = str(row.tool)
        model_name = str(row.model)
        member.tools.setdefault(tool_name, UsageAggregate()).add_group(row)
        _add_case_insensitive_group(
            member.models,
            member.model_labels,
            model_name,
            row,
        )
    return members


def _model_matches(model: str):
    """Match public model filters without splitting provider casing variants."""

    return func.lower(DailyUsage.model) == model.lower()


def _add_case_insensitive_group(
    aggregates: dict[str, UsageAggregate],
    labels: dict[str, str],
    raw_label: str,
    row,
) -> None:
    identity = raw_label.casefold()
    display_label = labels.get(identity)
    if display_label is None:
        display_label = raw_label
        labels[identity] = display_label
        aggregates[display_label] = UsageAggregate()
    elif raw_label < display_label:
        aggregate = aggregates.pop(display_label)
        display_label = raw_label
        labels[identity] = display_label
        aggregates[display_label] = aggregate
    aggregates[display_label].add_group(row)


def _primary_usage(
    aggregates: dict[str, UsageAggregate],
) -> tuple[str | None, int | None]:
    if not aggregates:
        return None, None
    name, usage = min(
        aggregates.items(),
        key=lambda item: (
            -item[1].total_tokens,
            item[0].casefold(),
            item[0],
        ),
    )
    return name, usage.total_tokens


def _distribution_aggregates(
    session: Session,
    query: Select,
    *,
    dimension,
    case_insensitive: bool = False,
) -> dict[object, UsageAggregate]:
    aggregates: dict[object, UsageAggregate] = {}
    casefolded_aggregates: dict[str, UsageAggregate] = {}
    labels: dict[str, str] = {}
    grouped_query = _grouped_usage_query(
        session,
        query,
        dimensions=(dimension,),
    )
    for row in session.execute(grouped_query):
        dimension_value = row[0]
        if case_insensitive:
            _add_case_insensitive_group(
                casefolded_aggregates,
                labels,
                str(dimension_value),
                row,
            )
        else:
            aggregate = aggregates.setdefault(dimension_value, UsageAggregate())
            aggregate.add_group(row)
    return casefolded_aggregates if case_insensitive else aggregates


def _available_labels(
    session: Session,
    public_scope_query: Select,
    *,
    dimension,
    max_scan_rows: int,
    case_insensitive: bool = False,
) -> list[str]:
    bounded_labels = (
        public_scope_query.with_only_columns(
            dimension,
            maintain_column_froms=True,
        )
        .order_by(None)
        .limit(max_scan_rows)
        .subquery()
    )
    label_column = next(iter(bounded_labels.c))
    distinct_labels = select(label_column).distinct().subquery()
    distinct_label_column = next(iter(distinct_labels.c))
    labels = list(
        session.scalars(
            select(distinct_label_column)
            .order_by(
                func.lower(distinct_label_column),
                distinct_label_column,
            )
            .limit(PUBLIC_DISTRIBUTION_LIMIT)
        )
    )
    if not case_insensitive:
        return labels
    preferred: dict[str, str] = {}
    for label in labels:
        identity = label.casefold()
        current = preferred.get(identity)
        if current is None or label < current:
            preferred[identity] = label
    return sorted(preferred.values(), key=lambda label: (label.casefold(), label))


def _metric_value(aggregate: UsageAggregate, metric: PublicMetric) -> int | None:
    if metric == "tokens":
        return aggregate.total_tokens
    if metric == "norm":
        return aggregate.norm_tokens
    comparable_cost = aggregate.comparable_cost()
    return comparable_cost[1] if comparable_cost is not None else None


def _metric_currency(
    aggregates: Iterable[UsageAggregate], metric: PublicMetric
) -> str | None:
    if metric != "cost":
        return None
    currencies = {
        cost[0]
        for aggregate in aggregates
        if (cost := aggregate.comparable_cost()) is not None
    }
    if len(currencies) > 1:
        raise HTTPException(
            status_code=422,
            detail=(
                "metric=cost requires one currency across all fully priced "
                "matching members"
            ),
        )
    return next(iter(currencies)) if currencies else None


def _stable_metric_sort_key(
    aggregate: UsageAggregate,
    metric: PublicMetric,
    *,
    nickname: str,
    public_id: str,
) -> tuple[object, ...]:
    value = _metric_value(aggregate, metric)
    return (
        value is None,
        -(value or 0),
        nickname.casefold(),
        nickname,
        public_id,
    )


def _ordered_members(
    members: Iterable[MemberAggregate], metric: PublicMetric
) -> list[MemberAggregate]:
    return sorted(
        members,
        key=lambda item: _stable_metric_sort_key(
            item.usage,
            metric,
            nickname=item.nickname,
            public_id=item.public_id,
        ),
    )


def _member_rank(
    ordered: Iterable[MemberAggregate],
    metric: PublicMetric,
    public_id: str,
) -> int | None:
    ranked_position = 0
    for member in ordered:
        value = _metric_value(member.usage, metric)
        if value is None:
            continue
        ranked_position += 1
        if member.public_id == public_id:
            return ranked_position
    return None


def build_public_leaderboard(
    session: Session,
    *,
    organization: Organization,
    period: PublicPeriod,
    metric: PublicMetric,
    tool: str | None,
    model: str | None,
    limit: int,
    max_scan_rows: int,
) -> PublicLeaderboardResponse:
    start_date, end_date = period_bounds(organization, period)
    public_scope_query = _base_public_usage_query(
        organization=organization,
        start_date=start_date,
        end_date=end_date,
        tool=None,
        model=None,
    )
    query = public_scope_query
    if tool is not None:
        query = query.where(DailyUsage.tool == tool)
    if model is not None:
        query = query.where(_model_matches(model))
    # Enforce the budget before caller-controlled tool/model filters. Otherwise
    # a missing or rare label can match zero rows while still forcing the database
    # to walk the entire public period to prove that result.
    _enforce_scan_limit(session, public_scope_query, max_scan_rows)
    _preflight_cost_currency(session, query, metric)
    # Discovery stays independent of the active tool/model filters and executes
    # as DISTINCT SQL over the complete scope admitted by the hard row budget.
    available_tools = _available_labels(
        session,
        public_scope_query,
        dimension=DailyUsage.tool,
        max_scan_rows=max_scan_rows,
    )
    available_models = _available_labels(
        session,
        public_scope_query,
        dimension=DailyUsage.model,
        max_scan_rows=max_scan_rows,
        case_insensitive=True,
    )
    members = _member_aggregates(session, query)
    response_timezones = TimezoneAggregate()
    for member in members.values():
        if member.usage.first_timezone is not None:
            response_timezones.add(member.usage.first_timezone)
        if member.usage.mixed_timezones:
            response_timezones.mixed_timezones = True

    ordered = _ordered_members(members.values(), metric)
    metric_currency = _metric_currency(
        (member.usage for member in ordered), metric
    )
    entries: list[PublicLeaderboardEntry] = []
    ranked_position = 0
    for member in ordered[:limit]:
        value = _metric_value(member.usage, metric)
        primary_tool, primary_tool_tokens = _primary_usage(member.tools)
        primary_model, primary_model_tokens = _primary_usage(member.models)
        rank = None
        if value is not None:
            ranked_position += 1
            rank = ranked_position
        entries.append(
            PublicLeaderboardEntry(
                rank=rank,
                public_id=member.public_id,
                nickname=member.nickname,
                metric_value=str(value) if value is not None else None,
                primary_tool=primary_tool,
                primary_tool_tokens=(
                    str(primary_tool_tokens)
                    if primary_tool_tokens is not None
                    else None
                ),
                tool_count=len(member.tools),
                primary_model=primary_model,
                primary_model_tokens=(
                    str(primary_model_tokens)
                    if primary_model_tokens is not None
                    else None
                ),
                model_count=len(member.models),
                totals=member.usage.as_response(),
            )
        )
    return PublicLeaderboardResponse(
        period=period,
        metric=metric,
        metric_definition=METRIC_DEFINITIONS[metric],
        metric_currency=metric_currency,
        tool=tool,
        model=model,
        timezone=organization.default_timezone,
        mixed_timezones=response_timezones.mixed_timezones,
        timezone_warning=(
            MIXED_TIMEZONE_WARNING if response_timezones.mixed_timezones else None
        ),
        start_date=start_date,
        end_date=end_date,
        available_tools=available_tools,
        available_models=available_models,
        total_entries=len(ordered),
        entries=entries,
    )


def build_device_community_rank(
    session: Session,
    *,
    organization: Organization,
    user: User,
    max_scan_rows: int,
) -> DeviceCommunityRankResponse:
    """Return only an authenticated member's public ranking context."""
    start_date, end_date = period_bounds(organization, "today")
    query = _base_public_usage_query(
        organization=organization,
        start_date=start_date,
        end_date=end_date,
        tool=None,
        model=None,
    )
    _enforce_scan_limit(session, query, max_scan_rows)
    members = _member_aggregates(session, query)
    ordered = _ordered_members(members.values(), "tokens")
    nickname = (
        _safe_nickname(user.display_name)
        if user.public_profile_enabled
        else None
    )
    target = members.get(user.public_id) if nickname is not None else None
    metric_value = target.usage.total_tokens if target is not None else None
    primary_tool, _ = _primary_usage(target.tools) if target is not None else (None, None)
    primary_model, _ = _primary_usage(target.models) if target is not None else (None, None)
    return DeviceCommunityRankResponse(
        public_id=user.public_id,
        nickname=nickname,
        public_profile_enabled=nickname is not None,
        rank=(
            _member_rank(ordered, "tokens", user.public_id)
            if target is not None
            else None
        ),
        total_entries=len(ordered),
        metric_value=str(metric_value) if metric_value is not None else None,
        primary_tool=primary_tool,
        primary_model=primary_model,
        totals=target.usage.as_response() if target is not None else None,
    )


def _ordered_distribution(
    distribution: dict[str, UsageAggregate], metric: PublicMetric
) -> list[PublicDistributionItem]:
    ordered = sorted(
        distribution.items(),
        key=lambda item: _stable_metric_sort_key(
            item[1], metric, nickname=item[0], public_id=item[0]
        ),
    )
    return [
        PublicDistributionItem(name=name, totals=aggregate.as_response())
        for name, aggregate in ordered[:PUBLIC_DISTRIBUTION_LIMIT]
    ]


def build_public_member_detail(
    session: Session,
    *,
    organization: Organization,
    public_id: str,
    period: PublicPeriod,
    metric: PublicMetric,
    tool: str | None,
    model: str | None,
    max_scan_rows: int,
) -> PublicMemberDetailResponse:
    public_user = session.execute(
        select(User.public_id, User.display_name).where(
            User.org_id == organization.id,
            User.public_id == public_id,
            User.role == UserRole.MEMBER,
            User.is_active.is_(True),
            User.public_profile_enabled.is_(True),
        )
    ).one_or_none()
    if public_user is None:
        raise HTTPException(status_code=404, detail="public profile not found")
    nickname = _safe_nickname(public_user.display_name)
    if nickname is None:
        raise HTTPException(status_code=404, detail="public profile not found")

    start_date, end_date = period_bounds(organization, period)
    public_scope_query = _base_public_usage_query(
        organization=organization,
        start_date=start_date,
        end_date=end_date,
        tool=None,
        model=None,
    )
    _enforce_scan_limit(session, public_scope_query, max_scan_rows)
    query = public_scope_query
    if tool is not None:
        query = query.where(DailyUsage.tool == tool)
    if model is not None:
        query = query.where(_model_matches(model))
    _preflight_cost_currency(session, query, metric)
    members = _member_aggregates(session, query)
    target_query = query.where(User.public_id == public_id)
    tools = _distribution_aggregates(
        session,
        target_query,
        dimension=DailyUsage.tool,
    )
    models = _distribution_aggregates(
        session,
        target_query,
        dimension=DailyUsage.model,
        case_insensitive=True,
    )
    days = _distribution_aggregates(
        session,
        _most_recent_daily_scope(target_query),
        dimension=DailyUsage.usage_date,
    )

    ordered = _ordered_members(members.values(), metric)
    target_member = members.get(public_id)
    totals = target_member.usage if target_member is not None else UsageAggregate()
    value = _metric_value(totals, metric)
    metric_currency = _metric_currency(
        (member.usage for member in ordered), metric
    )
    return PublicMemberDetailResponse(
        public_id=public_id,
        nickname=nickname,
        rank=_member_rank(ordered, metric, public_id),
        period=period,
        metric=metric,
        metric_definition=METRIC_DEFINITIONS[metric],
        metric_value=str(value) if value is not None else None,
        metric_currency=metric_currency,
        tool=tool,
        model=model,
        timezone=organization.default_timezone,
        mixed_timezones=totals.mixed_timezones,
        timezone_warning=(
            MIXED_TIMEZONE_WARNING if totals.mixed_timezones else None
        ),
        start_date=start_date,
        end_date=end_date,
        totals=totals.as_response(),
        tool_distribution=_ordered_distribution(tools, metric),
        tool_distribution_total=len(tools),
        model_distribution=_ordered_distribution(models, metric),
        model_distribution_total=len(models),
        daily_trend=[
            PublicDailyTrendItem(date=usage_date, totals=days[usage_date].as_response())
            for usage_date in sorted(days)
        ],
    )
