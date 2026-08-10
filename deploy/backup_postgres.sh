#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${TOKENFLEET_ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_FILE="$SCRIPT_DIR/compose.prod.yml"
PROJECT_NAME="${TOKENFLEET_COMPOSE_PROJECT:-tokenfleet}"
BACKUP_DIR="${TOKENFLEET_BACKUP_DIR:-$SCRIPT_DIR/backups}"
RETENTION_DAYS="${TOKENFLEET_BACKUP_RETENTION_DAYS:-14}"
PRUNE=0

if [[ "${1:-}" == "--prune" ]]; then
  PRUNE=1
elif [[ $# -ne 0 ]]; then
  printf 'Usage: deploy/backup_postgres.sh [--prune]\n' >&2
  exit 2
fi

[[ -f "$ENV_FILE" ]] || { printf 'Missing environment file: %s\n' "$ENV_FILE" >&2; exit 1; }
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && [[ "$RETENTION_DAYS" -ge 7 ]] \
  || { printf 'Backup retention must be at least 7 days.\n' >&2; exit 1; }

python3 "$SCRIPT_DIR/prepare_env.py" --output "$ENV_FILE" --check >/dev/null
mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd -P)"
[[ "$BACKUP_DIR" != "/" && "$BACKUP_DIR" != "/var" && "$BACKUP_DIR" != "/tmp" ]] \
  || { printf 'Refusing unsafe backup directory: %s\n' "$BACKUP_DIR" >&2; exit 1; }

compose() {
  docker compose --project-name "$PROJECT_NAME" \
    --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final_path="$BACKUP_DIR/tokenfleet-${timestamp}.dump"
temporary_path="$(mktemp "$BACKUP_DIR/.tokenfleet-${timestamp}.XXXXXX")"
cleanup() {
  rm -f "$temporary_path"
}
trap cleanup EXIT

compose exec -T db pg_dump \
  --username tokenfleet --dbname tokenfleet --format=custom > "$temporary_path"
[[ -s "$temporary_path" ]] || { printf 'PostgreSQL backup was empty.\n' >&2; exit 1; }
compose exec -T db pg_restore --list < "$temporary_path" >/dev/null
chmod 0600 "$temporary_path"
mv "$temporary_path" "$final_path"
trap - EXIT

(
  cd "$BACKUP_DIR"
  sha256sum "$(basename "$final_path")" > "$(basename "$final_path").sha256"
)
chmod 0600 "$final_path" "$final_path.sha256"

if [[ "$PRUNE" -eq 1 ]]; then
  find "$BACKUP_DIR" -type f \
    \( -name 'tokenfleet-*.dump' -o -name 'tokenfleet-*.dump.sha256' \) \
    -mtime "+$RETENTION_DAYS" -delete
fi

printf 'Created and verified PostgreSQL backup: %s\n' "$final_path"
