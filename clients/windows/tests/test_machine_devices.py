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
from tokenfleet.state import ClientState, StateStore

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
