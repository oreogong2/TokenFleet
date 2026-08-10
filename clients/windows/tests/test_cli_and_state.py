from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
import uuid
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
