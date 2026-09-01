from __future__ import annotations

import os
import socket
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from tokenfleet.constants import TASK_NAME
from tokenfleet.credential import CredentialStore, DPAPIProtector, DeviceCredential
from tokenfleet.local_dashboard import create_dashboard_server
from tokenfleet.scheduler import is_registered, register, unregister


@unittest.skipUnless(os.name == "nt", "requires the real Windows runtime")
class WindowsRuntimeTests(unittest.TestCase):
    def test_local_dashboard_really_binds_only_ipv4_loopback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = SimpleNamespace(
                dashboard_token=Path(temporary) / "local-dashboard.token"
            )
            server = create_dashboard_server(paths, port=0)
            try:
                self.assertEqual(server.server_address[0], "127.0.0.1")
                self.assertEqual(
                    server.socket.getsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE),
                    1,
                )
            finally:
                server.server_close()
            with self.assertRaises(RuntimeError):
                create_dashboard_server(paths, host="0.0.0.0", port=0)

    def test_current_user_dpapi_round_trip_and_ciphertext_storage(self) -> None:
        protector = DPAPIProtector()
        cleartext = b"tokenfleet-windows-runtime-probe"
        encrypted = protector.protect(cleartext)
        self.assertNotEqual(encrypted, cleartext)
        self.assertEqual(protector.unprotect(encrypted), cleartext)

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "credential.dpapi"
            store = CredentialStore(path, protector=protector)
            store.prepare()
            credential = DeviceCredential(
                server_origin="https://community.example.com",
                device_id="11111111-1111-4111-8111-111111111111",
                device_public_id="22222222-2222-4222-8222-222222222222",
                device_secret="fixture_device_value_1234567890",
            )
            store.save(credential)
            self.assertEqual(store.load(), credential)
            ciphertext = path.read_bytes()
            self.assertNotIn(credential.device_secret.encode("utf-8"), ciphertext)

    def test_limited_scheduled_task_can_be_created_and_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / "tokenfleet_runtime_probe.py"
            script.write_text("raise SystemExit(0)\n", encoding="utf-8")
            unregister(ignore_missing=True)
            try:
                register(script)
                self.assertTrue(is_registered(), TASK_NAME)
            finally:
                unregister(ignore_missing=True)
            self.assertFalse(is_registered(), TASK_NAME)


if __name__ == "__main__":
    unittest.main()
