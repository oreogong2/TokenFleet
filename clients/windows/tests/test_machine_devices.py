from __future__ import annotations

import hashlib
import hmac
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from tokenfleet.client import TokenFleetClient
from tokenfleet.credential import DeviceCredential
from tokenfleet.constants import SIGNING_KEY_CONTEXT
from tokenfleet.http_client import NetworkError
from tokenfleet.machine_identity import fingerprint_for_guid
from tokenfleet.protocol import ProtocolError, signed_headers
from tokenfleet.state import ClientState, StateStore, StateError
from tokenfleet.collectors import CollectionDiagnostics, CollectionResult
from tokenfleet.constants import SIGNING_KEY_DERIVATION
import test_client as client_fixtures

A = "a" * 64
B = "b" * 64

class MachineDeviceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = StateStore(Path(self.temp.name) / "state.json")
        self.initial = ClientState.new()
        self.state.save(self.initial)
        self.credentials = mock.Mock()
        self.credentials.exists = True
        self.credentials.load.return_value = DeviceCredential(
            server_origin="https://community.example.com",
            device_id="11111111-1111-4111-8111-111111111111",
            device_public_id=self.initial.device_public_id,
            device_secret="fixture_device_secret_1234567890")
        self.transport = mock.Mock()
        self.client = TokenFleetClient(credential_store=self.credentials, state_store=self.state,
            source_home=Path(self.temp.name), community_origin="https://community.example.com",
            transport=self.transport, machine_fingerprint=lambda: A)

    def test_migration_stops_before_dpapi_or_network_and_changes_only_binding(self):
        self.initial.machine_fingerprint = B
        self.state.save(self.initial)
        with self.assertRaisesRegex(ProtocolError, "新设备"):
            self.client.community_rank()
        self.credentials.clear.assert_called_once()
        self.credentials.load.assert_not_called()
        self.transport.get.assert_not_called()
        state = self.state.load()
        self.assertNotEqual(state.device_public_id, self.initial.device_public_id)
        self.assertEqual(state.machine_fingerprint, A)
        self.assertTrue(state.reconnect_required)

    def test_migration_date_survives_reconnect_restart_and_repeated_sync(self):
        self.initial.machine_fingerprint = B
        self.state.save(self.initial)
        # UTC is still the previous day; use the accounting timezone, not runner locale.
        self.client.clock = lambda: datetime(2026, 8, 8, 16, 30, tzinfo=timezone.utc)
        with self.assertRaises(ProtocolError): self.client.validate_machine_binding()
        reset = self.state.load()
        self.assertEqual(reset.upload_not_before_date, "2026-08-09")
        self.client.clock = lambda: datetime(2026, 8, 11, tzinfo=timezone.utc)
        transport = client_fixtures.FixtureTransport(reset.device_public_id)
        self.client.transport = transport
        self.credentials.exists = False
        self.client.connect(enrollment_token="T" * 43)
        self.credentials.exists = True
        connected = self.state.load()
        self.assertEqual(connected.upload_not_before_date, "2026-08-09")
        self.credentials.load.return_value = DeviceCredential(
            server_origin=self.client.community_origin, device_id="11111111-1111-4111-8111-111111111111",
            device_public_id=connected.device_public_id, device_secret="fixture_device_secret_1234567890")
        buckets = [dict(client_fixtures.ClientTests.bucket, date=d) for d in ("2026-08-08", "2026-08-09", "2026-08-10")]
        self.client.collector = lambda *a, **kw: CollectionResult(buckets, CollectionDiagnostics())
        for _ in range(2):
            self.assertEqual(self.client.sync().buckets, 2)
            import json
            self.assertEqual([b["date"] for b in json.loads(transport.uploads[-1][1])["buckets"]], ["2026-08-09", "2026-08-10"])
        self.assertEqual(self.state.load().upload_not_before_date, "2026-08-09")
        self.assertEqual(len(buckets), 3)  # Local preview still includes the original history.

    def test_same_machine_upgrade_still_uploads_existing_history(self):
        self.initial.machine_fingerprint = A
        self.state.save(self.initial)
        transport = client_fixtures.FixtureTransport(self.initial.device_public_id)
        self.client.transport = transport
        self.client.collector = lambda *a, **kw: CollectionResult([dict(client_fixtures.ClientTests.bucket)], CollectionDiagnostics())
        self.assertEqual(self.client.sync().buckets, 1)
        self.assertIsNone(self.state.load().upload_not_before_date)
        self.credentials.clear.assert_not_called()

    def test_machine_conflict_records_upload_floor_and_excludes_all_old_buckets(self):
        self.client.clock = lambda: datetime(2026, 8, 9, tzinfo=timezone.utc)
        self.transport.get.side_effect = NetworkError("fixture", status=409, machine_mismatch=True)
        with self.assertRaises(ProtocolError): self.client.community_rank()
        self.assertEqual(self.state.load().upload_not_before_date, "2026-08-09")
        # Reconnection does not lift the persisted restriction, even when no eligible data exists.
        self.state.save(self.state.load())
        self.credentials.load.return_value = DeviceCredential(
            server_origin=self.client.community_origin, device_id="11111111-1111-4111-8111-111111111111",
            device_public_id=self.state.load().device_public_id, device_secret="fixture_device_secret_1234567890")
        state = self.state.load(); state.reconnect_required = False; self.state.save(state)
        self.client.collector = lambda *a, **kw: CollectionResult([dict(client_fixtures.ClientTests.bucket, date="2026-08-08")], CollectionDiagnostics())
        self.assertEqual(self.client.sync().buckets, 0)
        self.transport.post_bytes.assert_not_called()

    def test_invalid_upload_date_is_rejected_and_legacy_state_remains_compatible(self):
        from dataclasses import asdict
        self.assertIsNone(ClientState.from_object(asdict(self.initial)).upload_not_before_date)
        for bad in ("2026-02-30", "2026-8-9", 42, ""):
            with self.assertRaises(StateError): ClientState.from_object(dict(asdict(self.initial), upload_not_before_date=bad))

    def test_unavailable_identity_preserves_old_state_and_credential(self):
        self.client.machine_fingerprint = lambda: "invalid"
        with self.assertRaises(ProtocolError):
            self.client.community_rank()
        self.assertEqual(self.state.load(), self.initial)
        self.credentials.clear.assert_not_called()
        self.transport.get.assert_not_called()

    def test_legacy_clone_server_conflict_resets_once_and_does_not_retry(self):
        self.transport.get.side_effect = NetworkError("fixture", status=409, machine_mismatch=True)
        with self.assertRaisesRegex(ProtocolError, "新设备"):
            self.client.community_rank()
        self.assertEqual(self.transport.get.call_count, 1)
        self.credentials.clear.assert_called_once()
        self.assertTrue(self.state.load().reconnect_required)

    def test_code_endpoint_signs_fingerprint_and_code_is_not_in_state(self):
        code = "T" * 43
        expiry = (datetime.now(timezone.utc) + timedelta(minutes=15)).isoformat()
        self.transport.post_bytes.return_value = {"enrollment_token": code, "expires_at": expiry}
        self.assertEqual(self.client.additional_device_code()["enrollment_token"], code)
        args, kwargs = self.transport.post_bytes.call_args
        self.assertEqual(args[1], b"{}")
        self.assertTrue(args[0].endswith("/devices/me/enrollment-tokens"))
        self.assertEqual(kwargs["headers"]["X-Machine-Fingerprint"], A)
        self.assertNotIn(code, self.state.path.read_text())
        self.assertEqual(self.state.load().device_public_id, self.initial.device_public_id)

    def test_additional_code_accepts_clock_behind_and_rejects_unbounded_or_expired(self):
        server_now = datetime(2026, 9, 27, tzinfo=timezone.utc)
        local_now = server_now - timedelta(seconds=120)
        with mock.patch("tokenfleet.client.datetime") as clock:
            clock.now.return_value = local_now
            clock.fromisoformat.side_effect = datetime.fromisoformat
            for seconds, accepted in ((900, True), (-120, False), (1200, False)):
                self.transport.post_bytes.return_value = {
                    "enrollment_token": "T" * 43,
                    "expires_at": (server_now + timedelta(seconds=seconds)).isoformat(),
                }
                if accepted:
                    self.assertEqual(self.client.additional_device_code()["enrollment_token"], "T" * 43)
                else:
                    with self.assertRaises(ProtocolError):
                        self.client.additional_device_code()

    def test_fingerprint_is_signed_using_cross_platform_canonical_contract(self):
        headers = signed_headers(device_id="fixture", device_secret="fixture-secret", body=b"{}",
            timestamp=1700000000, nonce="fixture_nonce_1234", machine_fingerprint=A)
        canonical = "\n".join(["1700000000", "fixture_nonce_1234", "POST", "/api/v1/usage/daily", hashlib.sha256(b"{}").hexdigest()]) + "\nmachine-fingerprint-v1:" + A
        key = hashlib.sha256(SIGNING_KEY_CONTEXT + b"fixture-secret").digest()
        self.assertEqual(headers["X-Signature"], hmac.new(key, canonical.encode(), hashlib.sha256).hexdigest())

    def test_guid_normalization_and_rejection(self):
        guid = "123e4567-e89b-12d3-a456-426614174000"
        self.assertEqual(fingerprint_for_guid(guid), fingerprint_for_guid(guid.upper()))
        self.assertEqual(len(fingerprint_for_guid(guid)), 64)
        for invalid in ("bad", "00000000-0000-0000-0000-000000000000"):
            with self.assertRaises(ProtocolError): fingerprint_for_guid(invalid)
