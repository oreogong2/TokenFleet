from __future__ import annotations

import os
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

from .constants import (
    RUN_KEY_PATH,
    RUN_VALUE_NAME,
    STARTUP_LOOP_MUTEX_NAME,
    SYNC_INTERVAL_SECONDS,
    SYNC_RETRY_SECONDS,
    TASK_NAME,
)


class SchedulerError(RuntimeError):
    pass


def task_action(script_path: Path, python_executable: Path | None = None) -> str:
    executable = python_executable or Path(sys.executable)
    if executable.name.lower() == "python.exe":
        pythonw = executable.with_name("pythonw.exe")
        if pythonw.exists():
            executable = pythonw
    return f'"{executable}" "{script_path.resolve()}" sync --quiet'


def startup_action(script_path: Path, python_executable: Path | None = None) -> str:
    executable = python_executable or Path(sys.executable)
    if executable.name.lower() == "python.exe":
        pythonw = executable.with_name("pythonw.exe")
        if pythonw.exists():
            executable = pythonw
    return f'"{executable}" "{script_path.resolve()}" scheduled-loop'


def create_task_command(script_path: Path) -> list[str]:
    return [
        "schtasks.exe",
        "/Create",
        "/TN",
        TASK_NAME,
        "/TR",
        task_action(script_path),
        "/SC",
        "HOURLY",
        "/MO",
        "6",
        "/RL",
        "LIMITED",
        "/F",
    ]


def register(script_path: Path) -> str:
    try:
        _run(create_task_command(script_path), operation="create")
    except SchedulerError:
        try:
            _register_startup(script_path)
        except SchedulerError as startup_error:
            raise SchedulerError(
                "TokenFleet automatic sync registration failed"
            ) from startup_error
        return "startup_loop"
    _unregister_startup(ignore_missing=True)
    return "task_scheduler"


def unregister(*, ignore_missing: bool = True) -> None:
    task_registered = is_task_registered()
    startup_registered = is_startup_registered()
    if task_registered:
        _run(
            ["schtasks.exe", "/Delete", "/TN", TASK_NAME, "/F"],
            operation="delete",
            check=True,
        )
    elif not ignore_missing and not startup_registered:
        raise SchedulerError("TokenFleet automatic sync registration is missing")
    _unregister_startup(ignore_missing=True)


def is_task_registered() -> bool:
    if os.name != "nt":
        return False
    result = _run(
        ["schtasks.exe", "/Query", "/TN", TASK_NAME],
        operation="query",
        check=False,
    )
    return result.returncode == 0


def is_startup_registered(script_path: Path | None = None) -> bool:
    if os.name != "nt":
        return False
    try:
        value = _read_startup_value()
    except SchedulerError:
        return False
    if value is None:
        return False
    return script_path is None or value == startup_action(script_path)


def scheduler_backend(script_path: Path | None = None) -> str | None:
    if is_task_registered():
        return "task_scheduler"
    if is_startup_registered(script_path):
        return "startup_loop"
    return None


def is_registered(script_path: Path | None = None) -> bool:
    return scheduler_backend(script_path) is not None


def run_startup_loop(script_path: Path, sync_once: Callable[[], object]) -> None:
    mutex = _acquire_loop_mutex()
    if mutex is None:
        return
    try:
        while is_startup_registered(script_path):
            delay = SYNC_INTERVAL_SECONDS
            try:
                sync_once()
            except Exception:
                # The background process has no console. Retry transient failures
                # without persisting response bodies, paths, or credentials.
                delay = SYNC_RETRY_SECONDS
            if not _sleep_while_registered(script_path, delay):
                return
    finally:
        _release_loop_mutex(mutex)


def _register_startup(script_path: Path) -> None:
    if os.name != "nt":
        raise SchedulerError("Windows startup registration is unavailable")
    try:
        import winreg

        with winreg.CreateKeyEx(
            winreg.HKEY_CURRENT_USER,
            RUN_KEY_PATH,
            0,
            winreg.KEY_SET_VALUE,
        ) as key:
            winreg.SetValueEx(
                key,
                RUN_VALUE_NAME,
                0,
                winreg.REG_SZ,
                startup_action(script_path),
            )
    except (OSError, ValueError) as exc:
        raise SchedulerError("TokenFleet startup registration failed") from exc


def _read_startup_value() -> str | None:
    try:
        import winreg

        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            RUN_KEY_PATH,
            0,
            winreg.KEY_QUERY_VALUE,
        ) as key:
            value, value_type = winreg.QueryValueEx(key, RUN_VALUE_NAME)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise SchedulerError("TokenFleet startup registration query failed") from exc
    if value_type != winreg.REG_SZ or not isinstance(value, str):
        return None
    return value


def _unregister_startup(*, ignore_missing: bool) -> None:
    if os.name != "nt":
        if ignore_missing:
            return
        raise SchedulerError("Windows startup registration is unavailable")
    try:
        import winreg

        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            RUN_KEY_PATH,
            0,
            winreg.KEY_SET_VALUE,
        ) as key:
            winreg.DeleteValue(key, RUN_VALUE_NAME)
    except FileNotFoundError:
        if not ignore_missing:
            raise SchedulerError("TokenFleet startup registration is missing")
    except OSError as exc:
        raise SchedulerError("TokenFleet startup registration removal failed") from exc


def _acquire_loop_mutex() -> int | None:
    if os.name != "nt":
        raise SchedulerError("Windows startup loop is unavailable")
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateMutexW.argtypes = [
        wintypes.LPVOID,
        wintypes.BOOL,
        wintypes.LPCWSTR,
    ]
    kernel32.CreateMutexW.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    ctypes.set_last_error(0)
    handle = kernel32.CreateMutexW(None, False, STARTUP_LOOP_MUTEX_NAME)
    if not handle:
        raise SchedulerError("TokenFleet startup loop lock failed")
    if ctypes.get_last_error() == 183:  # ERROR_ALREADY_EXISTS
        kernel32.CloseHandle(handle)
        return None
    return int(handle)


def _release_loop_mutex(handle: int) -> None:
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    kernel32.CloseHandle(handle)


def _sleep_while_registered(script_path: Path, delay_seconds: int) -> bool:
    remaining = delay_seconds
    while remaining > 0:
        time.sleep(min(60, remaining))
        if not is_startup_registered(script_path):
            return False
        remaining -= min(60, remaining)
    return True


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
