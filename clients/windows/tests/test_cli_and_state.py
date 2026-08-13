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


class CLIAndStateTests(unittest.TestCase):
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

    def test_connect_syncs_when_task_registration_fails(self) -> None:
        fake_client = mock.Mock()
        fake_client.connect.return_value = SimpleNamespace(
            device_public_id="22222222-2222-4222-8222-222222222222"
        )
        fake_client.sync.return_value = SimpleNamespace(buckets=2, total_tokens=30)
        args = SimpleNamespace(no_initial_sync=False)
        with (
            mock.patch("tokenfleet_cli._client", return_value=fake_client),
            mock.patch("tokenfleet_cli.getpass.getpass", return_value="A" * 32),
            mock.patch(
                "tokenfleet_cli.register",
                side_effect=tokenfleet_cli.SchedulerError("denied"),
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(tokenfleet_cli._connect(args, mock.Mock()), 0)
        fake_client.connect.assert_called_once_with(enrollment_token="A" * 32)
        fake_client.sync.assert_called_once_with()

    def test_connect_without_initial_sync_does_not_claim_data_was_synced(self) -> None:
        fake_client = mock.Mock()
        fake_client.connect.return_value = SimpleNamespace(
            device_public_id="22222222-2222-4222-8222-222222222222"
        )
        args = SimpleNamespace(no_initial_sync=True)
        stderr = io.StringIO()
        with (
            mock.patch("tokenfleet_cli._client", return_value=fake_client),
            mock.patch("tokenfleet_cli.getpass.getpass", return_value="A" * 32),
            mock.patch(
                "tokenfleet_cli.register",
                side_effect=tokenfleet_cli.SchedulerError("denied"),
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(stderr),
        ):
            self.assertEqual(tokenfleet_cli._connect(args, mock.Mock()), 0)
        fake_client.sync.assert_not_called()
        self.assertNotIn("数据已同步", stderr.getvalue())

    def test_manual_sync_continues_when_task_registration_fails(self) -> None:
        fake_client = mock.Mock()
        fake_client.sync.return_value = SimpleNamespace(
            buckets=2,
            total_tokens=30,
            created=2,
            updated=0,
            unchanged=0,
            ledger_version=1,
            generated_at="2026-08-13T00:00:00Z",
        )
        args = SimpleNamespace(quiet=False, as_json=True)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch("tokenfleet_cli._client", return_value=fake_client),
            mock.patch("tokenfleet_cli.is_registered", return_value=False),
            mock.patch(
                "tokenfleet_cli.register",
                side_effect=tokenfleet_cli.SchedulerError("denied"),
            ),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            self.assertEqual(tokenfleet_cli._sync(args, mock.Mock()), 0)
        fake_client.sync.assert_called_once_with()
        self.assertIn('"created": 2', stdout.getvalue())
        self.assertIn("tokenfleet sync", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
