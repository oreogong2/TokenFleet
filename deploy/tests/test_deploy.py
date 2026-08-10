from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest


DEPLOY_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = DEPLOY_ROOT.parent
sys.path.insert(0, str(DEPLOY_ROOT))

import prepare_env  # noqa: E402


class ProductionEnvironmentTests(unittest.TestCase):
    def test_generated_file_is_private_valid_and_does_not_print_secrets(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tokenfleet-deploy-test-") as directory:
            output = Path(directory) / ".env"
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                prepare_env.write_env(
                    output,
                    domain="rank.example.com",
                    org_slug="example-community",
                    app_port=18080,
                )
            values = prepare_env.validate_env(output)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(values["TOKENFLEET_DOMAIN"], "rank.example.com")
            self.assertEqual(values["PUBLIC_ORG_SLUG"], "example-community")
            self.assertEqual(values["ENROLLMENT_RATE_LIMIT_ATTEMPTS"], "60")
            self.assertEqual(values["ENROLLMENT_RATE_LIMIT_WINDOW_SECONDS"], "60")
            self.assertNotIn(values["POSTGRES_PASSWORD"], captured.getvalue())
            self.assertNotIn(values["JWT_SECRET"], captured.getvalue())

    def test_existing_environment_is_never_overwritten(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tokenfleet-deploy-test-") as directory:
            output = Path(directory) / ".env"
            output.write_text("sentinel\n", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                prepare_env.write_env(
                    output,
                    domain="rank.example.com",
                    org_slug="community",
                    app_port=18080,
                )
            self.assertEqual(output.read_text(encoding="utf-8"), "sentinel\n")

    def test_environment_permissions_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tokenfleet-deploy-test-") as directory:
            output = Path(directory) / ".env"
            prepare_env.write_env(
                output,
                domain="rank.example.com",
                org_slug="community",
                app_port=18080,
            )
            output.chmod(0o644)
            with self.assertRaisesRegex(ValueError, "permissions"):
                prepare_env.validate_env(output)

    def test_hostile_or_noncanonical_domains_are_rejected(self) -> None:
        rejected = (
            "https://rank.example.com",
            "Rank.example.com",
            "rank.example.com/",
            "rank.example.com.",
            "localhost",
            "127.0.0.1",
            "rank.localhost",
            "rank..example.com",
            "rank_example.com",
            "evil@example.com",
        )
        for value in rejected:
            with self.subTest(value=value), self.assertRaises(ValueError):
                prepare_env.validate_domain(value)
        self.assertEqual(
            prepare_env.validate_domain("rank.example.com"), "rank.example.com"
        )


class ProductionAssetTests(unittest.TestCase):
    def test_compose_exposes_only_loopback_app_and_not_database(self) -> None:
        compose = (DEPLOY_ROOT / "compose.prod.yml").read_text(encoding="utf-8")
        self.assertIn("127.0.0.1:${APP_PORT:-18080}:8000", compose)
        db_section = compose.split("  db:\n", 1)[1].split("  migrate:\n", 1)[0]
        self.assertNotIn("ports:", db_section)
        self.assertIn("172.30.50.1/32", compose)
        self.assertIn('TRUSTED_PROXY_HOPS: "1"', compose)

    def test_runtime_is_nonroot_readonly_and_single_worker(self) -> None:
        dockerfile = (DEPLOY_ROOT / "Dockerfile").read_text(encoding="utf-8")
        compose = (DEPLOY_ROOT / "compose.prod.yml").read_text(encoding="utf-8")
        self.assertIn("python:3.14-slim-bookworm@sha256:", dockerfile)
        self.assertIn("postgres:17-alpine@sha256:", compose)
        self.assertIn("USER 10001:10001", dockerfile)
        self.assertIn('"--workers", "1"', dockerfile)
        self.assertGreaterEqual(compose.count("read_only: true"), 2)
        self.assertNotIn("privileged: true", compose)

    def test_docker_context_excludes_macos_appledouble_metadata(self) -> None:
        dockerignore = (REPO_ROOT / ".dockerignore").read_text(encoding="utf-8")
        self.assertIn("**/._*", dockerignore.splitlines())

    def test_nginx_overwrites_forwarding_identity_and_has_gateway_limits(self) -> None:
        proxy = (
            DEPLOY_ROOT / "nginx" / "tokenfleet-proxy-headers.conf"
        ).read_text(encoding="utf-8")
        site = (DEPLOY_ROOT / "nginx" / "tokenfleet.conf.template").read_text(
            encoding="utf-8"
        )
        self.assertIn("X-Forwarded-For $remote_addr", proxy)
        self.assertNotIn("$proxy_add_x_forwarded_for", proxy)
        self.assertIn("limit_req_status 429", site)
        self.assertIn("tokenfleet_public_ip", site)
        self.assertIn("tokenfleet_login_ip", site)
        self.assertIn("tokenfleet_enrollment_ip", site)
        self.assertIn("location = /api/v1/devices/enroll", site)
        self.assertIn("client_max_body_size 2m", site)

        direct_tls = (
            DEPLOY_ROOT / "nginx" / "tokenfleet-direct-tls.conf.template"
        ).read_text(encoding="utf-8")
        bootstrap = (
            DEPLOY_ROOT / "nginx" / "tokenfleet-acme-bootstrap.conf.template"
        ).read_text(encoding="utf-8")
        self.assertIn("/var/lib/letsencrypt", bootstrap)
        self.assertNotIn("proxy_pass", bootstrap)
        self.assertIn("X-Forwarded-For $remote_addr", proxy)
        self.assertIn("limit_req_status 429", direct_tls)
        self.assertIn("tokenfleet_enrollment_ip", direct_tls)
        self.assertIn("location = /api/v1/devices/enroll", direct_tls)
        self.assertIn("/etc/letsencrypt/live/__TOKENFLEET_DOMAIN__", direct_tls)
        self.assertNotIn("$proxy_add_x_forwarded_for", direct_tls)

    def test_alibaba_installer_reuses_account_without_reading_its_email(self) -> None:
        installer = (
            DEPLOY_ROOT / "install_nginx_certbot_alibaba.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("--reuse-existing-account", installer)
        self.assertIn('"$CERTBOT_BIN" show_account >/dev/null', installer)
        self.assertIn("certonly --webroot", installer)
        self.assertNotIn("certbot --nginx", installer)
        self.assertIn("/etc/nginx/conf.d/tokenfleet.conf", installer)

    def test_repository_does_not_contain_generated_production_env(self) -> None:
        self.assertFalse((DEPLOY_ROOT / ".env").exists())
        ignore = (DEPLOY_ROOT / ".gitignore").read_text(encoding="utf-8")
        self.assertIn(".env", ignore.splitlines())


if __name__ == "__main__":
    unittest.main()
