#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 2 ]] || { echo "Usage: build_codex_history_decoder.sh architecture output" >&2; exit 2; }
[[ "$1" == arm64 || "$1" == x86_64 ]] || exit 2
SDK_PATH="${TOKENFLEET_SWIFT_SDK:-${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}}"
/usr/bin/clang -O2 -std=c99 -target "$1-apple-macos14.0" -isysroot "$SDK_PATH" \
  "$ROOT_DIR/script/codex_history_decoder.c" -o "$2"
