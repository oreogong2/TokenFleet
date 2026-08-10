#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ENV_FILE="${TOKENFLEET_ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_FILE="$SCRIPT_DIR/compose.prod.yml"
PROJECT_NAME="${TOKENFLEET_COMPOSE_PROJECT:-tokenfleet}"

fail() {
  printf 'TokenFleet: %s\n' "$1" >&2
  exit 1
}

require_env() {
  [[ -f "$ENV_FILE" ]] || fail "missing protected environment file: $ENV_FILE"
  python3 "$SCRIPT_DIR/prepare_env.py" --output "$ENV_FILE" --check >/dev/null
}

compose() {
  docker compose --project-name "$PROJECT_NAME" \
    --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

wait_until_ready() {
  local app_port attempt
  app_port="$(python3 "$SCRIPT_DIR/prepare_env.py" --output "$ENV_FILE" --get APP_PORT)"
  for attempt in $(seq 1 60); do
    if curl --fail --silent --show-error \
      "http://127.0.0.1:${app_port}/readyz" >/dev/null 2>&1; then
      printf 'TokenFleet is ready on loopback port %s.\n' "$app_port"
      return 0
    fi
    sleep 1
  done
  compose ps >&2 || true
  compose logs --tail 100 app migrate db >&2 || true
  fail "readiness did not become healthy within 60 seconds"
}

doctor() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required"
  command -v docker >/dev/null 2>&1 || fail "Docker is required"
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required"
  require_env
  compose config --quiet
  printf 'TokenFleet production configuration validation passed.\n'
}

usage() {
  cat <<'EOF'
Usage: deploy/tokenfleet.sh <command> [arguments]

Commands:
  doctor                         Validate prerequisites and production config
  up                             Build, migrate, and start one app + PostgreSQL
  migrate                        Apply Alembic migrations only
  create-admin <name> <email>    Create the first administrator (password hidden)
  status                         Show containers and local health/readiness
  logs                           Show the latest app/database/migration logs
  backup                         Create and verify a PostgreSQL backup
  stop                           Stop app and database without deleting data
EOF
}

command_name="${1:-}"
case "$command_name" in
  doctor)
    doctor
    ;;
  up)
    doctor
    compose up --detach --build
    wait_until_ready
    ;;
  migrate)
    doctor
    compose run --rm migrate
    ;;
  create-admin)
    [[ $# -eq 3 ]] || fail "create-admin requires organization name and email"
    doctor
    org_slug="$(python3 "$SCRIPT_DIR/prepare_env.py" --output "$ENV_FILE" --get PUBLIC_ORG_SLUG)"
    compose run --rm --no-deps app \
      python -m app.cli create-admin \
      --org-slug "$org_slug" \
      --org-name "$2" \
      --email "$3"
    ;;
  status)
    doctor
    compose ps
    app_port="$(python3 "$SCRIPT_DIR/prepare_env.py" --output "$ENV_FILE" --get APP_PORT)"
    curl --fail --silent --show-error "http://127.0.0.1:${app_port}/healthz"
    printf '\n'
    curl --fail --silent --show-error "http://127.0.0.1:${app_port}/readyz"
    printf '\n'
    ;;
  logs)
    doctor
    compose logs --tail 200 app migrate db
    ;;
  backup)
    require_env
    TOKENFLEET_ENV_FILE="$ENV_FILE" "$SCRIPT_DIR/backup_postgres.sh"
    ;;
  stop)
    doctor
    compose stop app db
    ;;
  help|-h|--help|"")
    usage
    ;;
  *)
    usage >&2
    fail "unknown command: $command_name"
    ;;
esac
