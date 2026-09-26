from __future__ import annotations

import os
import getpass
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime
import subprocess
import sys
from pathlib import Path

from .constants import TASK_NAME


class SchedulerError(RuntimeError):
    pass


def task_action(script_path: Path, python_executable: Path | None = None) -> str:
    executable = python_executable or Path(sys.executable)
    return f'"{executable}" "{script_path.resolve()}" sync --quiet'


def task_xml(script_path: Path, python_executable: Path | None = None) -> str:
    namespace = "http://schemas.microsoft.com/windows/2004/02/mit/task"
    ET.register_namespace("", namespace)
    def child(parent, name, text=None):
        node = ET.SubElement(parent, f"{{{namespace}}}{name}")
        if text is not None:
            node.text = text
        return node
    task = ET.Element(f"{{{namespace}}}Task", {"version": "1.3"})
    domain = os.environ.get("USERDOMAIN", "")
    user = (domain + "\\" if domain else "") + getpass.getuser()
    triggers = child(task, "Triggers")
    periodic = child(triggers, "CalendarTrigger")
    child(periodic, "Enabled", "true")
    child(periodic, "StartBoundary", datetime.now().replace(microsecond=0).isoformat())
    repetition = child(periodic, "Repetition")
    child(repetition, "Interval", "PT6H")
    child(repetition, "Duration", "P1D")
    child(repetition, "StopAtDurationEnd", "false")
    child(child(periodic, "ScheduleByDay"), "DaysInterval", "1")
    login = child(triggers, "LogonTrigger")
    child(login, "Enabled", "true")
    child(login, "UserId", user)
    principal = child(child(task, "Principals"), "Principal")
    principal.set("id", "CurrentUser")
    child(principal, "UserId", user)
    child(principal, "LogonType", "InteractiveToken")
    child(principal, "RunLevel", "LeastPrivilege")
    settings = child(task, "Settings")
    for name, value in (("MultipleInstancesPolicy", "IgnoreNew"),
                        ("DisallowStartIfOnBatteries", "false"), ("StopIfGoingOnBatteries", "false"),
                        ("StartWhenAvailable", "true"), ("ExecutionTimeLimit", "PT1H"), ("Enabled", "true")):
        child(settings, name, value)
    actions = child(task, "Actions")
    actions.set("Context", "CurrentUser")
    action = child(actions, "Exec")
    child(action, "Command", str(python_executable or Path(sys.executable)))
    child(action, "Arguments", f'"{script_path.resolve()}" sync --quiet')
    return '<?xml version="1.0" encoding="UTF-16"?>' + ET.tostring(task, encoding="unicode")


def create_task_command(script_path: Path, python_executable: Path | None = None,
                        *, xml_path: Path) -> list[str]:
    return ["schtasks.exe", "/Create", "/TN", TASK_NAME, "/XML", str(xml_path), "/F"]


def register(script_path: Path, python_executable: Path | None = None) -> None:
    with tempfile.TemporaryDirectory(prefix="tokenfleet-task-") as temporary:
        xml_path = Path(temporary) / "sync.xml"
        xml_path.write_text(task_xml(script_path, python_executable), encoding="utf-16")
        _run(create_task_command(script_path, python_executable, xml_path=xml_path), operation="create")


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
