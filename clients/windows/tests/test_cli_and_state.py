from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import tokenfleet_cli
from tokenfleet.constants import (
    SYNC_INTERVAL_SECONDS,
    SYNC_RETRY_SECONDS,
    TASK_NAME,
)
from tokenfleet import scheduler
from tokenfleet.scheduler import create_task_command, startup_action, task_action
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

    def test_startup_action_runs_hidden_loop_without_credentials(self) -> None:
        script = Path("C:/Users/example/AppData/Local/TokenFleet/app/tokenfleet_cli.py")
        python = Path("C:/Python312/pythonw.exe")
        action = startup_action(script, python)
        self.assertIn("scheduled-loop", action)
        self.assertNotIn("connect", action)
        self.assertNotIn("--code", action)

    def test_register_falls_back_to_current_user_startup(self) -> None:
        script = Path("C:/TokenFleet/tokenfleet_cli.py")
        with (
            mock.patch.object(
                scheduler,
                "_run",
                side_effect=scheduler.SchedulerError("denied"),
            ),
            mock.patch.object(scheduler, "_register_startup") as register_startup,
        ):
            self.assertEqual(scheduler.register(script), "startup_loop")
        register_startup.assert_called_once_with(script)

    def test_register_prefers_task_scheduler_and_removes_old_startup(self) -> None:
        script = Path("C:/TokenFleet/tokenfleet_cli.py")
        with (
            mock.patch.object(scheduler, "_run"),
            mock.patch.object(scheduler, "_unregister_startup") as unregister_startup,
        ):
            self.assertEqual(scheduler.register(script), "task_scheduler")
        unregister_startup.assert_called_once_with(ignore_missing=True)

    def test_startup_loop_syncs_immediately_then_waits_six_hours(self) -> None:
        script = Path("C:/TokenFleet/tokenfleet_cli.py")
        sync_once = mock.Mock()
        with (
            mock.patch.object(scheduler, "_acquire_loop_mutex", return_value=7),
            mock.patch.object(
                scheduler, "is_startup_registered", return_value=True
            ),
            mock.patch.object(
                scheduler, "_sleep_while_registered", return_value=False
            ) as sleep,
            mock.patch.object(scheduler, "_release_loop_mutex") as release,
        ):
            scheduler.run_startup_loop(script, sync_once)
        sync_once.assert_called_once_with()
        sleep.assert_called_once_with(script, SYNC_INTERVAL_SECONDS)
        release.assert_called_once_with(7)

    def test_startup_loop_retries_after_sync_failure(self) -> None:
        script = Path("C:/TokenFleet/tokenfleet_cli.py")
        sync_once = mock.Mock(side_effect=RuntimeError("offline"))
        with (
            mock.patch.object(scheduler, "_acquire_loop_mutex", return_value=8),
            mock.patch.object(
                scheduler, "is_startup_registered", return_value=True
            ),
            mock.patch.object(
                scheduler, "_sleep_while_registered", return_value=False
            ) as sleep,
            mock.patch.object(scheduler, "_release_loop_mutex"),
        ):
            scheduler.run_startup_loop(script, sync_once)
        sleep.assert_called_once_with(script, SYNC_RETRY_SECONDS)

    def test_startup_loop_is_single_instance(self) -> None:
        sync_once = mock.Mock()
        with mock.patch.object(scheduler, "_acquire_loop_mutex", return_value=None):
            scheduler.run_startup_loop(Path("C:/TokenFleet/tokenfleet_cli.py"), sync_once)
        sync_once.assert_not_called()

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

    def test_connect_syncs_before_registering_background_loop(self) -> None:
        calls: list[str] = []
        fake_client = mock.Mock()
        fake_client.connect.return_value = SimpleNamespace(
            device_public_id="22222222-2222-4222-8222-222222222222"
        )
        fake_client.sync.side_effect = lambda: calls.append("sync") or SimpleNamespace(
            buckets=1,
            total_tokens=10,
        )
        args = SimpleNamespace(no_initial_sync=False)
        with (
            mock.patch("tokenfleet_cli._client", return_value=fake_client),
            mock.patch("tokenfleet_cli.getpass.getpass", return_value="A" * 32),
            mock.patch(
                "tokenfleet_cli.register",
                side_effect=lambda _path: calls.append("register") or "startup_loop",
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(tokenfleet_cli._connect(args, mock.Mock()), 0)
        self.assertEqual(calls, ["sync", "register"])

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

    def test_status_reports_actual_scheduler_backend(self) -> None:
        paths = mock.Mock()
        store = mock.Mock()
        store.exists = False
        state = SimpleNamespace(
            device_public_id=None,
            last_sync_at=None,
            last_bucket_count=0,
            last_uploaded_tokens=0,
        )
        stdout = io.StringIO()
        with (
            mock.patch(
                "tokenfleet_cli.CommunityInstallationConfigStore"
            ) as config_store,
            mock.patch("tokenfleet_cli.CredentialStore", return_value=store),
            mock.patch("tokenfleet_cli.StateStore") as state_store,
            mock.patch(
                "tokenfleet_cli.scheduler_backend", return_value="startup_loop"
            ),
            contextlib.redirect_stdout(stdout),
        ):
            config_store.return_value.load.return_value = SimpleNamespace(
                community_server="https://token.example"
            )
            state_store.return_value.load.return_value = state
            self.assertEqual(
                tokenfleet_cli._status(SimpleNamespace(as_json=True), paths), 0
            )
        value = json.loads(stdout.getvalue())
        self.assertTrue(value["scheduled_sync"])
        self.assertEqual(value["scheduled_backend"], "startup_loop")
        self.assertIsNone(value["scheduled_task"])


if __name__ == "__main__":
    unittest.main()
