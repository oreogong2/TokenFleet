#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import os
from pathlib import Path
import re
import secrets
import stat


DOMAIN_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
ORG_SLUG = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?")
SAFE_KEYS = {"TOKENFLEET_DOMAIN", "PUBLIC_ORG_SLUG", "APP_PORT"}


def validate_domain(value: str) -> str:
    if value != value.strip() or value != value.lower():
        raise ValueError("domain must be lowercase without surrounding whitespace")
    if "://" in value or "/" in value or "@" in value or value.endswith("."):
        raise ValueError("domain must be a bare canonical hostname")
    if len(value) > 253 or "." not in value:
        raise ValueError("domain must be a public fully-qualified hostname")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        pass
    else:
        raise ValueError("an IP address cannot be used as the community domain")
    labels = value.split(".")
    if any(not DOMAIN_LABEL.fullmatch(label) for label in labels):
        raise ValueError("domain contains an invalid DNS label")
    if labels[-1].isdigit() or value.endswith(".localhost"):
        raise ValueError("domain must use a public DNS suffix")
    return value


def validate_org_slug(value: str) -> str:
    if not ORG_SLUG.fullmatch(value):
        raise ValueError("organization slug must use lowercase letters, digits, and hyphens")
    return value


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"invalid environment line {line_number}")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ValueError(f"invalid environment key on line {line_number}")
        if key in values:
            raise ValueError(f"duplicate environment key: {key}")
        if "\x00" in value or "\n" in value or "\r" in value:
            raise ValueError(f"invalid environment value for {key}")
        values[key] = value
    return values


def validate_env(path: Path) -> dict[str, str]:
    values = parse_env(path)
    required = {
        "ENVIRONMENT",
        "TOKENFLEET_DOMAIN",
        "PUBLIC_ORG_SLUG",
        "APP_PORT",
        "POSTGRES_PASSWORD",
        "JWT_SECRET",
    }
    missing = sorted(required - values.keys())
    if missing:
        raise ValueError("missing environment values: " + ", ".join(missing))
    if values["ENVIRONMENT"] != "production":
        raise ValueError("ENVIRONMENT must be production")
    validate_domain(values["TOKENFLEET_DOMAIN"])
    validate_org_slug(values["PUBLIC_ORG_SLUG"])
    if not values["APP_PORT"].isdigit() or not 1024 <= int(values["APP_PORT"]) <= 65535:
        raise ValueError("APP_PORT must be an unprivileged TCP port")
    if len(values["POSTGRES_PASSWORD"]) < 32 or not re.fullmatch(
        r"[A-Za-z0-9_-]+", values["POSTGRES_PASSWORD"]
    ):
        raise ValueError("POSTGRES_PASSWORD must be at least 32 URL-safe characters")
    if len(values["JWT_SECRET"].encode("utf-8")) < 32:
        raise ValueError("JWT_SECRET must contain at least 32 UTF-8 bytes")
    if any(value == "<UNSET>" for value in values.values()):
        raise ValueError("all <UNSET> placeholders must be replaced")
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise ValueError("environment file permissions must be 0600 or stricter")
    return values


def write_env(path: Path, *, domain: str, org_slug: str, app_port: int) -> None:
    if path.exists():
        raise FileExistsError(f"refusing to overwrite existing file: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    content = f"""# Generated locally by deploy/prepare_env.py. Do not commit or share.
ENVIRONMENT=production
TOKENFLEET_DOMAIN={domain}
PUBLIC_ORG_SLUG={org_slug}
APP_PORT={app_port}
POSTGRES_PASSWORD={secrets.token_urlsafe(36)}
JWT_SECRET={secrets.token_urlsafe(48)}
JWT_ISSUER=tokenfleet
JWT_AUDIENCE=tokenfleet-api
JWT_TTL_SECONDS=3600
LOGIN_RATE_LIMIT_ATTEMPTS=10
LOGIN_RATE_LIMIT_IP_ATTEMPTS=50
LOGIN_RATE_LIMIT_WINDOW_SECONDS=60
LOGIN_RATE_LIMIT_MAX_KEYS=10000
PUBLIC_RATE_LIMIT_ATTEMPTS=30
PUBLIC_RATE_LIMIT_WINDOW_SECONDS=60
PUBLIC_RATE_LIMIT_MAX_KEYS=10000
PUBLIC_MAX_SCAN_ROWS=250000
PUBLIC_CACHE_TTL_SECONDS=15
PUBLIC_CACHE_MAX_ENTRIES=1024
USAGE_RATE_LIMIT_DEVICE_ATTEMPTS=12
USAGE_RATE_LIMIT_ORG_ATTEMPTS=600
USAGE_RATE_LIMIT_WINDOW_SECONDS=60
USAGE_MAX_ROWS_PER_DEVICE=100000
USAGE_MAX_ROWS_PER_ORG=2000000
HMAC_MAX_CLOCK_SKEW_SECONDS=300
NONCE_RETENTION_SECONDS=600
PBKDF2_ITERATIONS=600000
"""
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    validate_env(path)


def main() -> None:
    parser = argparse.ArgumentParser(description="Create or validate TokenFleet production env")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--domain")
    parser.add_argument("--org-slug")
    parser.add_argument("--app-port", type=int, default=18080)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--get", choices=sorted(SAFE_KEYS))
    args = parser.parse_args()
    if args.check or args.get:
        values = validate_env(args.output)
        print(values[args.get] if args.get else "TokenFleet production environment validation passed")
        return
    if not args.domain or not args.org_slug:
        parser.error("--domain and --org-slug are required when creating a file")
    write_env(
        args.output,
        domain=validate_domain(args.domain),
        org_slug=validate_org_slug(args.org_slug),
        app_port=args.app_port,
    )
    print(f"Created protected environment file: {args.output}")
    print(f"Community origin: https://{args.domain}")


if __name__ == "__main__":
    main()
