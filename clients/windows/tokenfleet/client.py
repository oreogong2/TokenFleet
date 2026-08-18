from __future__ import annotations

import re
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Protocol

from .collectors import CollectionResult, collect_usage
from .constants import (
    APP_VERSION,
    ADDITIONAL_DEVICE_ENROLLMENT_PATH,
    COLLECTOR_VERSION,
    DAILY_USAGE_PATH,
    MAX_BUCKETS_PER_REQUEST,
    MAX_UPLOAD_BODY_BYTES,
    PUBLIC_RANK_PATH,
    SCHEMA_VERSION,
    SIGNING_KEY_DERIVATION,
)
from .credential import CredentialStore, DeviceCredential
from .http_client import (
    HTTPSJSONTransport,
    additional_device_enrollment_endpoint,
    enrollment_endpoint,
    usage_endpoint,
)
from .installation import InstallationConfigError, canonical_community_origin
from .protocol import (
    ProtocolError,
    canonical_json,
    daily_payload,
    generated_at,
    signed_headers,
    validate_ingest_response,
)
from .state import StateStore


class SyncTransport(Protocol):
    def post(
        self,
        url: str,
        value: dict[str, Any],
        *,
        headers: dict[str, str] | None = None,
        expected_status: int,
    ) -> Any: ...

    def post_bytes(
        self,
        url: str,
        body: bytes,
        *,
        headers: dict[str, str] | None = None,
        expected_status: int,
    ) -> Any: ...


@dataclass(frozen=True)
class SyncSummary:
    buckets: int
    total_tokens: int
    created: int
    updated: int
    unchanged: int
    ledger_version: int
    generated_at: str


