from __future__ import annotations

import hashlib
import hmac
import json
import re
import time
import unicodedata
import urllib.parse
import uuid
from datetime import datetime, timezone
from typing import Any, Iterable

from .constants import (
    DAILY_USAGE_PATH,
    MAX_TOKEN_VALUE,
    SCHEMA_VERSION,
    SIGNING_KEY_CONTEXT,
)


class ProtocolError(RuntimeError):
    pass


def normalize_origin(raw_value: str) -> str:
    if not isinstance(raw_value, str):
        raise ProtocolError("server URL must be an HTTPS origin")
    value = raw_value.strip()
    if value != raw_value or not value or "%" in value:
        raise ProtocolError("server URL must be an HTTPS origin")
    try:
        value.encode("ascii")
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except (UnicodeError, ValueError):
        raise ProtocolError("server URL must be an ASCII HTTPS origin") from None
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in ("", "/")
    ):
        raise ProtocolError("server URL must be an HTTPS origin")
    host = parsed.hostname.lower()
    if any(character.isspace() for character in host):
        raise ProtocolError("server URL must be an HTTPS origin")
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    authority = host if port is None else f"{host}:{port}"
    return f"https://{authority}"


def endpoint(origin: str, path: str) -> str:
    normalized = normalize_origin(origin)
    if not path.startswith("/") or "?" in path or "#" in path:
        raise ProtocolError("invalid API path")
    return normalized + path


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def generated_at(now: datetime | None = None) -> str:
    current = now or datetime.now(timezone.utc)
    current = current.astimezone(timezone.utc)
    return current.isoformat(timespec="microseconds").replace("+00:00", "Z")


def signed_headers(
    *,
    device_id: str,
    device_secret: str,
    body: bytes,
    timestamp: int | None = None,
    nonce: str | None = None,
    method: str = "POST",
    path: str = DAILY_USAGE_PATH,
) -> dict[str, str]:
    timestamp_text = str(int(time.time()) if timestamp is None else timestamp)
    nonce_value = nonce or str(uuid.uuid4())
    if not re.fullmatch(r"[A-Za-z0-9_-]{16,128}", nonce_value):
        raise ProtocolError("invalid request nonce")
    body_hash = hashlib.sha256(body).hexdigest()
    canonical = "\n".join(
        [timestamp_text, nonce_value, method.upper(), path, body_hash]
    ).encode("utf-8")
    signing_key = hashlib.sha256(
        SIGNING_KEY_CONTEXT + device_secret.encode("utf-8")
    ).digest()
    signature = hmac.new(signing_key, canonical, hashlib.sha256).hexdigest()
    return {
        "Content-Type": "application/json",
        "X-Device-ID": device_id,
        "X-Timestamp": timestamp_text,
        "X-Nonce": nonce_value,
        "X-Signature": signature,
    }


def validate_label(value: str) -> str:
    if not isinstance(value, str):
        raise ProtocolError("usage label is invalid")
    trimmed = value.strip()
    forbidden = {"Cc", "Cf", "Cs", "Zl", "Zp"}
    if (
        not trimmed
        or trimmed != value
        or len(value) > 128
        or "\x1f" in value
        or any(unicodedata.category(character) in forbidden for character in value)
    ):
        raise ProtocolError("usage label is invalid")
    return value


def validate_bucket(bucket: dict[str, Any]) -> dict[str, Any]:
    expected = {
        "date",
        "timezone",
        "tool",
        "model",
        "source",
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
        "completeness",
    }
    if set(bucket) != expected:
        raise ProtocolError("usage bucket fields are invalid")
    try:
        datetime.strptime(bucket["date"], "%Y-%m-%d")
    except (TypeError, ValueError) as exc:
        raise ProtocolError("usage bucket date is invalid") from exc
    if bucket["timezone"] != "Asia/Shanghai":
        raise ProtocolError("usage bucket timezone is invalid")
    validate_label(bucket["tool"])
    validate_label(bucket["model"])
    if bucket["source"] != "local" or bucket["completeness"] != "exact":
        raise ProtocolError("usage bucket source or completeness is invalid")
    counts = [
        bucket["input_tokens"],
        bucket["output_tokens"],
        bucket["cache_read_tokens"],
        bucket["cache_write_tokens"],
    ]
    if any(type(count) is not int or not 0 <= count <= MAX_TOKEN_VALUE for count in counts):
        raise ProtocolError("usage bucket token count is invalid")
    return bucket


def daily_payload(
    buckets: Iterable[dict[str, Any]],
    *,
    collector_version: str,
    generated: str | None = None,
) -> dict[str, Any]:
    validated = [validate_bucket(dict(bucket)) for bucket in buckets]
    if not validated:
        raise ProtocolError("at least one exact bucket is required")
    natural_keys: set[tuple[str, ...]] = set()
    for bucket in validated:
        key = tuple(
            bucket[field] for field in ("date", "timezone", "tool", "model", "source")
        )
        if key in natural_keys:
            raise ProtocolError("usage payload contains duplicate buckets")
        natural_keys.add(key)
    return {
        "schema_version": SCHEMA_VERSION,
        "collector_version": collector_version,
        "generated_at": generated or generated_at(),
        "buckets": validated,
    }


def validate_ingest_response(value: Any, *, expected_count: int) -> dict[str, int]:
    expected = {"created", "updated", "unchanged", "ledger_version"}
    if not isinstance(value, dict) or set(value) != expected:
        raise ProtocolError("server returned an invalid sync response")
    if any(type(value[field]) is not int or value[field] < 0 for field in expected):
        raise ProtocolError("server returned an invalid sync response")
    if value["created"] + value["updated"] + value["unchanged"] != expected_count:
        raise ProtocolError("server did not account for every uploaded bucket")
    return value
