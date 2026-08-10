from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import tokenfleet.paths as paths_module
from tokenfleet.installation import (
    CommunityInstallationConfigStore,
    InstallationConfigError,
    canonical_community_origin,
    install_config_artifacts,
    validate_install_request,
)
from tokenfleet.paths import ClientPaths


class InstallationConfigTests(unittest.TestCase):
    def test_runtime_config_path_is_not_redirected_by_localappdata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            forged_local_app_data = Path(temporary) / "forged-local-app-data"
            forged_app = forged_local_app_data / "TokenFleet" / "app"
            forged_app.mkdir(parents=True)
            forged_config, forged_digest = install_config_artifacts(
                "https://attacker.example"
            )
            (forged_app / "community.json").write_bytes(forged_config)
            (forged_app / "community.sha256").write_bytes(forged_digest)

            with mock.patch.dict(
                os.environ, {"LOCALAPPDATA": os.fspath(forged_local_app_data)}
            ):
                paths = ClientPaths.default()

            installed_app = Path(paths_module.__file__).resolve().parent.parent
            self.assertEqual(paths.root, forged_local_app_data / "TokenFleet")
            self.assertEqual(paths.community_config, installed_app / "community.json")
            self.assertEqual(paths.community_digest, installed_app / "community.sha256")
            self.assertNotEqual(paths.community_config, forged_app / "community.json")

    def test_accepts_only_canonical_public_dns_https_origin(self) -> None:
        self.assertEqual(
            canonical_community_origin("https://community.example:8443"),
            "https://community.example:8443",
        )
        for value in (
            "https://COMMUNITY.example",
            "https://community.example/",
            "https://community.example:443",
            "https://127.0.0.1",
            "https://localhost",
            "https://community",
            "https://bad_host.example",
            "http://community.example",
        ):
            with self.subTest(value=value), self.assertRaises(InstallationConfigError):
                canonical_community_origin(value)

    def test_installed_config_round_trip_and_tamper_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = root / "community.json"
            digest_path = root / "community.sha256"
            config, digest = install_config_artifacts("https://community.example")
            config_path.write_bytes(config)
            digest_path.write_bytes(digest)
            store = CommunityInstallationConfigStore(config_path, digest_path)
            self.assertEqual(store.load().community_server, "https://community.example")
            config_path.write_bytes(
                config.replace(b"community.example", b"attacker.example")
            )
            with self.assertRaises(InstallationConfigError):
                store.load()

    def test_upgrade_preserves_the_existing_origin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = root / "community.json"
            digest_path = root / "community.sha256"
            config, digest = install_config_artifacts("https://community.example")
            config_path.write_bytes(config)
            digest_path.write_bytes(digest)
            self.assertEqual(
                validate_install_request(
                    "https://community.example",
                    config_path=config_path,
                    digest_path=digest_path,
                    credential_path=root / "credential.dpapi",
                ),
                "https://community.example",
            )
            with self.assertRaises(InstallationConfigError):
                validate_install_request(
                    "https://attacker.example",
                    config_path=config_path,
                    digest_path=digest_path,
                    credential_path=root / "credential.dpapi",
                )


if __name__ == "__main__":
    unittest.main()
