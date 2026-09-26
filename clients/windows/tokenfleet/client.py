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
    COLLECTOR_VERSION,
    COMMUNITY_RANK_PATH,
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
    NetworkError,
    community_rank_endpoint,
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
from .state import ClientState, StateStore
from .machine_identity import current_machine_fingerprint
from datetime import datetime, timezone
from .settings import ClientSettings, SettingsStore


class SyncTransport(Protocol):
    def post(
        self,
        url: str,
        value: dict[str, Any],
        *,
        headers: dict[str, str] | None = None,
        expected_status: int,
    ) -> Any: ...

    def get(
        self,
        url: str,
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
        settings_store: SettingsStore | None = None,
        cursor_archive: Path | None = None,
        machine_fingerprint: Callable[[], str] = current_machine_fingerprint,
    ) -> None:
        self.credential_store = credential_store
        self.state_store = state_store
        self.source_home = source_home
        self.community_origin = canonical_community_origin(community_origin)
        self.transport = transport or HTTPSJSONTransport()
        self.collector = collector
        self.sleeper = sleeper
        self.settings_store = settings_store
        self.cursor_archive = cursor_archive
        self.machine_fingerprint = machine_fingerprint

    def connect(self, *, enrollment_token: str) -> DeviceCredential:
        state = self._machine_state()
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
            "machine_fingerprint": state.machine_fingerprint,
        }
        response = self._machine_request(lambda: self.transport.post(
            enrollment_endpoint(origin),
            request,
            expected_status=201,
        ))
        credential = self._enrollment_credential(
            response, expected_public_id=state.device_public_id, origin=origin
        )
        self.credential_store.save(credential)
        state.reconnect_required = False
        state.last_sync_error = None
        self.state_store.save(state)
        return credential

    def preview(self, *, history_days: int = 366) -> CollectionResult:
        experimental = (
            self.settings_store.load().experimental_sources_enabled
            if self.settings_store
            else ClientSettings().experimental_sources_enabled
        )
        return self.collector(
            self.source_home,
            history_days=history_days,
            include_experimental=experimental,
            cursor_archive=self.cursor_archive,
        )

    def sync(self, *, history_days: int = 366) -> SyncSummary:
        try:
            summary = self._sync_once(history_days=history_days)
        except Exception as error:
            state = self.state_store.load()
            state.last_sync_attempt_at = generated_at()
            state.consecutive_sync_failures += 1
            status = error.status if isinstance(error, NetworkError) else None
            state.last_sync_error = state.last_sync_error if state.reconnect_required else (
                f"同步失败（HTTP {status}），请检查连接状态" if status in (401, 403)
                else "同步暂未成功，计划任务会重试；可运行 tokenfleet sync"
            )
            self.state_store.save(state)
            raise
        state = self.state_store.load()
        state.last_sync_attempt_at = summary.generated_at
        state.last_sync_error = None
        state.consecutive_sync_failures = 0
        self.state_store.save(state)
        return summary

    def _sync_once(self, *, history_days: int = 366) -> SyncSummary:
        credential = self._credential_for_pinned_origin()
        result = self.preview(history_days=history_days)
        generated = generated_at()
        if not result.buckets:
            state = self.state_store.load()
            state.last_sync_at = generated
            state.last_bucket_count = 0
            state.last_uploaded_tokens = 0
            state.last_omitted_bucket_count = 0
            self.state_store.save(state)
            return SyncSummary(0, 0, 0, 0, 0, 0, generated)

        totals = {"created": 0, "updated": 0, "unchanged": 0, "ledger_version": 0}
        acknowledged_count = 0
        acknowledged_tokens = 0
        omitted_count = 0
        chunks = self._chunks(result.buckets, generated=generated)
        for index, buckets in enumerate(chunks):
            if index and index % 11 == 0:
                # The server's default authenticated device budget is 12/min.
                self.sleeper(61.0)
            clock_offset = 0
            authentication_retries = 0
            validation_retries = 0
            validated = None
            while buckets:
                payload = daily_payload(buckets, collector_version=COLLECTOR_VERSION, generated=generated)
                body = canonical_json(payload)
                headers = signed_headers(
                    device_id=credential.device_id, device_secret=credential.device_secret,
                    body=body, path=DAILY_USAGE_PATH, timestamp=int(time.time()) + clock_offset,
                    machine_fingerprint=self.state_store.load().machine_fingerprint,
                )
                try:
                    response = self._machine_request(lambda: self.transport.post_bytes(
                        usage_endpoint(credential.server_origin), body, headers=headers, expected_status=200,
                    ))
                except NetworkError as error:
                    if error.status == 401 and authentication_retries == 0:
                        authentication_retries += 1
                        if error.server_time is not None:
                            clock_offset = error.server_time - int(time.time())
                        continue
                    rejected = {i for i in error.rejected_indices if 0 <= i < len(buckets)}
                    if error.status == 422 and rejected and validation_retries < 2:
                        validation_retries += 1
                        omitted_count += len(rejected)
                        buckets = [bucket for i, bucket in enumerate(buckets) if i not in rejected]
                        continue
                    raise
                validated = validate_ingest_response(response, expected_count=len(buckets))
                break
            if validated is None:
                continue
            acknowledged_count += len(buckets)
            acknowledged_tokens += sum(sum(bucket[field] for field in ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")) for bucket in buckets)
            for field in ("created", "updated", "unchanged"):
                totals[field] += validated[field]
            totals["ledger_version"] = max(
                totals["ledger_version"], validated["ledger_version"]
            )

        state = self.state_store.load()
        state.last_sync_at = generated
        state.last_bucket_count = acknowledged_count
        state.last_uploaded_tokens = acknowledged_tokens
        state.last_omitted_bucket_count = omitted_count
        self.state_store.save(state)
        return SyncSummary(
            buckets=acknowledged_count,
            total_tokens=acknowledged_tokens,
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

    def community_rank(self) -> dict[str, Any]:
        credential = self._credential_for_pinned_origin()
        headers = signed_headers(
            device_id=credential.device_id,
            device_secret=credential.device_secret,
            body=b"",
            method="GET",
            path=COMMUNITY_RANK_PATH,
            machine_fingerprint=self.state_store.load().machine_fingerprint,
        )
        headers.pop("Content-Type", None)
        value = self._machine_request(lambda: self.transport.get(
            community_rank_endpoint(credential.server_origin),
            headers=headers,
            expected_status=200,
        ))
        return self._validate_community_rank(value)

    def additional_device_code(self) -> dict[str, str]:
        credential = self._credential_for_pinned_origin()
        path = "/api/v1/devices/me/enrollment-tokens"
        body = b"{}"
        headers = signed_headers(device_id=credential.device_id, device_secret=credential.device_secret,
                                 body=body, path=path, machine_fingerprint=self.state_store.load().machine_fingerprint)
        value = self._machine_request(lambda: self.transport.post_bytes(
            credential.server_origin + path, body, headers=headers, expected_status=201))
        if (not isinstance(value, dict) or set(value) != {"enrollment_token", "expires_at"}
            or not isinstance(value["enrollment_token"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", value["enrollment_token"])
            or not isinstance(value["expires_at"], str)):
            raise ProtocolError("服务器返回的添加设备码无效")
        try:
            expires = datetime.fromisoformat(value["expires_at"].replace("Z", "+00:00"))
            seconds = (expires - datetime.now(timezone.utc)).total_seconds()
            if not 0 < seconds <= (15 + 5 + 1) * 60:
                raise ValueError("invalid expiry")
        except (ValueError, TypeError) as error:
            raise ProtocolError("服务器返回的添加设备码无效") from error
        return value

    def validate_machine_binding(self) -> None:
        self._machine_state()

    def _machine_state(self) -> ClientState:
        fingerprint = self.machine_fingerprint()
        if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
            raise ProtocolError("无法确认当前机器身份，尚未发送数据")
        state = self.state_store.load()
        if state.machine_fingerprint is not None and state.machine_fingerprint != fingerprint:
            self._reset_machine_binding(fingerprint)
            raise ProtocolError("这是一台新设备，请用原设备的添加设备码重新连接")
        if state.machine_fingerprint is None:
            state.machine_fingerprint = fingerprint
            self.state_store.save(state)
        return state

    def _reset_machine_binding(self, fingerprint: str) -> None:
        # Only this app's local device credential is removed; raw usage remains.
        self.credential_store.clear()
        state = ClientState.new()
        state.machine_fingerprint = fingerprint
        state.reconnect_required = True
        state.last_sync_error = "这是一台新设备，请用原设备的添加设备码重新连接"
        self.state_store.save(state)

    def _machine_request(self, request: Callable[[], Any]) -> Any:
        try:
            return request()
        except NetworkError as error:
            if error.machine_mismatch:
                self._reset_machine_binding(self._machine_state().machine_fingerprint)
                raise ProtocolError("这是一台新设备，请用原设备的添加设备码重新连接") from None
            raise

    @staticmethod
    def _validate_community_rank(value: Any) -> dict[str, Any]:
        expected = {
            "public_id",
            "nickname",
            "public_profile_enabled",
            "period",
            "metric",
            "rank",
            "total_entries",
            "metric_value",
            "primary_tool",
            "primary_model",
            "totals",
        }
        if not isinstance(value, dict) or set(value) != expected:
            raise ProtocolError("server returned an invalid rank response")
        if (
            not isinstance(value["public_id"], str)
            or not value["public_id"]
            or (
                value["nickname"] is not None
                and (
                    not isinstance(value["nickname"], str)
                    or not 1 <= len(value["nickname"]) <= 128
                )
            )
            or type(value["public_profile_enabled"]) is not bool
            or value["period"] != "today"
            or value["metric"] != "tokens"
            or type(value["total_entries"]) is not int
            or value["total_entries"] < 0
            or (
                value["rank"] is not None
                and (type(value["rank"]) is not int or value["rank"] < 1)
            )
            or (
                value["metric_value"] is not None
                and (
                    not isinstance(value["metric_value"], str)
                    or not value["metric_value"].isdigit()
                )
            )
            or (
                value["rank"] is not None
                and value["rank"] > value["total_entries"]
            )
            or any(
                item is not None
                and (
                    not isinstance(item, str)
                    or not 1 <= len(item) <= 128
                )
                for item in (value["primary_tool"], value["primary_model"])
            )
        ):
            raise ProtocolError("server returned an invalid rank response")
        totals = value["totals"]
        if totals is not None:
            required_totals = {
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "norm_tokens",
                "total_tokens",
                "estimated_cost_microunits",
                "cost_currency",
                "unpriced",
                "mixed_currency",
            }
            if not isinstance(totals, dict) or set(totals) != required_totals:
                raise ProtocolError("server returned an invalid rank response")
            for field in (
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "norm_tokens",
                "total_tokens",
            ):
                if not isinstance(totals[field], str) or not totals[field].isdigit():
                    raise ProtocolError("server returned an invalid rank response")
            estimated_cost = totals["estimated_cost_microunits"]
            currency = totals["cost_currency"]
            if (
                estimated_cost is not None
                and (
                    not isinstance(estimated_cost, str)
                    or not estimated_cost.isdigit()
                )
            ) or (
                currency is not None
                and (not isinstance(currency, str) or len(currency) != 3)
            ) or type(totals["unpriced"]) is not bool or type(
                totals["mixed_currency"]
            ) is not bool:
                raise ProtocolError("server returned an invalid rank response")
        return value

    def _credential_for_pinned_origin(self) -> DeviceCredential:
        self._machine_state()
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
