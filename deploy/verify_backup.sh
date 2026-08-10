#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${TOKENFLEET_ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_FILE="$SCRIPT_DIR/compose.prod.yml"
PROJECT_NAME="${TOKENFLEET_COMPOSE_PROJECT:-tokenfleet}"

[[ $# -eq 1 ]] || { printf 'Usage: deploy/verify_backup.sh /path/to/tokenfleet.dump\n' >&2; exit 2; }
BACKUP_PATH="$1"
[[ -f "$BACKUP_PATH" && ! -L "$BACKUP_PATH" ]] \
  || { printf 'Backup must be a regular non-symlink file.\n' >&2; exit 1; }
[[ -f "$BACKUP_PATH.sha256" && ! -L "$BACKUP_PATH.sha256" ]] \
  || { printf 'Missing checksum file: %s.sha256\n' "$BACKUP_PATH" >&2; exit 1; }

(
  cd "$(dirname "$BACKUP_PATH")"
  sha256sum --check "$(basename "$BACKUP_PATH").sha256"
)

docker compose --project-name "$PROJECT_NAME" \
  --env-file "$ENV_FILE" -f "$COMPOSE_FILE" \
  exec -T db pg_restore --list < "$BACKUP_PATH" >/dev/null
printf 'Backup checksum and PostgreSQL archive structure are valid.\n'
