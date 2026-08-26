from __future__ import annotations

import enum
import unicodedata
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    Enum,
    ForeignKeyConstraint,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    UniqueConstraint,
    false,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship, validates

from .database import Base


def new_id() -> str:
    return str(uuid.uuid4())


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def normalize_display_name(value: str) -> str:
    """Return the database identity used for organization-scoped nickname uniqueness."""

    normalized = unicodedata.normalize("NFKC", value.strip()).casefold()
    if not normalized or len(normalized) > 512:
        raise ValueError("display_name cannot be normalized to an empty or oversized value")
    return normalized


class UserRole(str, enum.Enum):
    ADMIN = "admin"
    MEMBER = "member"


class Organization(Base):
    __tablename__ = "organizations"
    __table_args__ = (
        CheckConstraint("retention_days BETWEEN 30 AND 3650", name="ck_org_retention_days"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    slug: Mapped[str] = mapped_column(String(64), unique=True, nullable=False, index=True)
    name: Mapped[str] = mapped_column(String(128), nullable=False)
    default_timezone: Mapped[str] = mapped_column(
        String(64), nullable=False, default="Asia/Shanghai"
    )
    retention_days: Mapped[int] = mapped_column(Integer, nullable=False, default=395)
    ledger_version: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    users: Mapped[list["User"]] = relationship(back_populates="organization")


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint("org_id", "email", name="uq_user_org_email"),
        UniqueConstraint("id", "org_id", name="uq_user_id_org"),
        Index(
            "uq_user_org_normalized_display_name",
            "org_id",
            "normalized_display_name",
            unique=True,
        ),
        CheckConstraint(
            "(email IS NULL AND password_hash IS NULL) OR "
            "(email IS NOT NULL AND password_hash IS NOT NULL)",
            name="ck_user_login_credentials_pair",
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    org_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # A participant created solely for device enrollment has no human login.
    # Keeping both credentials NULL avoids fake email addresses while preserving
    # the existing login-member and administrator model.
    email: Mapped[str | None] = mapped_column(String(254))
    display_name: Mapped[str | None] = mapped_column(String(128))
    normalized_display_name: Mapped[str | None] = mapped_column(String(512))
    password_hash: Mapped[str | None] = mapped_column(String(512))
    public_id: Mapped[str] = mapped_column(
        String(36), nullable=False, default=new_id, unique=True, index=True
    )
    public_profile_enabled: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=false()
    )
    role: Mapped[UserRole] = mapped_column(
        Enum(UserRole, native_enum=False, length=16), nullable=False, default=UserRole.MEMBER
    )
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    organization: Mapped[Organization] = relationship(back_populates="users")
    devices: Mapped[list["Device"]] = relationship(back_populates="user")

    @property
    def can_login(self) -> bool:
        return self.email is not None and self.password_hash is not None

    @validates("display_name")
    def _normalize_display_name(self, _key: str, value: str | None) -> str | None:
        self.normalized_display_name = (
            normalize_display_name(value) if value is not None else None
        )
        return value


class EnrollmentToken(Base):
    __tablename__ = "enrollment_tokens"
    __table_args__ = (
        ForeignKeyConstraint(
            ["user_id", "org_id"], ["users.id", "users.org_id"], ondelete="CASCADE"
        ),
        ForeignKeyConstraint(
            ["created_by_user_id", "org_id"],
            ["users.id", "users.org_id"],
            ondelete="CASCADE",
        ),
        Index("ix_enrollment_org_user", "org_id", "user_id"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    org_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False
    )
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    created_by_user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False, unique=True, index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )


class InvitationBatch(Base):
    __tablename__ = "invitation_batches"
    __table_args__ = (
        ForeignKeyConstraint(
            ["created_by_user_id", "org_id"],
            ["users.id", "users.org_id"],
            ondelete="CASCADE",
        ),
        CheckConstraint("capacity BETWEEN 1 AND 50", name="ck_invitation_batch_capacity"),
        CheckConstraint(
            "claimed_count BETWEEN 0 AND capacity",
            name="ck_invitation_batch_claimed_count",
        ),
        Index("uq_invitation_batch_token_hash", "token_hash", unique=True),
        Index("ix_invitation_batch_org_created", "org_id", "created_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    org_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False
    )
    created_by_user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    capacity: Mapped[int] = mapped_column(Integer, nullable=False, default=50)
    claimed_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (
        ForeignKeyConstraint(
            ["user_id", "org_id"], ["users.id", "users.org_id"], ondelete="CASCADE"
        ),
        UniqueConstraint("org_id", "device_public_id", name="uq_device_org_public_id"),
        UniqueConstraint("id", "user_id", "org_id", name="uq_device_id_user_org"),
        Index("ix_device_org_user", "org_id", "user_id"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    org_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False
    )
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    device_public_id: Mapped[str] = mapped_column(String(36), nullable=False)
    platform: Mapped[str] = mapped_column(String(32), nullable=False)
    app_version: Mapped[str] = mapped_column(String(64), nullable=False)
    collector_version: Mapped[str] = mapped_column(String(64), nullable=False)
    # This is a one-way derivation of the registration secret. It is nevertheless
    # a symmetric signing capability and must be protected like a credential.
    signing_key: Mapped[str] = mapped_column(String(64), nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    disabled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_successful_sync_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    user: Mapped[User] = relationship(back_populates="devices")


class CommunityShareGrant(Base):
    """One-time, short-lived bridge from a signed device to the public Web UI.

    The raw grant is deliberately never persisted.  It can only identify a
    member's already-public profile for a single browser-page redemption; it
    is not a login credential and does not authorize any write operation.
    """

    __tablename__ = "community_share_grants"
    __table_args__ = (
        ForeignKeyConstraint(
            ["user_id", "org_id"], ["users.id", "users.org_id"], ondelete="CASCADE"
        ),
        ForeignKeyConstraint(
            ["device_id", "user_id", "org_id"],
            ["devices.id", "devices.user_id", "devices.org_id"],
            ondelete="CASCADE",
        ),
        Index("uq_community_share_grant_hash", "grant_hash", unique=True),
        Index("ix_community_share_grant_expires", "expires_at"),
        Index("ix_community_share_grant_device_consumed", "device_id", "consumed_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    org_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False
    )
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    device_id: Mapped[str] = mapped_column(String(36), nullable=False)
    grant_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )


class DeviceNonce(Base):
    __tablename__ = "device_nonces"
    __table_args__ = (
        UniqueConstraint("device_id", "nonce", name="uq_device_nonce"),
        Index("ix_device_nonce_created", "created_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    device_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("devices.id", ondelete="CASCADE"), nullable=False
    )
    nonce: Mapped[str] = mapped_column(String(128), nullable=False)
    request_timestamp: Mapped[int] = mapped_column(BigInteger, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )


class PriceVersion(Base):
    __tablename__ = "price_versions"
    __table_args__ = (
        ForeignKeyConstraint(
            ["created_by_user_id", "org_id"],
            ["users.id", "users.org_id"],
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "org_id", "tool", "model", "effective_from", name="uq_price_scope_effective"
        ),
        UniqueConstraint("id", "org_id", name="uq_price_id_org"),
        CheckConstraint("input_per_million >= 0", name="ck_price_input_nonnegative"),
        CheckConstraint("output_per_million >= 0", name="ck_price_output_nonnegative"),
        CheckConstraint("cache_read_per_million >= 0", name="ck_price_cache_read_nonnegative"),
        CheckConstraint("cache_write_per_million >= 0", name="ck_price_cache_write_nonnegative"),
        Index("ix_price_lookup", "org_id", "tool", "model", "effective_from"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    org_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False
    )
    tool: Mapped[str] = mapped_column(String(128), nullable=False)
    model: Mapped[str] = mapped_column(String(128), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    # Public projections may use a frozen derived cost only when an
    # administrator explicitly declares this version a public estimate. The
    # default protects private negotiated or invoice rates.
    public_estimate: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=false()
    )
    input_per_million: Mapped[Decimal] = mapped_column(Numeric(20, 8), nullable=False)
    output_per_million: Mapped[Decimal] = mapped_column(Numeric(20, 8), nullable=False)
    cache_read_per_million: Mapped[Decimal] = mapped_column(Numeric(20, 8), nullable=False)
    cache_write_per_million: Mapped[Decimal] = mapped_column(Numeric(20, 8), nullable=False)
    effective_from: Mapped[date] = mapped_column(Date, nullable=False)
    created_by_user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )


class DailyUsage(Base):
    __tablename__ = "daily_usage"
    __table_args__ = (
        ForeignKeyConstraint(
            ["user_id", "org_id"], ["users.id", "users.org_id"], ondelete="CASCADE"
        ),
        ForeignKeyConstraint(
            ["device_id", "user_id", "org_id"],
            ["devices.id", "devices.user_id", "devices.org_id"],
            ondelete="CASCADE",
        ),
        ForeignKeyConstraint(
            ["price_version_id", "org_id"],
            ["price_versions.id", "price_versions.org_id"],
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "org_id",
            "user_id",
            "device_id",
            "usage_date",
            "timezone",
            "tool",
            "model",
            "source",
            name="uq_daily_usage_natural_key",
        ),
        CheckConstraint("input_tokens >= 0", name="ck_usage_input_nonnegative"),
        CheckConstraint("output_tokens >= 0", name="ck_usage_output_nonnegative"),
        CheckConstraint("cache_read_tokens >= 0", name="ck_usage_cache_read_nonnegative"),
        CheckConstraint("cache_write_tokens >= 0", name="ck_usage_cache_write_nonnegative"),
        CheckConstraint(
            "completeness IN ('exact', 'legacy_marginal', 'fallback_estimate')",
            name="ck_usage_completeness",
        ),
        Index("ix_usage_org_date", "org_id", "usage_date"),
        Index("ix_usage_org_user_date", "org_id", "user_id", "usage_date"),
        Index("ix_usage_org_device_date", "org_id", "device_id", "usage_date"),
        Index("ix_usage_public_org_tool_date", "org_id", "tool", "usage_date"),
        Index("ix_usage_public_org_model_date", "org_id", "model", "usage_date"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    org_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False
    )
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    device_id: Mapped[str] = mapped_column(String(36), nullable=False)
    usage_date: Mapped[date] = mapped_column(Date, nullable=False)
    timezone: Mapped[str] = mapped_column(String(64), nullable=False)
    tool: Mapped[str] = mapped_column(String(128), nullable=False)
    model: Mapped[str] = mapped_column(String(128), nullable=False)
    source: Mapped[str] = mapped_column(String(128), nullable=False, default="local")
    is_deleted: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=false()
    )
    completeness: Mapped[str] = mapped_column(String(32), nullable=False)
    input_tokens: Mapped[int] = mapped_column(BigInteger, nullable=False)
    output_tokens: Mapped[int] = mapped_column(BigInteger, nullable=False)
    cache_read_tokens: Mapped[int] = mapped_column(BigInteger, nullable=False)
    cache_write_tokens: Mapped[int] = mapped_column(BigInteger, nullable=False)
    report_schema_version: Mapped[int] = mapped_column(Integer, nullable=False)
    collector_version: Mapped[str] = mapped_column(String(64), nullable=False)
    reported_generated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    price_version_id: Mapped[str | None] = mapped_column(String(36))
    cost_microunits: Mapped[int | None] = mapped_column(BigInteger)
    cost_currency: Mapped[str | None] = mapped_column(String(3))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow, onupdate=utcnow
    )
