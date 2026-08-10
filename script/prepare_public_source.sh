#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
  cat <<'USAGE'
Prepare a clean TokenFleet public-source snapshot without Git history.

Usage:
  ./script/prepare_public_source.sh --output /absolute/path/TokenFleet

The output path must not already exist. The script never deletes or overwrites
an existing directory.
USAGE
}

fail() {
  echo "TokenFleet public-source export failed: $*" >&2
  exit 2
}

OUTPUT=""
EXPORT_COMPLETE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || fail "--output requires an absolute path"
      OUTPUT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument; use --help"
      ;;
  esac
done

[[ -n "$OUTPUT" ]] || fail "--output is required"
[[ "$OUTPUT" == /* ]] || fail "--output must be an absolute path"
OUTPUT_PARENT="$(dirname "$OUTPUT")"
OUTPUT_NAME="$(basename "$OUTPUT")"
[[ -d "$OUTPUT_PARENT" ]] || fail "output parent directory must already exist"
[[ -n "$OUTPUT_NAME" && "$OUTPUT_NAME" != "." && "$OUTPUT_NAME" != ".." ]] \
  || fail "invalid output directory name"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
OUTPUT="$OUTPUT_PARENT/$OUTPUT_NAME"
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail "output already exists"
command -v rsync >/dev/null 2>&1 || fail "rsync is required"
command -v rg >/dev/null 2>&1 || fail "ripgrep (rg) is required"

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$EXPORT_COMPLETE" != true && -d "$OUTPUT" ]]; then
    rm -rf -- "$OUTPUT"
  fi
  exit "$status"
}
trap cleanup EXIT

mkdir -p "$OUTPUT"

# This is intentionally an exclusion-based export of the complete product
# tree. The fresh destination has no .git directory, so committed private
# history cannot follow the public snapshot.
rsync -a \
  --include='*/.env.example' \
  --exclude='.git/' \
  --exclude='.codex/' \
  --exclude='.github/workflows/release.yml' \
  --exclude='release/' \
  --exclude='artifacts/' \
  --exclude='.DS_Store' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.pytest_cache/' \
  --exclude='.venv/' \
  --exclude='.env' \
  --exclude='.env.*' \
  --exclude='*.p8' \
  --exclude='*.p12' \
  --exclude='*.pem' \
  --exclude='*.key' \
  --exclude='*.mobileprovision' \
  --exclude='*.sqlite' \
  --exclude='*.sqlite3' \
  --exclude='*.db' \
  --exclude='TokenStepSwift/.build/' \
  --exclude='TokenStepSwift/dist/' \
  --exclude='server/.venv/' \
  --exclude='docs/review/' \
  --exclude='docs/references/' \
  --exclude='docs/PROJECT_HANDOFF.md' \
  --exclude='docs/deliverables/TokenFleet-蓝白总览.png' \
  --exclude='deploy/ALIYUN_HANDOFF.md' \
  --exclude='brand/logo-concepts/' \
  "$ROOT_DIR/" "$OUTPUT/"

for forbidden_path in \
  "$OUTPUT/.git" \
  "$OUTPUT/docs/review" \
  "$OUTPUT/docs/references" \
  "$OUTPUT/docs/PROJECT_HANDOFF.md" \
  "$OUTPUT/deploy/ALIYUN_HANDOFF.md"; do
  [[ ! -e "$forbidden_path" && ! -L "$forbidden_path" ]] \
    || fail "private path entered export: ${forbidden_path#"$OUTPUT/"}"
done

if find "$OUTPUT" -type f \( \
    -name '.env' -o -name '.env.*' \
    -o -name '*.p8' -o -name '*.p12' -o -name '*.pem' \
    -o -name '*.key' -o -name '*.mobileprovision' \
    -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \
  \) ! -name '.env.example' -print -quit | rg -q .; then
  fail "credential, database, or private signing filename entered export"
fi

if rg -n --hidden \
    -g '!.git/**' \
    -g '!*.png' -g '!*.jpg' -g '!*.jpeg' -g '!*.gif' -g '!*.icns' \
    -e 'oreogong2@gmail\.com' \
    -e '/Users/oreo(?:/|$)' \
    -e '47\.97\.20\.13' \
    -e 'BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY' \
    "$OUTPUT"; then
  fail "personal path, deployment identifier, or private key marker entered export"
fi

[[ -f "$OUTPUT/server/.env.example" ]] \
  || fail "safe server/.env.example placeholder was not exported"
rg -q "<UNSET>" "$OUTPUT/server/.env.example" \
  || fail "server/.env.example does not contain fail-closed placeholders"

EXPORT_COMPLETE=true
echo "TokenFleet public-source snapshot prepared: $OUTPUT"
echo "Next: inspect the snapshot, run its verification gates, then initialize a new Git repository."
