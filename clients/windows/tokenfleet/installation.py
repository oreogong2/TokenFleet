from __future__ import annotations

import hashlib
import hmac
import ipaddress
import json
import re
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any


CONFIG_SCHEMA_VERSION = 1
CONFIG_FILE_NAME = "community.json"
CONFIG_DIGEST_FILE_NAME = "community.sha256"
_CONFIG_DIGEST_CONTEXT = b"TokenFleet Windows community configuration v1\n"
_MAX_CONFIG_BYTES = 4_096
_DNS_LABEL = re.compile(r"[a-z0-9-]+")
_NUMERIC_IP_COMPONENT = re.compile(r"(?:0x[0-9a-f]+|[0-9]+)")


class InstallationConfigError(RuntimeError):
    pass


def canonical_community_origin(raw: str) -> str:
    """Accept only a canonical, public DNS HTTPS origin.

    The source installer is the only supported place to choose this value.
    Keeping the accepted grammar deliberately narrow prevents URL parser
    ambiguities and stops a one-time enrollment code being redirected to a
    command-line supplied host.
    """

    if (
        not isinstance(raw, str)
        or not raw
        or raw != raw.strip()
        or not raw.isascii()
        or "%" in raw
        or not raw.startswith("https://")
    ):
        raise InstallationConfigError("community server must be a canonical HTTPS origin")
    try:
        parsed = urllib.parse.urlsplit(raw)
        host = parsed.hostname
        port = parsed.port
    except ValueError:
        raise InstallationConfigError(
            "community server must be a canonical HTTPS origin"
        ) from None
    if (
        parsed.scheme != "https"
        or not host
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path
        or parsed.query
        or parsed.fragment
    ):
        raise InstallationConfigError("community server must be a canonical HTTPS origin")

    authority = raw[len("https://") :]
    if authority.count(":") > 1:
        raise InstallationConfigError("community server must use a public DNS name")
    if ":" in authority:
        raw_host, raw_port = authority.rsplit(":", 1)
        if (
            not raw_port
            or not raw_port.isdecimal()
            or not raw_port.isascii()
            or not 1 <= int(raw_port, 10) <= 65_535
            or str(int(raw_port, 10)) != raw_port
        ):
            raise InstallationConfigError(
                "community server must be a canonical HTTPS origin"
            )
        parsed_port: int | None = int(raw_port, 10)
    else:
        raw_host = authority
        parsed_port = None
    if raw_host != host or parsed_port != port or port == 443:
        raise InstallationConfigError("community server must be a canonical HTTPS origin")
    if host != host.lower() or host.endswith(".") or len(host) > 253:
        raise InstallationConfigError("community server must use a public DNS name")
    if host == "localhost" or host.endswith(".localhost"):
        raise InstallationConfigError("community server must use a public DNS name")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise InstallationConfigError("community server must use a public DNS name")

    labels = host.split(".")
    looks_numeric = 1 <= len(labels) <= 4 and all(
        _NUMERIC_IP_COMPONENT.fullmatch(label) is not None for label in labels
    )
    if (
        len(labels) < 2
        or looks_numeric
        or any(
            not label
            or len(label) > 63
            or label.startswith("-")
            or label.endswith("-")
            or _DNS_LABEL.fullmatch(label) is None
            for label in labels
        )
    ):
        raise InstallationConfigError("community server must use a public DNS name")

    expected = f"https://{host}" + (f":{port}" if port is not None else "")
    if raw != expected or parsed.geturl() != raw:
        raise InstallationConfigError("community server must be a canonical HTTPS origin")
    return raw


def _encoded_config(origin: str) -> bytes:
    value = {
        "community_server": canonical_community_origin(origin),
        "schema_version": CONFIG_SCHEMA_VERSION,
    }
    return (
        json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("ascii")


def _digest(payload: bytes) -> str:
    return hashlib.sha256(_CONFIG_DIGEST_CONTEXT + payload).hexdigest()


def install_config_artifacts(origin: str) -> tuple[bytes, bytes]:
    payload = _encoded_config(origin)
    return payload, (_digest(payload) + "\n").encode("ascii")


@dataclass(frozen=True)
class CommunityInstallationConfig:
    community_server: str
    schema_version: int = CONFIG_SCHEMA_VERSION


class CommunityInstallationConfigStore:
    def __init__(self, config_path: Path, digest_path: Path) -> None:
        self.config_path = config_path
        self.digest_path = digest_path

    @property
    def exists(self) -> bool:
        return self.config_path.is_file() or self.digest_path.is_file()

    def load(self) -> CommunityInstallationConfig:
        try:
            payload = self.config_path.read_bytes()
            digest_payload = self.digest_path.read_bytes()
        except FileNotFoundError as exc:
            raise InstallationConfigError(
                "TokenFleet community configuration is incomplete; reinstall the client"
            ) from exc
        except OSError as exc:
            raise InstallationConfigError(
                "TokenFleet community configuration is unreadable; reinstall the client"
            ) from exc
        if not payload or len(payload) > _MAX_CONFIG_BYTES:
            raise InstallationConfigError(
                "TokenFleet community configuration is invalid; reinstall the client"
            )
        try:
            digest_text = digest_payload.decode("ascii")
        except UnicodeError as exc:
            raise InstallationConfigError(
                "TokenFleet community configuration integrity check failed"
            ) from exc
        expected_digest = _digest(payload) + "\n"
        if not hmac.compare_digest(digest_text, expected_digest):
            raise InstallationConfigError(
                "TokenFleet community configuration integrity check failed"
            )
        try:
            value: Any = json.loads(payload.decode("ascii"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise InstallationConfigError(
                "TokenFleet community configuration is invalid; reinstall the client"
            ) from exc
        if not isinstance(value, dict) or set(value) != {
            "community_server",
            "schema_version",
        }:
            raise InstallationConfigError(
                "TokenFleet community configuration is invalid; reinstall the client"
            )
        if value.get("schema_version") != CONFIG_SCHEMA_VERSION or not isinstance(
            value.get("community_server"), str
        ):
            raise InstallationConfigError(
                "TokenFleet community configuration is invalid; reinstall the client"
            )
        origin = canonical_community_origin(value["community_server"])
        if payload != _encoded_config(origin):
            raise InstallationConfigError(
                "TokenFleet community configuration is non-canonical; reinstall the client"
            )
        return CommunityInstallationConfig(community_server=origin)


def validate_install_request(
    proposed_origin: str,
    *,
    config_path: Path,
    digest_path: Path,
    credential_path: Path,
) -> str:
    """Read-only install/upgrade preflight used by install.ps1.

    A current install must keep its original pinned origin. An installation
    made before the pinned configuration existed is migrated only when its
    DPAPI-protected credential (if present) names the same origin.
    """

    proposed = canonical_community_origin(proposed_origin)
    store = CommunityInstallationConfigStore(config_path, digest_path)
    if store.exists:
        if store.load().community_server != proposed:
            raise InstallationConfigError(
                "TokenFleet is already pinned to a different community server"
            )
        return proposed
    if credential_path.is_file():
        # Import lazily so cross-platform tests never initialize Windows DPAPI.
        from .credential import CredentialStore

        credential = CredentialStore(credential_path).load()
        try:
            existing = canonical_community_origin(credential.server_origin)
        except InstallationConfigError as exc:
            raise InstallationConfigError(
                "the existing TokenFleet credential has an invalid community server"
            ) from exc
        if existing != proposed:
            raise InstallationConfigError(
                "TokenFleet is already connected to a different community server"
            )
    return proposed
