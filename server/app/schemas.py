from __future__ import annotations

import unicodedata
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Annotated, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import (
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    field_validator,
    model_validator,
)

TOKEN_MAX = 9_000_000_000_000_000
PUBLIC_NICKNAME_MAX_LENGTH = 128
NORMALIZED_PUBLIC_NICKNAME_MAX_LENGTH = 512
Trimmed128 = Annotated[str, Field(min_length=1, max_length=128)]
VersionString = Annotated[str, Field(min_length=1, max_length=64)]
PublicNickname = Annotated[
    str, Field(min_length=1, max_length=PUBLIC_NICKNAME_MAX_LENGTH)
]
NonNegativeIntegerString = Annotated[str, Field(pattern=r"^(0|[1-9][0-9]*)$")]
FORBIDDEN_LABEL_CATEGORIES = frozenset({"Cc", "Cf", "Cs", "Zl", "Zp"})


def validate_label_characters(value: str) -> str:
    if any(
        unicodedata.category(character) in FORBIDDEN_LABEL_CATEGORIES
        for character in value
    ):
        raise ValueError(
            "tool, model, and source cannot contain Unicode control, "
            "format, surrogate, or line-separator characters"
        )
    return value


def validate_public_nickname(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value.strip())
    normalized_identity = normalized.casefold()
    if (
        not normalized_identity
        or len(normalized) > NORMALIZED_PUBLIC_NICKNAME_MAX_LENGTH
        or len(normalized_identity) > NORMALIZED_PUBLIC_NICKNAME_MAX_LENGTH
    ):
        raise ValueError(
            "display_name cannot be normalized to an empty or oversized value"
        )
    if any(
        unicodedata.category(character) in FORBIDDEN_LABEL_CATEGORIES
        for character in value
    ):
        raise ValueError(
            "display_name cannot contain Unicode control, format, surrogate, "
            "or line-separator characters"
        )
    return value


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class TokenRequest(StrictModel):
    org_slug: Annotated[str, Field(min_length=1, max_length=64)]
    email: EmailStr
    password: Annotated[str, Field(min_length=8, max_length=1024)]


