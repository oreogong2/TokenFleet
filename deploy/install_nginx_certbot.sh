#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${TOKENFLEET_ENV_FILE:-$SCRIPT_DIR/.env}"
SITE_AVAILABLE="/etc/nginx/sites-available/tokenfleet"
SITE_ENABLED="/etc/nginx/sites-enabled/tokenfleet"
PROXY_SNIPPET="/etc/nginx/snippets/tokenfleet-proxy-headers.conf"
RECONFIGURE=0
EXPECTED_IP=""
CERTBOT_EMAIL=""

fail() {
  printf 'TokenFleet TLS setup: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sudo deploy/install_nginx_certbot.sh \
  --email ops@example.com --expected-ip 203.0.113.10 [--reconfigure]

The domain and loopback application port are read from protected deploy/.env.
The script requires Nginx, Certbot, and the Certbot Nginx plugin to be installed.
It never reads or prints TokenFleet database/JWT secrets.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)
      [[ $# -ge 2 ]] || fail "--email requires a value"
      CERTBOT_EMAIL="$2"
      shift 2
      ;;
    --expected-ip)
      [[ $# -ge 2 ]] || fail "--expected-ip requires a value"
      EXPECTED_IP="$2"
      shift 2
      ;;
    --reconfigure)
      RECONFIGURE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || fail "run with sudo on the target Ubuntu server"
[[ -f "$ENV_FILE" ]] || fail "missing protected environment file: $ENV_FILE"
[[ "$CERTBOT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
  || fail "a valid --email is required"
[[ -n "$EXPECTED_IP" ]] || fail "--expected-ip is required"

command -v nginx >/dev/null 2>&1 || fail "nginx is not installed"
command -v certbot >/dev/null 2>&1 || fail "certbot is not installed"
command -v python3 >/dev/null 2>&1 || fail "python3 is not installed"
command -v curl >/dev/null 2>&1 || fail "curl is not installed"

python3 "$SCRIPT_DIR/prepare_env.py" --output "$ENV_FILE" --check >/dev/null
DOMAIN="$(python3 "$SCRIPT_DIR/prepare_env.py" --output "$ENV_FILE" --get TOKENFLEET_DOMAIN)"
APP_PORT="$(python3 "$SCRIPT_DIR/prepare_env.py" --output "$ENV_FILE" --get APP_PORT)"

python3 - "$DOMAIN" "$EXPECTED_IP" <<'PY'
import ipaddress
import socket
import sys

domain, expected = sys.argv[1:]
expected_ip = ipaddress.ip_address(expected)
resolved = {
    ipaddress.ip_address(item[4][0])
    for item in socket.getaddrinfo(domain, 443, type=socket.SOCK_STREAM)
}
if expected_ip not in resolved:
    raise SystemExit(
        f"DNS for {domain} does not include expected server IP {expected_ip}; "
        f"resolved values: {', '.join(sorted(map(str, resolved))) or 'none'}"
    )
PY

curl --fail --silent --show-error "http://127.0.0.1:${APP_PORT}/readyz" >/dev/null \
  || fail "TokenFleet is not ready on the configured loopback port"

if [[ -e "$SITE_AVAILABLE" && "$RECONFIGURE" -ne 1 ]]; then
  fail "$SITE_AVAILABLE already exists; inspect it or pass --reconfigure"
fi

WORK_DIR="$(mktemp -d /tmp/tokenfleet-nginx.XXXXXX)"
BACKUP_FILE="$WORK_DIR/site.backup"
HAD_SITE=0
HAD_LINK=0
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPT_DIR/render_nginx.py" \
  --template "$SCRIPT_DIR/nginx/tokenfleet.conf.template" \
  --output "$WORK_DIR/tokenfleet.conf" \
  --domain "$DOMAIN" \
  --app-port "$APP_PORT"

if [[ -e "$SITE_AVAILABLE" ]]; then
  cp -p "$SITE_AVAILABLE" "$BACKUP_FILE"
  HAD_SITE=1
fi
if [[ -L "$SITE_ENABLED" || -e "$SITE_ENABLED" ]]; then
  HAD_LINK=1
fi

rollback_nginx() {
  if [[ "$HAD_SITE" -eq 1 ]]; then
    cp -p "$BACKUP_FILE" "$SITE_AVAILABLE"
  else
    rm -f "$SITE_AVAILABLE"
  fi
  if [[ "$HAD_LINK" -eq 0 ]]; then
    rm -f "$SITE_ENABLED"
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
}

install -m 0644 "$WORK_DIR/tokenfleet.conf" "$SITE_AVAILABLE"
install -m 0644 "$SCRIPT_DIR/nginx/tokenfleet-proxy-headers.conf" "$PROXY_SNIPPET"
ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"
if ! nginx -t; then
  rollback_nginx
  fail "Nginx validation failed; previous site configuration was restored"
fi
systemctl reload nginx

if ! certbot --nginx --non-interactive --agree-tos --redirect \
  --email "$CERTBOT_EMAIL" --domain "$DOMAIN"; then
  rollback_nginx
  fail "certificate issuance failed; previous site configuration was restored"
fi

if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
  systemctl enable --now certbot.timer
fi

certbot renew --dry-run
curl --fail --silent --show-error "https://${DOMAIN}/readyz" >/dev/null
printf 'TokenFleet HTTPS is ready: https://%s/rank\n' "$DOMAIN"
