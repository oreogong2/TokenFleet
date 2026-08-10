#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEPLOY_ROOT="$REPO_ROOT/deploy"
TEMP_ROOT="$(mktemp -d /tmp/tokenfleet-production-verify.XXXXXX)"
cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

for script in \
  "$DEPLOY_ROOT/tokenfleet.sh" \
  "$DEPLOY_ROOT/install_nginx_certbot.sh" \
  "$DEPLOY_ROOT/install_nginx_certbot_alibaba.sh" \
  "$DEPLOY_ROOT/backup_postgres.sh" \
  "$DEPLOY_ROOT/verify_backup.sh" \
  "$DEPLOY_ROOT/install_backup_timer.sh" \
  "$REPO_ROOT/script/verify_production_docker_e2e.sh"; do
  bash -n "$script"
done

PYTHONPYCACHEPREFIX="$TEMP_ROOT/pycache" \
  python3 -m compileall -q \
  "$DEPLOY_ROOT/prepare_env.py" \
  "$DEPLOY_ROOT/render_nginx.py" \
  "$DEPLOY_ROOT/tests"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s "$DEPLOY_ROOT/tests" -v

ENV_FILE="$TEMP_ROOT/production.env"
python3 "$DEPLOY_ROOT/prepare_env.py" \
  --output "$ENV_FILE" \
  --domain rank.example.com \
  --org-slug example-community >/dev/null
python3 "$DEPLOY_ROOT/prepare_env.py" --output "$ENV_FILE" --check >/dev/null
[[ "$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE")" == "600" ]]

RENDERED_NGINX="$TEMP_ROOT/tokenfleet.conf"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$DEPLOY_ROOT" \
  python3 "$DEPLOY_ROOT/render_nginx.py" \
  --template "$DEPLOY_ROOT/nginx/tokenfleet.conf.template" \
  --output "$RENDERED_NGINX" \
  --domain rank.example.com \
  --app-port 18080
! grep -q '__TOKENFLEET_' "$RENDERED_NGINX"
grep -q 'server_name rank.example.com;' "$RENDERED_NGINX"
grep -q '127.0.0.1:18080' "$RENDERED_NGINX"

for template in \
  tokenfleet-acme-bootstrap.conf.template \
  tokenfleet-direct-tls.conf.template; do
  rendered="$TEMP_ROOT/$template"
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$DEPLOY_ROOT" \
    python3 "$DEPLOY_ROOT/render_nginx.py" \
    --template "$DEPLOY_ROOT/nginx/$template" \
    --output "$rendered" \
    --domain rank.example.com \
    --app-port 18080
  ! grep -q '__TOKENFLEET_' "$rendered"
  grep -q 'server_name rank.example.com;' "$rendered"
done

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if ! docker compose --env-file "$ENV_FILE" \
    -f "$DEPLOY_ROOT/compose.prod.yml" config --quiet >/dev/null; then
    printf 'Docker Compose rejected deploy/compose.prod.yml.\n' >&2
    exit 1
  fi
else
  printf 'Docker Compose syntax check skipped: Compose v2 is unavailable.\n'
fi

git -C "$REPO_ROOT" diff --check -- .dockerignore deploy script/verify_production_deployment.sh
printf 'TokenFleet production deployment verification passed.\n'
