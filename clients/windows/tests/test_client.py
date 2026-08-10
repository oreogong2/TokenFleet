from __future__ import annotations

import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path
from typing import Any
from unittest import mock

from tokenfleet.client import TokenFleetClient
from tokenfleet.collectors import CollectionDiagnostics, CollectionResult
from tokenfleet.constants import DAILY_USAGE_PATH, SIGNING_KEY_DERIVATION
from tokenfleet.credential import DeviceCredential
from tokenfleet.paths import ClientPaths
from tokenfleet.protocol import canonical_json, signed_headers
from tokenfleet.protocol import ProtocolError
from tokenfleet.state import StateStore


class MemoryDeviceStore:
    def __init__(self, value: DeviceCredential | None = None) -> None:
        self.value = value
        self.events: list[str] = []

    @property
    def exists(self) -> bool:
        return self.value is not None

    def prepare(self) -> None:
        self.events.append("prepare")

    def save(self, value: DeviceCredential) -> None:
        self.events.append("save")
        self.value = value

    def load(self) -> DeviceCredential:
        self.events.append("load")
        assert self.value is not None
        return self.value


class FixtureTransport:
    def __init__(self, public_id: str) -> None:
        self.public_id = public_id
        self.requests: list[tuple[str, dict[str, Any]]] = []
        self.uploads: list[tuple[str, bytes, dict[str, str]]] = []

    def post(
        self,
        url: str,
        value: dict[str, Any],
        *,
        headers: dict[str, str] | None = None,
        expected_status: int,
    ) -> Any:
        self.requests.append((url, value))
        return {
            "device_id": "11111111-1111-4111-8111-111111111111",
            "device_public_id": self.public_id,
            "device_secret": "fixture_device_value_1234567890",
            "signing_key_derivation": SIGNING_KEY_DERIVATION,
        }

    def post_bytes(
        self,
        url: str,
        body: bytes,
        *,
        headers: dict[str, str] | None = None,
        expected_status: int,
    ) -> Any:
        assert headers is not None
        self.uploads.append((url, body, headers))
        count = len(json.loads(body)["buckets"])
        return {"created": count, "updated": 0, "unchanged": 0, "ledger_version": 7}


