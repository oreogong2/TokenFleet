#!/usr/bin/env python3
"""Validate TokenFleet's fixed production community origin.

The production contract intentionally accepts DNS hostnames only.  Raw IPs,
legacy numeric IP aliases, single-label names, and localhost names are rejected
so a signed release cannot silently point at a machine-local endpoint.
"""

from __future__ import annotations

import argparse
import ipaddress
import re
from pathlib import Path
from urllib.parse import urlsplit


_DNS_LABEL = re.compile(r"[a-z0-9-]+")
_NUMERIC_IP_COMPONENT = re.compile(r"(?:0x[0-9a-f]+|[0-9]+)")


def _split_canonical_port(authority: str) -> tuple[str, int | None]:
    if authority.count(":") > 1:
        raise ValueError("production origins do not accept IP literals")
    if ":" not in authority:
        return authority, None
    host, raw_port = authority.rsplit(":", 1)
    if not raw_port or not raw_port.isascii() or not raw_port.isdecimal():
        raise ValueError("invalid port")
    port = int(raw_port, 10)
    if not 1 <= port <= 65535 or str(port) != raw_port:
        raise ValueError("port is not canonical")
    return host, port


def _looks_like_legacy_numeric_ip_alias(host: str) -> bool:
    labels = host.split(".")
    return 1 <= len(labels) <= 4 and all(
        _NUMERIC_IP_COMPONENT.fullmatch(label) is not None for label in labels
    )


def is_valid_production_origin(raw: str) -> bool:
    try:
        if (
            not raw
            or raw != raw.strip()
            or not raw.isascii()
            or "%" in raw
            or not raw.startswith("https://")
        ):
            return False

        parsed = urlsplit(raw)
        host = parsed.hostname
        port = parsed.port
        if (
            parsed.scheme != "https"
            or not host
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path
            or parsed.query
            or parsed.fragment
        ):
            return False

        authority = raw[len("https://") :]
        raw_host, raw_port = _split_canonical_port(authority)
        if raw_host != host or raw_port != port or port == 443:
            return False
        if host != host.lower() or host.endswith(".") or len(host) > 253:
            return False
        if host == "localhost" or host.endswith(".localhost"):
            return False

        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            return False

        labels = host.split(".")
        if len(labels) < 2 or _looks_like_legacy_numeric_ip_alias(host):
            return False
        if any(
            not label
            or len(label) > 63
            or label.startswith("-")
            or label.endswith("-")
            or _DNS_LABEL.fullmatch(label) is None
            for label in labels
        ):
            return False

        expected = f"https://{host}" + (f":{port}" if port is not None else "")
        return raw == expected and parsed.geturl() == raw
    except (TypeError, ValueError):
        return False


def is_valid_testing_origin(raw: str) -> bool:
    if is_valid_production_origin(raw):
        return True
    try:
        if (
            not raw
            or raw != raw.strip()
            or not raw.isascii()
            or "%" in raw
            or not raw.startswith("http://")
        ):
            return False
        parsed = urlsplit(raw)
        if (
            parsed.scheme != "http"
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path
            or parsed.query
            or parsed.fragment
            or parsed.port is None
            or parsed.port == 80
        ):
            return False
        host = parsed.hostname
        if host not in {"127.0.0.1", "::1"}:
            return False
        display_host = "[::1]" if host == "::1" else host
        expected = f"http://{display_host}:{parsed.port}"
        return raw == expected and parsed.geturl() == raw
    except (TypeError, ValueError):
        return False


def verify_fixture(path: Path) -> None:
    failures: list[str] = []
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw_line or raw_line.startswith("#"):
            continue
        try:
            mode, expected_text, encoded_value = raw_line.split("\t", 2)
        except ValueError:
            failures.append(f"line {line_number}: expected three tab-separated fields")
            continue
        value = "" if encoded_value == "<EMPTY>" else encoded_value
        validator = {
            "production": is_valid_production_origin,
            "testing": is_valid_testing_origin,
        }.get(mode)
        if validator is None or expected_text not in {"valid", "invalid"}:
            failures.append(f"line {line_number}: invalid mode or expectation")
            continue
        actual = validator(value)
        expected = expected_text == "valid"
        if actual != expected:
            failures.append(
                f"line {line_number}: {mode} expected {expected_text}: {encoded_value}"
            )
    if failures:
        raise SystemExit("\n".join(failures))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("origin", nargs="?")
    parser.add_argument("--verify-fixture", type=Path)
    args = parser.parse_args()
    if args.verify_fixture is not None:
        verify_fixture(args.verify_fixture)
        return
    if args.origin is None:
        parser.error("origin is required")
    if not is_valid_production_origin(args.origin):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