class TokenFleetClient:
    def __init__(
        self,
        *,
        credential_store: CredentialStore,
        state_store: StateStore,
        source_home: Path,
        community_origin: str,
        transport: SyncTransport | None = None,
        collector: Callable[..., CollectionResult] = collect_usage,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        self.credential_store = credential_store
        self.state_store = state_store
        self.source_home = source_home
        self.community_origin = canonical_community_origin(community_origin)
        self.transport = transport or HTTPSJSONTransport()
        self.collector = collector
        self.sleeper = sleeper

    def connect(self, *, enrollment_token: str) -> DeviceCredential:
        origin = self.community_origin
        token = enrollment_token.strip()
        if token != enrollment_token or not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
            raise ProtocolError("一次性接入码格式无效")

        # Re-enrollment may replace a credential only inside the community
        # pinned by the installed app. In particular, refuse before prepare()
        # or any request if per-user storage points at a different origin.
        if self.credential_store.exists:
            self._credential_for_pinned_origin()

        # Prove DPAPI and the target directory work before consuming the
        # server-side one-time code.
        self.credential_store.prepare()
        state = self.state_store.load()
        self.state_store.save(state)
        request = {
            "enrollment_token": token,
            "device_public_id": state.device_public_id,
            "platform": "windows",
            "app_version": APP_VERSION,
            "collector_version": COLLECTOR_VERSION,
        }
        response = self.transport.post(
            enrollment_endpoint(origin),
            request,
            expected_status=201,
        )
        credential = self._enrollment_credential(
            response, expected_public_id=state.device_public_id, origin=origin
        )
        self.credential_store.save(credential)
        return credential

    def preview(self, *, history_days: int = 366) -> CollectionResult:
        return self.collector(self.source_home, history_days=history_days)

    def issue_additional_device_code(self) -> str:
        credential = self._credential_for_pinned_origin()
        body = canonical_json({})
        headers = signed_headers(
            device_id=credential.device_id,
            device_secret=credential.device_secret,
            body=body,
            path=ADDITIONAL_DEVICE_ENROLLMENT_PATH,
        )
        response = self.transport.post_bytes(
            additional_device_enrollment_endpoint(credential.server_origin),
            body,
            headers=headers,
            expected_status=201,
        )
        if not isinstance(response, dict) or set(response) != {
            "enrollment_token",
            "expires_at",
        }:
            raise ProtocolError("服务器返回了无效的新设备码")
        token = response.get("enrollment_token")
        expires_at = response.get("expires_at")
        if (
            not isinstance(token, str)
            or not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token)
            or not isinstance(expires_at, str)
            or not 1 <= len(expires_at) <= 64
            or any(ord(character) < 32 or ord(character) >= 127 for character in expires_at)
        ):
            raise ProtocolError("服务器返回了无效的新设备码")
        return token

    def sync(self, *, history_days: int = 366) -> SyncSummary:
        credential = self._credential_for_pinned_origin()
        result = self.preview(history_days=history_days)
        generated = generated_at()
        total_tokens = result.total_tokens
        if not result.buckets:
            state = self.state_store.load()
            state.last_sync_at = generated
            state.last_bucket_count = 0
            state.last_uploaded_tokens = 0
            self.state_store.save(state)
            return SyncSummary(0, 0, 0, 0, 0, 0, generated)

        totals = {"created": 0, "updated": 0, "unchanged": 0, "ledger_version": 0}
        chunks = self._chunks(result.buckets, generated=generated)
        for index, buckets in enumerate(chunks):
            if index and index % 11 == 0:
                # The server's default authenticated device budget is 12/min.
                self.sleeper(61.0)
            payload = daily_payload(
                buckets,
                collector_version=COLLECTOR_VERSION,
                generated=generated,
            )
            body = canonical_json(payload)
            headers = signed_headers(
                device_id=credential.device_id,
                device_secret=credential.device_secret,
                body=body,
                path=DAILY_USAGE_PATH,
            )
            response = self.transport.post_bytes(
                usage_endpoint(credential.server_origin),
                body,
                headers=headers,
                expected_status=200,
            )
            validated = validate_ingest_response(response, expected_count=len(buckets))
            for field in ("created", "updated", "unchanged"):
                totals[field] += validated[field]
            totals["ledger_version"] = max(
                totals["ledger_version"], validated["ledger_version"]
            )

        state = self.state_store.load()
        state.last_sync_at = generated
        state.last_bucket_count = len(result.buckets)
        state.last_uploaded_tokens = total_tokens
        self.state_store.save(state)
        return SyncSummary(
            buckets=len(result.buckets),
            total_tokens=total_tokens,
            created=totals["created"],
            updated=totals["updated"],
            unchanged=totals["unchanged"],
            ledger_version=totals["ledger_version"],
            generated_at=generated,
        )

    @staticmethod
    def _chunks(
        buckets: list[dict[str, Any]], *, generated: str
    ) -> list[list[dict[str, Any]]]:
        empty_envelope = {
            "schema_version": SCHEMA_VERSION,
            "collector_version": COLLECTOR_VERSION,
            "generated_at": generated,
            "buckets": [],
        }
        fixed_size = len(canonical_json(empty_envelope)) - 2
        chunks: list[list[dict[str, Any]]] = []
        current: list[dict[str, Any]] = []
        current_items_size = 0
        for bucket in buckets:
            bucket_size = len(canonical_json(bucket))
            candidate_items_size = current_items_size + bucket_size + (1 if current else 0)
            candidate_size = fixed_size + 2 + candidate_items_size
            if current and (
                len(current) >= MAX_BUCKETS_PER_REQUEST
                or candidate_size > MAX_UPLOAD_BODY_BYTES
            ):
                chunks.append(current)
                current = []
                current_items_size = 0
                candidate_items_size = bucket_size
                candidate_size = fixed_size + 2 + bucket_size
            if candidate_size > MAX_UPLOAD_BODY_BYTES:
                raise ProtocolError("单个聚合桶超过安全上传大小")
            current.append(bucket)
            current_items_size = candidate_items_size
        if current:
            chunks.append(current)
        return chunks

    def rank_url(self) -> str:
        credential = self._credential_for_pinned_origin()
        return credential.server_origin + PUBLIC_RANK_PATH

    def _credential_for_pinned_origin(self) -> DeviceCredential:
        credential = self.credential_store.load()
        try:
            stored_origin = canonical_community_origin(credential.server_origin)
        except InstallationConfigError as exc:
            raise ProtocolError(
                "本机设备凭据中的社群地址无效；请卸载后重新安装"
            ) from exc
        if stored_origin != self.community_origin:
            raise ProtocolError(
                "本机设备凭据与安装时固定的社群地址不一致；已拒绝联网"
            )
        return credential

    @staticmethod
    def _enrollment_credential(
        value: Any, *, expected_public_id: str, origin: str
    ) -> DeviceCredential:
        expected = {
            "device_id",
            "device_public_id",
            "device_secret",
            "signing_key_derivation",
        }
        if not isinstance(value, dict) or set(value) != expected:
            raise ProtocolError("服务器返回了无效的设备登记结果")
        if value.get("device_public_id") != expected_public_id:
            raise ProtocolError("服务器返回的设备身份不匹配")
        if value.get("signing_key_derivation") != SIGNING_KEY_DERIVATION:
            raise ProtocolError("服务器返回了不支持的签名算法")
        try:
            device_id = str(uuid.UUID(value["device_id"]))
            public_id = str(uuid.UUID(value["device_public_id"]))
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            raise ProtocolError("服务器返回了无效的设备身份") from exc
        secret = value.get("device_secret")
        if not isinstance(secret, str) or not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", secret):
            raise ProtocolError("服务器返回了无效的设备凭据")
        return DeviceCredential(
            server_origin=origin,
            device_id=device_id,
            device_public_id=public_id,
            device_secret=secret,
        ).validate()
