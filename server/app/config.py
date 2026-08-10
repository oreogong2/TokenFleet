from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Settings:
    environment: str = "development"
    database_url: str = "sqlite:///./tokenfleet.db"
    web_root: str | None = None
    jwt_secret: str = "change-me-in-production"
    jwt_issuer: str = "tokenfleet"
    jwt_audience: str = "tokenfleet-api"
    jwt_ttl_seconds: int = 3600
    login_rate_limit_attempts: int = 10
    login_rate_limit_ip_attempts: int = 50
    login_rate_limit_window_seconds: int = 60
    login_rate_limit_max_keys: int = 10_000
    trusted_proxy_cidrs: str = ""
    trusted_proxy_hops: int = 0
    public_org_slug: str = ""
    public_rate_limit_attempts: int = 30
    public_rate_limit_window_seconds: int = 60
    public_rate_limit_max_keys: int = 10_000
    public_max_scan_rows: int = 250_000
    public_cache_ttl_seconds: int = 15
    public_cache_max_entries: int = 1_024
    enrollment_rate_limit_attempts: int = 60
    enrollment_rate_limit_window_seconds: int = 60
    enrollment_rate_limit_max_keys: int = 10_000
    usage_rate_limit_device_attempts: int = 12
    usage_rate_limit_org_attempts: int = 600
    usage_rate_limit_window_seconds: int = 60
    usage_max_rows_per_device: int = 100_000
    usage_max_rows_per_org: int = 2_000_000
    hmac_max_clock_skew_seconds: int = 300
    nonce_retention_seconds: int = 600
    pbkdf2_iterations: int = 600_000

    @classmethod
    def from_env(cls) -> "Settings":
        defaults = cls()
        return cls(
            environment=os.getenv("ENVIRONMENT", defaults.environment),
            database_url=os.getenv("DATABASE_URL", defaults.database_url),
            web_root=os.getenv("WEB_ROOT", defaults.web_root),
            jwt_secret=os.getenv("JWT_SECRET", defaults.jwt_secret),
            jwt_issuer=os.getenv("JWT_ISSUER", defaults.jwt_issuer),
            jwt_audience=os.getenv("JWT_AUDIENCE", defaults.jwt_audience),
            jwt_ttl_seconds=int(os.getenv("JWT_TTL_SECONDS", defaults.jwt_ttl_seconds)),
            login_rate_limit_attempts=int(
                os.getenv(
                    "LOGIN_RATE_LIMIT_ATTEMPTS", defaults.login_rate_limit_attempts
                )
            ),
            login_rate_limit_ip_attempts=int(
                os.getenv(
                    "LOGIN_RATE_LIMIT_IP_ATTEMPTS",
                    defaults.login_rate_limit_ip_attempts,
                )
            ),
            login_rate_limit_window_seconds=int(
                os.getenv(
                    "LOGIN_RATE_LIMIT_WINDOW_SECONDS",
                    defaults.login_rate_limit_window_seconds,
                )
            ),
            login_rate_limit_max_keys=int(
                os.getenv(
                    "LOGIN_RATE_LIMIT_MAX_KEYS", defaults.login_rate_limit_max_keys
                )
            ),
            trusted_proxy_cidrs=os.getenv(
                "TRUSTED_PROXY_CIDRS", defaults.trusted_proxy_cidrs
            ),
            trusted_proxy_hops=int(
                os.getenv("TRUSTED_PROXY_HOPS", defaults.trusted_proxy_hops)
            ),
            public_org_slug=os.getenv("PUBLIC_ORG_SLUG", defaults.public_org_slug),
            public_rate_limit_attempts=int(
                os.getenv(
                    "PUBLIC_RATE_LIMIT_ATTEMPTS",
                    defaults.public_rate_limit_attempts,
                )
            ),
            public_rate_limit_window_seconds=int(
                os.getenv(
                    "PUBLIC_RATE_LIMIT_WINDOW_SECONDS",
                    defaults.public_rate_limit_window_seconds,
                )
            ),
            public_rate_limit_max_keys=int(
                os.getenv(
                    "PUBLIC_RATE_LIMIT_MAX_KEYS",
                    defaults.public_rate_limit_max_keys,
                )
            ),
            public_max_scan_rows=int(
                os.getenv(
                    "PUBLIC_MAX_SCAN_ROWS",
                    defaults.public_max_scan_rows,
                )
            ),
            public_cache_ttl_seconds=int(
                os.getenv(
                    "PUBLIC_CACHE_TTL_SECONDS",
                    defaults.public_cache_ttl_seconds,
                )
            ),
            public_cache_max_entries=int(
                os.getenv(
                    "PUBLIC_CACHE_MAX_ENTRIES",
                    defaults.public_cache_max_entries,
                )
            ),
            enrollment_rate_limit_attempts=int(
                os.getenv(
                    "ENROLLMENT_RATE_LIMIT_ATTEMPTS",
                    defaults.enrollment_rate_limit_attempts,
                )
            ),
            enrollment_rate_limit_window_seconds=int(
                os.getenv(
                    "ENROLLMENT_RATE_LIMIT_WINDOW_SECONDS",
                    defaults.enrollment_rate_limit_window_seconds,
                )
            ),
            enrollment_rate_limit_max_keys=int(
                os.getenv(
                    "ENROLLMENT_RATE_LIMIT_MAX_KEYS",
                    defaults.enrollment_rate_limit_max_keys,
                )
            ),
            usage_rate_limit_device_attempts=int(
                os.getenv(
                    "USAGE_RATE_LIMIT_DEVICE_ATTEMPTS",
                    defaults.usage_rate_limit_device_attempts,
                )
            ),
            usage_rate_limit_org_attempts=int(
                os.getenv(
                    "USAGE_RATE_LIMIT_ORG_ATTEMPTS",
                    defaults.usage_rate_limit_org_attempts,
                )
            ),
            usage_rate_limit_window_seconds=int(
                os.getenv(
                    "USAGE_RATE_LIMIT_WINDOW_SECONDS",
                    defaults.usage_rate_limit_window_seconds,
                )
            ),
            usage_max_rows_per_device=int(
                os.getenv(
                    "USAGE_MAX_ROWS_PER_DEVICE",
                    defaults.usage_max_rows_per_device,
                )
            ),
            usage_max_rows_per_org=int(
                os.getenv(
                    "USAGE_MAX_ROWS_PER_ORG", defaults.usage_max_rows_per_org
                )
            ),
            hmac_max_clock_skew_seconds=int(
                os.getenv(
                    "HMAC_MAX_CLOCK_SKEW_SECONDS", defaults.hmac_max_clock_skew_seconds
                )
            ),
            nonce_retention_seconds=int(
                os.getenv("NONCE_RETENTION_SECONDS", defaults.nonce_retention_seconds)
            ),
            pbkdf2_iterations=int(
                os.getenv("PBKDF2_ITERATIONS", defaults.pbkdf2_iterations)
            ),
        )