class ClientTests(unittest.TestCase):
    bucket = {
        "date": "2026-08-09",
        "timezone": "Asia/Shanghai",
        "tool": "Codex",
        "model": "gpt-5",
        "source": "local",
        "input_tokens": 10,
        "output_tokens": 20,
        "cache_read_tokens": 30,
        "cache_write_tokens": 40,
        "completeness": "exact",
    }

    def test_connect_prepares_local_store_before_consuming_code(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_store = StateStore(Path(temporary) / "state.json")
            state = state_store.load()
            state_store.save(state)
            transport = FixtureTransport(state.device_public_id)
            device_store = MemoryDeviceStore()
            client = TokenFleetClient(
                credential_store=device_store,  # type: ignore[arg-type]
                state_store=state_store,
                source_home=Path(temporary),
                community_origin="https://community.example.com",
                transport=transport,
            )
            result = client.connect(
                enrollment_token="A" * 32,
            )
            self.assertEqual(device_store.events, ["prepare", "save"])
            self.assertEqual(result.server_origin, "https://community.example.com")
            self.assertEqual(len(transport.requests), 1)
            request = transport.requests[0][1]
            self.assertEqual(request["platform"], "windows")
            self.assertEqual(request["device_public_id"], state.device_public_id)
            self.assertNotIn("nickname", request)
            self.assertNotIn("email", request)
            self.assertNotIn("wechat", request)

    def test_connect_rejects_mismatched_existing_origin_without_network(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            forged_local_app_data = Path(temporary) / "forged-local-app-data"
            existing = DeviceCredential(
                server_origin="https://community.example",
                device_id="11111111-1111-4111-8111-111111111111",
                device_public_id="22222222-2222-4222-8222-222222222222",
                device_secret="fixture_device_value_1234567890",
            )
            device_store = MemoryDeviceStore(existing)
            with mock.patch.dict(
                os.environ, {"LOCALAPPDATA": os.fspath(forged_local_app_data)}
            ):
                paths = ClientPaths.default()
            state_store = StateStore(paths.state)
            transport = FixtureTransport(existing.device_public_id)
            client = TokenFleetClient(
                credential_store=device_store,  # type: ignore[arg-type]
                state_store=state_store,
                source_home=Path(temporary),
                community_origin="https://attacker.example",
                transport=transport,
            )

            with self.assertRaises(ProtocolError):
                client.connect(enrollment_token="A" * 32)

            self.assertEqual(device_store.events, ["load"])
            self.assertEqual(transport.requests, [])

    def test_sync_sends_only_exact_daily_bucket_with_valid_signature(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            value = DeviceCredential(
                server_origin="https://community.example.com",
                device_id="11111111-1111-4111-8111-111111111111",
                device_public_id="22222222-2222-4222-8222-222222222222",
                device_secret="fixture_device_value_1234567890",
            )
            device_store = MemoryDeviceStore(value)
            state_store = StateStore(Path(temporary) / "state.json")
            state_store.save(state_store.load())
            transport = FixtureTransport(value.device_public_id)
            collection = CollectionResult([dict(self.bucket)], CollectionDiagnostics())
            client = TokenFleetClient(
                credential_store=device_store,  # type: ignore[arg-type]
                state_store=state_store,
                source_home=Path(temporary),
                community_origin="https://community.example.com",
                transport=transport,
                collector=lambda *_args, **_kwargs: collection,
            )
            summary = client.sync()
            self.assertEqual(summary.buckets, 1)
            self.assertEqual(summary.total_tokens, 100)
            self.assertEqual(len(transport.uploads), 1)
            url, body, headers = transport.uploads[0]
            self.assertEqual(url, "https://community.example.com/api/v1/usage/daily")
            payload = json.loads(body)
            self.assertEqual(payload["buckets"], [self.bucket])
            serialized = canonical_json(payload)
            expected = signed_headers(
                device_id=value.device_id,
                device_secret=value.device_secret,
                body=serialized,
                timestamp=int(headers["X-Timestamp"]),
                nonce=headers["X-Nonce"],
                path=DAILY_USAGE_PATH,
            )
            self.assertEqual(headers, expected)
            wire_text = body.decode("utf-8")
            for forbidden in ("prompt", "response", "source_path", "account_id"):
                self.assertNotIn(forbidden, wire_text)

    def test_empty_collection_does_not_send_an_invalid_empty_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            value = DeviceCredential(
                server_origin="https://community.example.com",
                device_id="11111111-1111-4111-8111-111111111111",
                device_public_id="22222222-2222-4222-8222-222222222222",
                device_secret="fixture_device_value_1234567890",
            )
            transport = FixtureTransport(value.device_public_id)
            state_store = StateStore(Path(temporary) / "state.json")
            state_store.save(state_store.load())
            client = TokenFleetClient(
                credential_store=MemoryDeviceStore(value),  # type: ignore[arg-type]
                state_store=state_store,
                source_home=Path(temporary),
                community_origin="https://community.example.com",
                transport=transport,
                collector=lambda *_args, **_kwargs: CollectionResult(
                    [], CollectionDiagnostics()
                ),
            )
            summary = client.sync()
            self.assertEqual(summary.buckets, 0)
            self.assertEqual(transport.uploads, [])

    def test_credential_origin_must_match_the_installed_origin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            value = DeviceCredential(
                server_origin="https://attacker.example",
                device_id="11111111-1111-4111-8111-111111111111",
                device_public_id="22222222-2222-4222-8222-222222222222",
                device_secret="fixture_device_value_1234567890",
            )
            state_store = StateStore(Path(temporary) / "state.json")
            client = TokenFleetClient(
                credential_store=MemoryDeviceStore(value),  # type: ignore[arg-type]
                state_store=state_store,
                source_home=Path(temporary),
                community_origin="https://community.example",
                transport=FixtureTransport(value.device_public_id),
                collector=lambda *_args, **_kwargs: CollectionResult(
                    [], CollectionDiagnostics()
                ),
            )
            with self.assertRaises(ProtocolError):
                client.sync()

    def test_chunking_respects_server_bucket_and_body_limits(self) -> None:
        buckets = [
            dict(
                self.bucket,
                model=f"model-{index}-" + ("界" * 110),
            )
            for index in range(2_005)
        ]
        chunks = TokenFleetClient._chunks(
            buckets, generated="2026-08-09T01:02:03.000000Z"
        )
        self.assertGreater(len(chunks), 1)
        self.assertEqual(sum(map(len, chunks)), len(buckets))
        self.assertTrue(all(len(chunk) <= 2_000 for chunk in chunks))


if __name__ == "__main__":
    unittest.main()
