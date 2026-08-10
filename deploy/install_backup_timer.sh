#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ENV_FILE="${TOKENFLEET_ENV_FILE:-$SCRIPT_DIR/.env}"
BACKUP_DIR="${TOKENFLEET_BACKUP_DIR:-/var/backups/tokenfleet}"

[[ "$(id -u)" -eq 0 ]] || { printf 'Run with sudo on the target server.\n' >&2; exit 1; }
[[ "$REPO_ROOT" != *$'\n'* && "$REPO_ROOT" != *' '* ]] \
  || { printf 'Production repository path must not contain spaces or newlines.\n' >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { printf 'Missing environment file: %s\n' "$ENV_FILE" >&2; exit 1; }
python3 "$SCRIPT_DIR/prepare_env.py" --output "$ENV_FILE" --check >/dev/null

install -d -m 0700 "$BACKUP_DIR"
SERVICE_TMP="$(mktemp /tmp/tokenfleet-backup-service.XXXXXX)"
TIMER_TMP="$(mktemp /tmp/tokenfleet-backup-timer.XXXXXX)"
cleanup() {
  rm -f "$SERVICE_TMP" "$TIMER_TMP"
}
trap cleanup EXIT

printf '%s\n' \
  '[Unit]' \
  'Description=TokenFleet PostgreSQL backup' \
  'After=docker.service' \
  'Requires=docker.service' \
  '' \
  '[Service]' \
  'Type=oneshot' \
  "WorkingDirectory=$REPO_ROOT" \
  "Environment=TOKENFLEET_ENV_FILE=$ENV_FILE" \
  "Environment=TOKENFLEET_BACKUP_DIR=$BACKUP_DIR" \
  'Environment=TOKENFLEET_BACKUP_RETENTION_DAYS=14' \
  "ExecStart=$SCRIPT_DIR/backup_postgres.sh --prune" \
  'UMask=0077' > "$SERVICE_TMP"

printf '%s\n' \
  '[Unit]' \
  'Description=Run TokenFleet backup every day' \
  '' \
  '[Timer]' \
  'OnCalendar=*-*-* 03:17:00' \
  'RandomizedDelaySec=15m' \
  'Persistent=true' \
  'Unit=tokenfleet-backup.service' \
  '' \
  '[Install]' \
  'WantedBy=timers.target' > "$TIMER_TMP"

install -m 0644 "$SERVICE_TMP" /etc/systemd/system/tokenfleet-backup.service
install -m 0644 "$TIMER_TMP" /etc/systemd/system/tokenfleet-backup.timer
systemctl daemon-reload
systemctl enable --now tokenfleet-backup.timer
systemctl list-timers tokenfleet-backup.timer --no-pager
