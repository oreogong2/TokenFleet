#!/usr/bin/env bash
set -euo pipefail

[[ "${TOKENFLEET_ALLOW_DOCKER_E2E:-}" == "YES" ]] || {
  printf 'Set TOKENFLEET_ALLOW_DOCKER_E2E=YES to run isolated Docker E2E.\n' >&2
  exit 2
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEPLOY_ROOT="$REPO_ROOT/deploy"
TEMP_ROOT="$(mktemp -d /tmp/tokenfleet-production-docker-e2e.XXXXXX)"
PROJECT_NAME="tokenfleet-prod-e2e-$$"
ENV_FILE="$TEMP_ROOT/production.env"
BACKUP_DIR="$TEMP_ROOT/backups"
APP_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)"

compose() {
  docker compose --project-name "$PROJECT_NAME" \
    --env-file "$ENV_FILE" -f "$DEPLOY_ROOT/compose.prod.yml" "$@"
}

cleanup() {
  status=$?
  if [[ "$status" -ne 0 ]]; then
    compose ps >&2 || true
    compose logs --tail 120 app migrate db >&2 || true
  fi
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm "${PROJECT_NAME}-app:latest" \
    "${PROJECT_NAME}-migrate:latest" >/dev/null 2>&1 || true
  rm -rf "$TEMP_ROOT"
  exit "$status"
}
trap cleanup EXIT INT TERM

python3 "$DEPLOY_ROOT/prepare_env.py" \
  --output "$ENV_FILE" \
  --domain rank.example.com \
  --org-slug e2e-community \
  --app-port "$APP_PORT" >/dev/null

mkdir -p "$TEMP_ROOT/nginx/snippets"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$DEPLOY_ROOT" \
  python3 "$DEPLOY_ROOT/render_nginx.py" \
  --template "$DEPLOY_ROOT/nginx/tokenfleet.conf.template" \
  --output "$TEMP_ROOT/nginx/default.conf" \
  --domain rank.example.com \
  --app-port "$APP_PORT"
cp "$DEPLOY_ROOT/nginx/tokenfleet-proxy-headers.conf" \
  "$TEMP_ROOT/nginx/snippets/tokenfleet-proxy-headers.conf"
docker run --rm \
  --volume "$TEMP_ROOT/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  --volume "$TEMP_ROOT/nginx/snippets:/etc/nginx/snippets:ro" \
  nginx:alpine@sha256:4a73073bd557c65b759505da037898b61f1be6cbcc3c2c3aeac22d2a470c1752 nginx -t

compose up --detach --build

for _attempt in $(seq 1 90); do
  if curl --fail --silent --show-error \
    "http://127.0.0.1:${APP_PORT}/readyz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl --fail --silent --show-error \
  "http://127.0.0.1:${APP_PORT}/readyz" >/dev/null

compose run --rm --no-deps \
  --env BOOTSTRAP_ADMIN_PASSWORD=tokenfleet-e2e-admin-only \
  app python -m app.cli create-admin \
  --org-slug e2e-community \
  --org-name 'TokenFleet E2E Community' \
  --email admin@example.com >/dev/null

TOKENFLEET_E2E_PORT="$APP_PORT" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from __future__ import annotations

import json
import os
import urllib.request

base = f"http://127.0.0.1:{os.environ['TOKENFLEET_E2E_PORT']}"
proxy_headers = {
    "X-Forwarded-For": "198.51.100.23",
    "X-Forwarded-Proto": "https",
}

def request(path: str, *, method: str = "GET", body: dict | None = None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {**proxy_headers}
    if data is not None:
        headers["Content-Type"] = "application/json"
    with urllib.request.urlopen(
        urllib.request.Request(base + path, data=data, headers=headers, method=method),
        timeout=10,
    ) as response:
        return response.status, response.headers, response.read()

status, headers, body = request(
    "/api/v1/auth/token",
    method="POST",
    body={
        "org_slug": "e2e-community",
        "email": "admin@example.com",
        "password": "tokenfleet-e2e-admin-only",
    },
)
assert status == 200
payload = json.loads(body)
assert payload["access_token"] and payload["token_type"] == "bearer"
assert headers["Cache-Control"] == "no-store"

status, headers, body = request(
    "/api/v1/public/leaderboard?period=today&metric=tokens"
)
assert status == 200
public = json.loads(body)
assert public["period"] == "today" and public["metric"] == "tokens"
assert "public" in headers["Cache-Control"]

status, _headers, body = request("/rank")
assert status == 200 and b"TokenFleet" in body
PY

TOKENFLEET_ENV_FILE="$ENV_FILE" \
TOKENFLEET_COMPOSE_PROJECT="$PROJECT_NAME" \
TOKENFLEET_BACKUP_DIR="$BACKUP_DIR" \
  "$DEPLOY_ROOT/backup_postgres.sh"

BACKUP_PATH="$(find "$BACKUP_DIR" -type f -name 'tokenfleet-*.dump' -print -quit)"
[[ -n "$BACKUP_PATH" ]]
TOKENFLEET_ENV_FILE="$ENV_FILE" \
TOKENFLEET_COMPOSE_PROJECT="$PROJECT_NAME" \
  "$DEPLOY_ROOT/verify_backup.sh" "$BACKUP_PATH"

RESTORE_DB="tokenfleet_restore_check"
compose exec -T db createdb --username tokenfleet "$RESTORE_DB"
compose exec -T db pg_restore --username tokenfleet --dbname "$RESTORE_DB" \
  --no-owner < "$BACKUP_PATH"
[[ "$(compose exec -T db psql --username tokenfleet --dbname "$RESTORE_DB" \
  --tuples-only --no-align --command 'SELECT COUNT(*) FROM users;')" == "1" ]]
[[ -n "$(compose exec -T db psql --username tokenfleet --dbname "$RESTORE_DB" \
  --tuples-only --no-align --command 'SELECT version_num FROM alembic_version;')" ]]
compose exec -T db dropdb --username tokenfleet "$RESTORE_DB"

printf 'TokenFleet production Docker E2E passed: build, migration, auth, public Web/API, backup, and restore.\n'
