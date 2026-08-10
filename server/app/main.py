from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.engine import Engine

from .api import router
from .config import Settings
from .database import build_engine, build_session_factory
from .middleware import (
    RequestBodyLimitMiddleware,
    SecurityHeadersMiddleware,
    parse_trusted_proxy_cidrs,
)
from .public_projection import PublicProjectionCache
from .rate_limit import LoginRateLimiter, PublicReadRateLimiter
from .static_web import SPAStaticFiles

MAX_REQUEST_BODY_BYTES = 2 * 1024 * 1024


def create_app(*, settings: Settings | None = None, engine: Engine | None = None) -> FastAPI:
    resolved_settings = settings or Settings.from_env()
    if (
        resolved_settings.jwt_secret == "change-me-in-production"
        or len(resolved_settings.jwt_secret.encode("utf-8")) < 32
    ):
        raise RuntimeError(
            "JWT_SECRET must be explicitly configured with at least 32 UTF-8 bytes"
        )
    if (
        resolved_settings.nonce_retention_seconds
        < 2 * resolved_settings.hmac_max_clock_skew_seconds
    ):
        raise RuntimeError("NONCE_RETENTION_SECONDS must be at least twice the HMAC clock skew")
    if (
        resolved_settings.login_rate_limit_attempts < 1
        or resolved_settings.login_rate_limit_ip_attempts < 1
        or resolved_settings.login_rate_limit_window_seconds < 1
        or resolved_settings.login_rate_limit_max_keys < 2
    ):
        raise RuntimeError("login rate-limit settings must be positive")
    try:
        trusted_proxy_networks = parse_trusted_proxy_cidrs(
            resolved_settings.trusted_proxy_cidrs
        )
    except ValueError as exc:
        raise RuntimeError("TRUSTED_PROXY_CIDRS must contain valid IP networks") from exc
    if trusted_proxy_networks:
        if not 1 <= resolved_settings.trusted_proxy_hops <= 8:
            raise RuntimeError(
                "TRUSTED_PROXY_HOPS must be between 1 and 8 when proxies are trusted"
            )
    elif resolved_settings.trusted_proxy_hops != 0:
        raise RuntimeError(
            "TRUSTED_PROXY_HOPS must be 0 when TRUSTED_PROXY_CIDRS is empty"
        )
    if (
        resolved_settings.public_rate_limit_attempts < 1
        or resolved_settings.public_rate_limit_window_seconds < 1
        or resolved_settings.public_rate_limit_max_keys < 1
        or resolved_settings.public_max_scan_rows < 1
    ):
        raise RuntimeError("public rate-limit settings must be positive")
    if (
        not 1 <= resolved_settings.public_cache_ttl_seconds <= 300
        or resolved_settings.public_cache_max_entries < 1
    ):
        raise RuntimeError(
            "public cache TTL must be 1-300 seconds and max entries must be positive"
        )
    if len(resolved_settings.public_org_slug.strip()) > 64:
        raise RuntimeError("PUBLIC_ORG_SLUG cannot exceed 64 characters")
    if (
        resolved_settings.usage_rate_limit_device_attempts < 1
        or resolved_settings.usage_rate_limit_org_attempts < 1
        or resolved_settings.usage_rate_limit_window_seconds < 1
    ):
        raise RuntimeError("usage rate-limit settings must be positive")
    if (
        resolved_settings.usage_max_rows_per_device < 1
        or resolved_settings.usage_max_rows_per_org < 1
    ):
        raise RuntimeError("usage row-quota settings must be positive")
    if (
        resolved_settings.usage_max_rows_per_device
        > resolved_settings.usage_max_rows_per_org
    ):
        raise RuntimeError(
            "USAGE_MAX_ROWS_PER_DEVICE must not exceed USAGE_MAX_ROWS_PER_ORG"
        )
    if (
        resolved_settings.nonce_retention_seconds
        < resolved_settings.usage_rate_limit_window_seconds
    ):
        raise RuntimeError(
            "NONCE_RETENTION_SECONDS must cover the usage rate-limit window"
        )
    resolved_engine = engine or build_engine(resolved_settings.database_url)
    is_production = resolved_settings.environment.strip().lower() == "production"
    application = FastAPI(
        title="TokenFleet Server",
        version="1.0.0",
        description=(
            "Team AI usage ledger whose official collector protocol accepts only "
            "aggregate usage fields."
        ),
    )
    application.state.settings = resolved_settings
    application.state.trusted_proxy_networks = trusted_proxy_networks
    application.state.trusted_proxy_hops = resolved_settings.trusted_proxy_hops
    application.state.engine = resolved_engine
    application.state.session_factory = build_session_factory(resolved_engine)
    application.state.login_rate_limiter = LoginRateLimiter(
        attempts=resolved_settings.login_rate_limit_attempts,
        ip_attempts=resolved_settings.login_rate_limit_ip_attempts,
        window_seconds=resolved_settings.login_rate_limit_window_seconds,
        max_keys=resolved_settings.login_rate_limit_max_keys,
    )
    application.state.public_rate_limiter = PublicReadRateLimiter(
        attempts=resolved_settings.public_rate_limit_attempts,
        window_seconds=resolved_settings.public_rate_limit_window_seconds,
        max_keys=resolved_settings.public_rate_limit_max_keys,
    )
    application.state.public_projection_cache = PublicProjectionCache(
        ttl_seconds=resolved_settings.public_cache_ttl_seconds,
        max_entries=resolved_settings.public_cache_max_entries,
    )
    application.add_middleware(
        RequestBodyLimitMiddleware, max_bytes=MAX_REQUEST_BODY_BYTES
    )
    # Added last so this pure ASGI middleware also wraps request-size rejections
    # generated by RequestBodyLimitMiddleware.
    application.add_middleware(
        SecurityHeadersMiddleware,
        production=is_production,
        trusted_proxy_networks=trusted_proxy_networks,
        trusted_proxy_hops=resolved_settings.trusted_proxy_hops,
    )

    @application.exception_handler(RequestValidationError)
    async def validation_error_without_sensitive_input(
        _request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        # FastAPI's default validation response echoes the rejected `input`.
        # Removing it prevents passwords, enrollment tokens, and signed bodies
        # from leaking into clients or reverse-proxy error logs.
        sanitized = []
        for error in exc.errors():
            sanitized.append(
                {
                    key: value
                    for key, value in error.items()
                    if key not in {"input", "ctx"}
                }
            )
        return JSONResponse(status_code=422, content={"detail": sanitized})

    application.include_router(router)

    # Keep this catch-all before the root SPA mount. Known API routes registered
    # above still win by route order; unknown API paths remain machine-readable
    # 404s instead of accidentally returning index.html.
    @application.api_route(
        "/api/{path:path}",
        methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"],
        include_in_schema=False,
    )
    async def unknown_api(path: str) -> JSONResponse:
        del path
        return JSONResponse(status_code=404, content={"detail": "API route not found"})

    default_web_root = Path(__file__).resolve().parents[2] / "web"
    configured_web_root = resolved_settings.web_root
    web_root = (
        Path(configured_web_root).expanduser()
        if configured_web_root
        else default_web_root
    )
    if configured_web_root != "" and (web_root / "index.html").is_file():
        application.mount(
            "/",
            SPAStaticFiles(directory=str(web_root), html=True),
            name="web",
        )
    return application


app = create_app()
