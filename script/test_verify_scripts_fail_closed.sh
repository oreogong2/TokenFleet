#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tokenfleet-fake-rg.XXXXXX")"

cleanup() {
  local status=$?
  trap - EXIT
  rm -rf -- "$TEST_ROOT"
  exit "$status"
}
trap cleanup EXIT

printf '#!/bin/sh\nexit 2\n' >"$TEST_ROOT/rg"
chmod 700 "$TEST_ROOT/rg"

for verifier in \
  "$ROOT_DIR/script/verify_tokenstep_swift.sh" \
  "$ROOT_DIR/script/verify_tokenfleet_desktop_identity.sh"; do
  output="$TEST_ROOT/$(basename "$verifier").output"
  status=0
  PATH="$TEST_ROOT:/usr/bin:/bin" bash "$verifier" >"$output" 2>&1 || status=$?
  [[ "$status" -ne 0 ]] || {
    echo "fake rg error was masked by $(basename "$verifier")" >&2
    exit 1
  }
done

echo "PASS: verifier scripts fail closed when ripgrep exits with an error"
