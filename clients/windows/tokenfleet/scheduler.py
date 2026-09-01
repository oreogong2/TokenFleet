from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from .constants import TASK_NAME


class SchedulerError(RuntimeError):
    pass


def task_action(script_path: Path, python_executable: Path | None = None) -> str:
    executable = python_executable or Path(sys.executable)
    return f'"{executable}" "{script_path.resolve()}" sync --quiet'


def create_task_command(
    script_path: Path, python_executable: Path | None = None
) -> list[str]:
    return [
        "schtasks.exe",
        "/Create",
        "/TN",
        TASK_NAME,
        "/TR",
        task_action(script_path, python_executable),
        "/SC",
        "HOURLY",
        "/MO",
        "6",
        "/RL",
        "LIMITED",
        "/F",
    ]


def register(
    script_path: Path, python_executable: Path | None = None
) -> None:
    _run(
        create_task_command(script_path, python_executable),
        operation="create",
    )


def unregister(*, ignore_missing: bool = True) -> None:
    if ignore_missing and not is_registered():
        return
    _run(
        ["schtasks.exe", "/Delete", "/TN", TASK_NAME, "/F"],
        operation="delete",
        check=True,
    )


def is_registered() -> bool:
    if os.name != "nt":
        return False
    result = _run(
        ["schtasks.exe", "/Query", "/TN", TASK_NAME],
        operation="query",
        check=False,
    )
    return result.returncode == 0


def _run(
    command: list[str], *, operation: str, check: bool = True
) -> subprocess.CompletedProcess[str]:
    if os.name != "nt":
        raise SchedulerError("Windows Task Scheduler is unavailable")
    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
            check=False,
            creationflags=creation_flags,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise SchedulerError(f"TokenFleet scheduled sync {operation} failed") from exc
    if check and result.returncode != 0:
        raise SchedulerError(f"TokenFleet scheduled sync {operation} failed")
    return result