class TokenResponse(StrictModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"
    expires_in: int


class UserCreate(StrictModel):
    email: EmailStr
    password: Annotated[str, Field(min_length=12, max_length=1024)]
    role: Literal["admin"]
    display_name: Annotated[str | None, Field(min_length=1, max_length=128)] = None

    @field_validator("display_name")
    @classmethod
    def display_name_is_safe(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return validate_public_nickname(value)


class UserResponse(StrictModel):
    id: str
    org_id: str
    email: EmailStr | None
    display_name: str | None
    role: Literal["admin", "member"]
    is_active: bool
    can_login: bool
    public_id: str
    public_profile_enabled: bool

    model_config = ConfigDict(from_attributes=True, extra="forbid")


class UserStatusUpdate(StrictModel):
    is_active: Annotated[bool, Field(strict=True)] | None = None
    display_name: Annotated[str | None, Field(min_length=1, max_length=128)] = None
    public_profile_enabled: Annotated[bool, Field(strict=True)] | None = None

    @field_validator("display_name")
    @classmethod
    def public_display_name_is_safe(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return validate_public_nickname(value)

    @model_validator(mode="after")
    def at_least_one_field(self) -> "UserStatusUpdate":
        if not self.model_fields_set or (
            self.is_active is None
            and self.public_profile_enabled is None
            and "display_name" not in self.model_fields_set
        ):
            raise ValueError("at least one user field is required")
        return self


class ParticipantCreate(StrictModel):
    display_name: PublicNickname
    public_profile_enabled: Annotated[bool, Field(strict=True)]
    expires_in_minutes: Annotated[int, Field(strict=True, ge=1, le=1_440)] = 60

    @field_validator("display_name")
    @classmethod
    def public_display_name_is_safe(cls, value: str) -> str:
        return validate_public_nickname(value)


class ParticipantEnrollmentResponse(StrictModel):
    participant: UserResponse
    enrollment_token: str
    expires_at: datetime


class InvitationBatchCreate(StrictModel):
    capacity: Annotated[int, Field(strict=True, ge=1, le=50)] = 50
    expires_in_hours: Annotated[int, Field(strict=True, ge=1, le=2_160)] = 24


class InvitationBatchSummary(StrictModel):
    id: str
    capacity: int
    claimed_count: int
    expires_at: datetime
    closed_at: datetime | None
    created_at: datetime
    status: Literal["open", "full", "expired", "closed"]


class InvitationBatchCreateResponse(StrictModel):
    batch: InvitationBatchSummary
    invitation_token: str


class InvitationBatchClaim(StrictModel):
    invitation_token: Annotated[str, Field(min_length=32, max_length=256)]
    display_name: PublicNickname
    public_profile_enabled: Annotated[bool, Field(strict=True)]

    @field_validator("display_name")
    @classmethod
    def display_name_is_safe(cls, value: str) -> str:
        return validate_public_nickname(value)

    @model_validator(mode="after")
    def public_profile_requires_explicit_consent(self) -> "InvitationBatchClaim":
        if not self.public_profile_enabled:
            raise ValueError("public_profile_enabled must be true")
        return self


class InvitationBatchClaimResponse(StrictModel):
    nickname: str
    enrollment_token: str
    expires_at: datetime


class OrganizationSettingsUpdate(StrictModel):
    name: Annotated[str, Field(min_length=1, max_length=128)] | None = None
    default_timezone: Annotated[str, Field(min_length=1, max_length=64)] | None = None
    retention_days: Annotated[int, Field(strict=True, ge=30, le=3650)] | None = None

    @field_validator("default_timezone")
    @classmethod
    def default_timezone_is_known(cls, value: str | None) -> str | None:
        if value is None:
            return None
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError as exc:
            raise ValueError("default_timezone must be a known IANA identifier") from exc
        return value

    @model_validator(mode="after")
    def at_least_one_setting(self) -> "OrganizationSettingsUpdate":
        if (
            self.name is None
            and self.default_timezone is None
            and self.retention_days is None
        ):
            raise ValueError("at least one organization setting is required")
        return self


class OrganizationSettingsResponse(StrictModel):
    id: str
    slug: str
    name: str
    default_timezone: str
    retention_days: int
    retention_enforcement: Literal["external_scheduler_required"] = (
        "external_scheduler_required"
    )
    ledger_version: int

    model_config = ConfigDict(from_attributes=True, extra="forbid")


class EnrollmentTokenCreate(StrictModel):
    user_id: UUID
    expires_in_minutes: Annotated[int, Field(strict=True, ge=1, le=1_440)] = 60


class EnrollmentTokenResponse(StrictModel):
    enrollment_token: str
    expires_at: datetime


class DeviceEnrollRequest(StrictModel):
    enrollment_token: Annotated[str, Field(min_length=32, max_length=256)]
    device_public_id: UUID
    platform: Annotated[str, Field(min_length=1, max_length=32)]
    app_version: VersionString
    collector_version: VersionString


class DeviceEnrollResponse(StrictModel):
    device_id: str
    device_public_id: str
    device_secret: str
    signing_key_derivation: Literal["sha256-tokenfleet-hmac-v1"] = (
        "sha256-tokenfleet-hmac-v1"
    )


class DeviceResponse(StrictModel):
    id: str
    org_id: str
    user_id: str
    device_public_id: str
    platform: str
    app_version: str
    collector_version: str
    is_active: bool
    disabled_at: datetime | None
    last_seen_at: datetime | None
    last_successful_sync_at: datetime | None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True, extra="forbid")


class DeviceCommunityRankResponse(StrictModel):
    public_id: str
    nickname: Annotated[str | None, Field(min_length=1, max_length=128)]
    public_profile_enabled: bool
    period: Literal["today"] = "today"
    metric: Literal["tokens"] = "tokens"
    rank: Annotated[int, Field(ge=1)] | None
    total_entries: Annotated[int, Field(ge=0)]
    metric_value: NonNegativeIntegerString | None
    primary_tool: Annotated[str | None, Field(min_length=1, max_length=128)] = None
    primary_model: Annotated[str | None, Field(min_length=1, max_length=128)] = None
    totals: PublicUsageTotals | None = None


class CommunityShareGrantIssueRequest(StrictModel):
    """The signed route intentionally accepts only an empty JSON object."""


class CommunityShareGrantResponse(StrictModel):
    grant: Annotated[
        str,
        Field(min_length=43, max_length=128, pattern=r"^[A-Za-z0-9_-]+$"),
    ]
    expires_at: datetime
    public_id: str


class CommunityShareGrantRedeemRequest(StrictModel):
    grant: Annotated[
        str,
        Field(min_length=43, max_length=128, pattern=r"^[A-Za-z0-9_-]+$"),
    ]


class CommunityShareGrantRedeemResponse(StrictModel):
    public_id: str


class DeviceStatusUpdate(StrictModel):
    is_active: Annotated[bool, Field(strict=True)]


class UsageBucket(StrictModel):
    date: date
    timezone: Annotated[str, Field(min_length=1, max_length=64)]
    tool: Trimmed128
    model: Trimmed128
    source: Trimmed128 = "local"
    input_tokens: Annotated[int, Field(strict=True, ge=0, le=TOKEN_MAX)]
    output_tokens: Annotated[int, Field(strict=True, ge=0, le=TOKEN_MAX)]
    cache_read_tokens: Annotated[int, Field(strict=True, ge=0, le=TOKEN_MAX)]
    cache_write_tokens: Annotated[int, Field(strict=True, ge=0, le=TOKEN_MAX)]
    completeness: Literal["exact", "legacy_marginal", "fallback_estimate"]
    deleted: Annotated[bool, Field(strict=True)] = False

    @field_validator("timezone")
    @classmethod
    def known_iana_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError as exc:
            raise ValueError("timezone must be a known IANA identifier") from exc
        return value

    @field_validator("tool", "model", "source")
    @classmethod
    def labels_do_not_contain_control_characters(cls, value: str) -> str:
        return validate_label_characters(value)

    @field_validator("date")
    @classmethod
    def acceptable_date(cls, value: date) -> date:
        received_date = datetime.now(timezone.utc).date()
        try:
            oldest = received_date.replace(year=received_date.year - 5)
        except ValueError:
            oldest = received_date.replace(year=received_date.year - 5, day=28)
        if value < oldest:
            raise ValueError("date cannot be earlier than five years before receipt")
        if value > received_date + timedelta(days=2):
            raise ValueError("date cannot be later than two days after receipt")
        return value

    @model_validator(mode="after")
    def tombstone_is_exact_and_zero(self) -> "UsageBucket":
        if self.deleted and (
            self.completeness != "exact"
            or self.input_tokens != 0
            or self.output_tokens != 0
            or self.cache_read_tokens != 0
            or self.cache_write_tokens != 0
        ):
            raise ValueError(
                "deleted buckets must be exact and all four token fields must be zero"
            )
        return self


class DailyUsageReport(StrictModel):
    schema_version: Literal[1]
    collector_version: VersionString
    generated_at: datetime
    buckets: Annotated[list[UsageBucket], Field(min_length=1, max_length=2000)]

    @field_validator("generated_at")
    @classmethod
    def generated_at_has_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("generated_at must include a UTC offset")
        now = datetime.now(timezone.utc)
        normalized = value.astimezone(timezone.utc)
        if normalized > now + timedelta(minutes=10):
            raise ValueError("generated_at cannot be more than ten minutes in the future")
        if normalized < now - timedelta(days=366 * 5):
            raise ValueError("generated_at cannot be more than five years old")
        return value

    @model_validator(mode="after")
    def natural_keys_are_unique(self) -> "DailyUsageReport":
        seen: set[tuple[object, ...]] = set()
        for bucket in self.buckets:
            key = (
                bucket.date,
                bucket.timezone,
                bucket.tool,
                bucket.model,
                bucket.source,
            )
            if key in seen:
                raise ValueError("buckets contain a duplicate natural key")
            seen.add(key)
        return self


class DailyUsageIngestResponse(StrictModel):
    created: int
    updated: int
    unchanged: int
    ledger_version: int


class PriceCreate(StrictModel):
    tool: Trimmed128
    model: Trimmed128
    currency: Annotated[str, Field(min_length=3, max_length=3)] = "USD"
    public_estimate: Annotated[bool, Field(strict=True)]
    input_per_million: Annotated[Decimal, Field(ge=0, max_digits=20, decimal_places=8)]
    output_per_million: Annotated[Decimal, Field(ge=0, max_digits=20, decimal_places=8)]
    cache_read_per_million: Annotated[
        Decimal, Field(ge=0, max_digits=20, decimal_places=8)
    ]
    cache_write_per_million: Annotated[
        Decimal, Field(ge=0, max_digits=20, decimal_places=8)
    ]
    effective_from: date

    @field_validator("tool", "model")
    @classmethod
    def labels_do_not_contain_control_characters(cls, value: str) -> str:
        return validate_label_characters(value)

    @field_validator("currency")
    @classmethod
    def currency_is_uppercase_ascii(cls, value: str) -> str:
        value = value.upper()
        if not value.isascii() or not value.isalpha():
            raise ValueError("currency must be a three-letter ASCII code")
        return value


class PriceResponse(StrictModel):
    id: str
    org_id: str
    tool: str
    model: str
    currency: str
    public_estimate: bool
    input_per_million: Decimal
    output_per_million: Decimal
    cache_read_per_million: Decimal
    cache_write_per_million: Decimal
    effective_from: date
    created_at: datetime

    model_config = ConfigDict(from_attributes=True, extra="forbid")


class PriceVisibilityUpdate(StrictModel):
    public_estimate: Annotated[bool, Field(strict=True)]


class UsageRow(StrictModel):
    date: date
    timezone: str
    user_id: str
    device_id: str
    tool: str
    model: str
    source: str
    completeness: str
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int
    cache_write_tokens: int
    total_tokens: int
    schema_version: int
    collector_version: str
    price_version_id: str | None
    cost_microunits: int | None
    cost_currency: str | None


class UsageTotals(StrictModel):
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int
    cache_write_tokens: int
    total_tokens: int
    priced_costs_microunits: dict[str, int]
    unpriced_rows: int


class UsageDashboardResponse(StrictModel):
    rows: list[UsageRow]
    totals: UsageTotals
    organization_timezone: str
    mixed_timezones: bool
    timezone_warning: str | None


PublicPeriod = Literal["today", "yesterday", "3d", "7d", "30d", "90d", "all"]
PublicMetric = Literal["tokens", "norm", "cost"]


class PublicUsageTotals(StrictModel):
    input_tokens: NonNegativeIntegerString
    output_tokens: NonNegativeIntegerString
    cache_read_tokens: NonNegativeIntegerString
    cache_write_tokens: NonNegativeIntegerString
    # The public normalization contract is deliberately simple and stable:
    # norm_tokens = input_tokens + output_tokens. Cache never contributes.
    norm_tokens: NonNegativeIntegerString
    total_tokens: NonNegativeIntegerString
    estimated_cost_microunits: NonNegativeIntegerString | None
    cost_currency: Annotated[str | None, Field(min_length=3, max_length=3)]
    unpriced: bool
    mixed_currency: bool


class PublicLeaderboardEntry(StrictModel):
    rank: int | None
    public_id: str
    nickname: str
    metric_value: NonNegativeIntegerString | None
    primary_tool: str | None
    primary_tool_tokens: NonNegativeIntegerString | None
    tool_count: int
    primary_model: str | None
    primary_model_tokens: NonNegativeIntegerString | None
    model_count: int
    totals: PublicUsageTotals


class PublicLeaderboardResponse(StrictModel):
    period: PublicPeriod
    metric: PublicMetric
    metric_definition: str
    metric_currency: str | None
    tool: str | None
    model: str | None
    timezone: str
    mixed_timezones: bool
    timezone_warning: str | None
    start_date: date | None
    end_date: date
    available_tools: list[str]
    available_models: list[str]
    total_entries: int
    entries: list[PublicLeaderboardEntry]


class PublicDistributionItem(StrictModel):
    name: str
    totals: PublicUsageTotals


class PublicDailyTrendItem(StrictModel):
    date: date
    totals: PublicUsageTotals


class PublicMemberDetailResponse(StrictModel):
    public_id: str
    nickname: str
    rank: int | None
    period: PublicPeriod
    metric: PublicMetric
    metric_definition: str
    metric_value: NonNegativeIntegerString | None
    metric_currency: str | None
    tool: str | None
    model: str | None
    timezone: str
    mixed_timezones: bool
    timezone_warning: str | None
    start_date: date | None
    end_date: date
    totals: PublicUsageTotals
    tool_distribution: list[PublicDistributionItem]
    tool_distribution_total: int
    model_distribution: list[PublicDistributionItem]
    model_distribution_total: int
    daily_trend: list[PublicDailyTrendItem]


class HealthResponse(StrictModel):
    status: Literal["ok", "ready"]
