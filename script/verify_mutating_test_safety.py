#!/usr/bin/env python3
"""Fail-closed checks for TokenFleet verifiers that create server data."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
E2E = ROOT / "script" / "verify_tokenfleet_e2e.py"
LIVE_WEB = ROOT / "script" / "verify_tokenfleet_live_web.py"


def run_refusal(script: Path, *arguments: str, environment: dict[str, str] | None = None) -> str:
    env = os.environ.copy()
    for key in (
        "TOKENFLEET_E2E_CONFIRM_BASE_URL",
        "TOKENFLEET_ALLOW_MUTATING_E2E",
        "TOKENFLEET_E2E_PASSWORD",
    ):
        env.pop(key, None)
    if environment:
        env.update(environment)
    result = subprocess.run(
        [sys.executable, str(script), *arguments],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    if result.returncode == 0:
        raise AssertionError(f"{script.name} unexpectedly ran without a complete write confirmation")
    output = f"{result.stdout}\n{result.stderr}"
    if "refusing to" not in output:
        raise AssertionError(f"{script.name} did not fail at the write guard: {output[:500]}")
    return output


def main() -> None:
    run_refusal(E2E)
    run_refusal(E2E, "--allow-write-test-data")
    run_refusal(
        E2E,
        "--allow-write-test-data",
        environment={"TOKENFLEET_E2E_CONFIRM_BASE_URL": "http://127.0.0.1:65534"},
    )
    run_refusal(LIVE_WEB)
    run_refusal(
        LIVE_WEB,
        environment={
            "TOKENFLEET_ALLOW_MUTATING_E2E": "YES",
            "TOKENFLEET_E2E_CONFIRM_BASE_URL": "http://127.0.0.1:65534",
        },
    )

    e2e_source = E2E.read_text(encoding="utf-8")
    live_source = LIVE_WEB.read_text(encoding="utf-8")
    if "response.text" in e2e_source:
        raise AssertionError("API verifier can expose a secret-bearing response body")
    if 'page.locator("body").inner_text()' in live_source:
        raise AssertionError("browser verifier can expose an enrollment token in the page body")
    if '"sensitive_body_suppressed": True' not in live_source:
        raise AssertionError("browser verifier failure output lacks an explicit suppression marker")

    print("TokenFleet mutating verifier safety checks passed")


if __name__ == "__main__":
    main()
