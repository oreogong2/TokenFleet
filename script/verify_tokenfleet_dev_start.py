#!/usr/bin/env python3
"""Verify the one-command development server without exposing credentials.

The verifier uses a temporary SQLite state directory and terminates the child
server (including its process group) before returning.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


DEV_ORG = "dev-team"
DEV_EMAIL = "admin@example.com"
DEV_PASSWORD = "tokenfleet-local-dev-only"


def free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def request_json(
    base_url: str,
    path: str,
    *,
    method: str = "GET",
    payload: dict[str, object] | None = None,
    token: str | None = None,
) -> tuple[int, dict[str, object]]:
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(
        f"{base_url}{path}", data=body, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())


def wait_until_ready(
    base_url: str, process: subprocess.Popen[str], *, timeout_seconds: int
) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("development server exited before becoming ready")
        try:
            status, payload = request_json(base_url, "/readyz")
            if status == 200 and payload.get("status") == "ready":
                return
        except (OSError, ValueError):
            pass
        time.sleep(0.1)
    raise TimeoutError(
        f"development server did not become ready within {timeout_seconds} seconds"
    )


def stop_process_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--venv",
        type=Path,
        help="reuse an installed server venv and skip dependency installation",
    )
    args = parser.parse_args()

    script_path = Path(__file__).resolve().with_name("start_tokenfleet_dev.sh")
    port = free_loopback_port()
    base_url = f"http://127.0.0.1:{port}"
    with tempfile.TemporaryDirectory(prefix="tokenfleet-dev-start-") as state_dir:
        environment = {
            **os.environ,
            "TOKENFLEET_DEV_STATE_DIR": state_dir,
            "TOKENFLEET_DEV_PORT": str(port),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        if args.venv:
            environment["TOKENFLEET_DEV_VENV"] = str(args.venv.resolve())
            environment["TOKENFLEET_DEV_SKIP_INSTALL"] = "1"

        log_path = Path(state_dir) / "server.log"
        with log_path.open("w+", encoding="utf-8") as log_file:
            process = subprocess.Popen(
                [str(script_path)],
                env=environment,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )
            failed = False
            try:
                wait_until_ready(
                    base_url,
                    process,
                    timeout_seconds=30 if args.venv else 180,
                )
                health_status, health = request_json(base_url, "/healthz")
                ready_status, ready = request_json(base_url, "/readyz")
                root_request = urllib.request.Request(f"{base_url}/", method="GET")
                with urllib.request.urlopen(root_request, timeout=2) as root_response:
                    root_status = root_response.status
                    root_content_type = root_response.headers.get("Content-Type", "")

                unauthenticated_status, _ = request_json(base_url, "/api/v1/me")
                login_status, login = request_json(
                    base_url,
                    "/api/v1/auth/token",
                    method="POST",
                    payload={
                        "org_slug": DEV_ORG,
                        "email": DEV_EMAIL,
                        "password": DEV_PASSWORD,
                    },
                )
                token = str(login.get("access_token", ""))
                me_status, me = request_json(
                    base_url, "/api/v1/me", token=token
                )

                assert health_status == 200 and health == {"status": "ok"}
                assert ready_status == 200 and ready == {"status": "ready"}
                assert root_status == 200 and "text/html" in root_content_type
                assert unauthenticated_status == 401
                assert login_status == 200 and token
                assert me_status == 200
                assert me.get("email") == DEV_EMAIL
                assert me.get("role") == "admin"
            except Exception:
                failed = True
                raise
            finally:
                stop_process_group(process)
                if failed:
                    log_file.flush()
                    log_file.seek(0)
                    output = log_file.read(4_000).replace(
                        DEV_PASSWORD, "[redacted-dev-password]"
                    )
                    if output:
                        print(output, file=os.sys.stderr)

    print(
        json.dumps(
            {
                "status": "ok",
                "temporary_state_removed": True,
                "healthz": 200,
                "readyz": 200,
                "spa_root": 200,
                "unauthenticated_me": 401,
                "login": 200,
                "authenticated_me": 200,
                "secret_output": False,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
