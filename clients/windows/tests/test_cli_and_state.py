from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import tokenfleet_cli
from tokenfleet.constants import TASK_NAME
from tokenfleet.scheduler import create_task_command, task_action
from tokenfleet.state import ClientState, StateError, StateStore
from tokenfleet.settings import ClientSettings, SettingsStore


class CLIAndStateTests(unittest.TestCase):
    def test_json_output_is_safe_for_legacy_windows_console_encoding(self) -> None:
        raw_output = io.BytesIO()
        encoded_output = io.TextIOWrapper(raw_output, encoding="cp1252")
        with contextlib.redirect_stdout(encoded_output):
            tokenfleet_cli._print_value(
                {"collectors": ["实验 Agent 来源（总开关）"]}, as_json=True
            )
        encoded_output.flush()
        self.assertIn(b"\\u5b9e\\u9a8c", raw_output.getvalue())

    def test_experimental_settings_default_on_and_persist_explicit_choice(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            store = SettingsStore(Path(temporary) / "settings.json")
            defaults = store.load()
            self.assertTrue(defaults.experimental_sources_enabled)
            self.assertFalse(defaults.experimental_sources_configured)
            store.set_experimental_sources(False)
            persisted = store.load()
            self.assertFalse(persisted.experimental_sources_enabled)
            self.assertTrue(persisted.experimental_sources_configured)
            self.assertEqual(
                set(__import__("json").loads(store.path.read_text(encoding="utf-8"))),
                {
                    "version",
                    "experimental_sources_enabled",
                    "experimental_sources_configured",
                },
            )

    def test_version_one_experimental_choice_migrates_without_flipping(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "settings.json"
            store = SettingsStore(path)
            for enabled in (False, True):
                path.write_text(
                    __import__("json").dumps(
                        {"version": 1, "experimental_sources_enabled": enabled}
                    ),
                    encoding="utf-8",
                )
                migrated = store.load()
                self.assertEqual(migrated.experimental_sources_enabled, enabled)
                self.assertTrue(migrated.experimental_sources_configured)

    def test_version_two_rejects_non_boolean_configured_marker(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "settings are invalid"):
            ClientSettings.from_object(
                {
                    "version": 2,
                    "experimental_sources_enabled": True,
                    "experimental_sources_configured": 1,
                }
            )

    def test_unconfigured_version_two_value_follows_current_default(self) -> None:
        settings = ClientSettings.from_object(
            {
                "version": 2,
                "experimental_sources_enabled": False,
                "experimental_sources_configured": False,
            }
        )

        self.assertTrue(settings.experimental_sources_enabled)
        self.assertFalse(settings.experimental_sources_configured)

    def test_rank_subcommand_prints_rank_outside_top_100(self) -> None:
        parser = tokenfleet_cli._parser()
        args = parser.parse_args(["rank"])
        rank_value = {
            "rank": 137,
            "total_entries": 200,
            "metric_value": "12345",
        }
        fake_client = mock.Mock()
        fake_client.community_rank.return_value = rank_value
        with mock.patch.object(tokenfleet_cli, "_client", return_value=fake_client):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = tokenfleet_cli._rank(args, mock.Mock())
        self.assertEqual(result, 0)
        self.assertIn("第 137 名 / 200 人", output.getvalue())
        self.assertIn("12345 Token", output.getvalue())

    def test_status_plain_text_prints_exactly_one_rank_summary(self) -> None:
        args = tokenfleet_cli._parser().parse_args(["status"])
        paths = SimpleNamespace(
            community_config=Path("community.json"),
            community_digest=Path("community.sha256"),
            credential=Path("credential.dpapi"),
            state=Path("state.json"),
            settings=Path("settings.json"),
        )
        credential = SimpleNamespace(
            server_origin="https://community.example",
            device_public_id="public-id",
        )
        state = SimpleNamespace(
            device_public_id="public-id",
            last_sync_at=None,
            last_bucket_count=0,
            last_uploaded_tokens=0,
        )
        rank_value = {
            "rank": 137,
            "total_entries": 200,
            "metric_value": "12345",
        }
        with (
            mock.patch.object(tokenfleet_cli, "CommunityInstallationConfigStore") as config_store,
            mock.patch.object(tokenfleet_cli, "CredentialStore") as credential_store,
            mock.patch.object(tokenfleet_cli, "StateStore") as state_store,
            mock.patch.object(tokenfleet_cli, "SettingsStore") as settings_store,
            mock.patch.object(tokenfleet_cli, "is_registered", return_value=True),
            mock.patch.object(tokenfleet_cli, "_client") as client,
        ):
            config_store.return_value.load.return_value = SimpleNamespace(
                community_server="https://community.example"
            )
            credential_store.return_value.exists = True
            credential_store.return_value.load.return_value = credential
            state_store.return_value.load.return_value = state
            settings_store.return_value.load.return_value = SimpleNamespace(
                experimental_sources_enabled=False
            )
            client.return_value.community_rank.return_value = rank_value
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = tokenfleet_cli._status(args, paths)
        self.assertEqual(result, 0)
        text = output.getvalue()
        self.assertEqual(text.count("我的名次："), 1)
        self.assertNotIn("rank_summary:", text)

    def test_connect_has_no_command_line_code_argument(self) -> None:
        parser = tokenfleet_cli._parser()
        parsed = parser.parse_args(["connect"])
        self.assertEqual(parsed.command, "connect")
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parser.parse_args(["connect", "--code", "not-accepted"])
            with self.assertRaises(SystemExit):
                parser.parse_args(
                    ["connect", "--server", "https://attacker.example"]
                )

    def test_state_is_strict_and_contains_only_non_sensitive_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "state.json"
            store = StateStore(path)
            state = ClientState.new()
            state.last_sync_at = "2026-08-09T01:02:03Z"
            state.last_bucket_count = 3
            state.last_uploaded_tokens = 42
            store.save(state)
            self.assertEqual(store.load(), state)
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("prompt", text)
            self.assertNotIn("response", text)
            self.assertEqual(str(uuid.UUID(state.device_public_id)), state.device_public_id)
            path.write_text(text[:-1] + ',"unexpected":true}', encoding="utf-8")
            with self.assertRaises(StateError):
                store.load()

    def test_scheduled_task_is_limited_and_runs_quiet_sync(self) -> None:
        script = Path("C:/Users/example/AppData/Local/TokenFleet/app/tokenfleet_cli.py")
        python = Path("C:/Python312/python.exe")
        action = task_action(script, python)
        self.assertIn("sync --quiet", action)
        self.assertNotIn("connect", action)
        command = create_task_command(script)
        self.assertEqual(command[0], "schtasks.exe")
        self.assertIn(TASK_NAME, command)
        self.assertIn("LIMITED", command)
        self.assertNotIn("SYSTEM", command)


if __name__ == "__main__":
    unittest.main()
