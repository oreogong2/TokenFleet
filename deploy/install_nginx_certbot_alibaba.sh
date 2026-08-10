#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${TOKENFLEET_ENV_FILE:-$SCRIPT_DIR/.env}"
SITE_FILE="/etc/nginx/conf.d/tokenfleet.conf"
PROXY_SNIPPET="/etc/nginx/snippets/tokenfleet-proxy-headers.conf"
HOOK_FILE="/etc/letsencrypt/renewal-hooks/deploy/tokenfleet-deploy-hook.sh"
SERVICE_FILE="/etc/systemd/system/tokenfleet-certbot-renew.service"
TIMER_FILE="/etc/systemd/system/tokenfleet-certbot-renew.timer"
EXPECTED_IP=""
CERTBOT_EMAIL=""
REUSE_EXISTING_ACCOUNT=0
RECONFIGURE=0

fail() {
  printf 'TokenFleet direct TLS setup: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sudo deploy/install_nginx_certbot_alibaba.sh \
  --expected-ip 203.0.113.10 \
  (--email ops@example.com | --reuse-existing-account) [--reconfigure]

This variant is for an existing Alibaba Cloud Linux host whose Nginx loads
/etc/nginx/conf.d/*.conf and whose Certbot may live at /opt/certbot/bin/certbot.
It uses webroot issuance and never lets Certbot rewrite unrelated Nginx sites.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)
      [[ $# -ge 2 ]] || fail "--email requires a value"
      CERTBOT_EMAIL="$2"
      shift 2
      ;;
    --reuse-existing-account)
      REUSE_EXISTING_ACCOUNT=1
      shift
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

[[ "$(id -u)" -eq 0 ]] || fail "run as root on the target server"
[[ -f "$ENV_FILE" ]] || fail "missing protected environment file: $ENV_FILE"
[[ -n "$EXPECTED_IP" ]] || fail "--expected-ip is required"
if [[ -n "$CERTBOT_EMAIL" && "$REUSE_EXISTING_ACCOUNT" -eq 1 ]]; then
  fail "choose either --email or --reuse-existing-account"
fi
if [[ -z "$CERTBOT_EMAIL" && "$REUSE_EXISTING_ACCOUNT" -ne 1 ]]; then
  fail "--email or --reuse-existing-account is required"
fi
if [[ -n "$CERTBOT_EMAIL" && ! "$CERTBOT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  fail "--email must be a valid address"
fi

command -v nginx >/dev/null 2>&1 || fail "nginx is not installed"
command -v python3 >/dev/null 2>&1 || fail "python3 is not installed"
command -v curl >/dev/null 2>&1 || fail "curl is not installed"
command -v systemctl >/dev/null 2>&1 || fail "systemd is required"

if [[ -n "${TOKENFLEET_CERTBOT_BIN:-}" ]]; then
  CERTBOT_BIN="$TOKENFLEET_CERTBOT_BIN"
elif [[ -x /opt/certbot/bin/certbot ]]; then
  CERTBOT_BIN=/opt/certbot/bin/certbot
else
  CERTBOT_BIN="$(command -v certbot || true)"
fi
[[ "$CERTBOT_BIN" == /* && -x "$CERTBOT_BIN" && "$CERTBOT_BIN" != *$'\n'* && "$CERTBOT_BIN" != *' '* ]] \
  || fail "an absolute executable Certbot path without whitespace is required"

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
    for item in socket.getaddrinfo(domain, 80, type=socket.SOCK_STREAM)
}
if expected_ip not in resolved:
    raise SystemExit(
        f"DNS for {domain} does not include expected server IP {expected_ip}; "
        f"resolved values: {', '.join(sorted(map(str, resolved))) or 'none'}"
    )
PY

curl --fail --silent --show-error "http://127.0.0.1:${APP_PORT}/readyz" >/dev/null \
  || fail "TokenFleet is not ready on the configured loopback port"
[[ ! -e "$SITE_FILE" || "$RECONFIGURE" -eq 1 ]] \
  || fail "$SITE_FILE already exists; inspect it or pass --reconfigure"

WORK_DIR="$(mktemp -d /tmp/tokenfleet-direct-tls.XXXXXX)"
BACKUP_FILE="$WORK_DIR/tokenfleet.conf.previous"
HAD_SITE=0
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ -e "$SITE_FILE" ]]; then
  cp -p "$SITE_FILE" "$BACKUP_FILE"
  HAD_SITE=1
fi

rollback_nginx() {
  if [[ "$HAD_SITE" -eq 1 ]]; then
    install -m 0644 "$BACKUP_FILE" "$SITE_FILE"
  else
    rm -f "$SITE_FILE"
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
}

render() {
  local template="$1" output="$2"
  PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPT_DIR/render_nginx.py" \
    --template "$template" \
    --output "$output" \
    --domain "$DOMAIN" \
    --app-port "$APP_PORT"
}

install -d -m 0755 /var/lib/letsencrypt/.well-known/acme-challenge
install -d -m 0755 /etc/nginx/snippets
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
install -m 0644 "$SCRIPT_DIR/nginx/tokenfleet-proxy-headers.conf" "$PROXY_SNIPPET"

render "$SCRIPT_DIR/nginx/tokenfleet-acme-bootstrap.conf.template" "$WORK_DIR/bootstrap.conf"
install -m 0644 "$WORK_DIR/bootstrap.conf" "$SITE_FILE"
if ! nginx -t; then
  rollback_nginx
  fail "bootstrap Nginx validation failed; previous TokenFleet site restored"
fi
systemctl reload nginx

certbot_args=(
  certonly --webroot --webroot-path /var/lib/letsencrypt
  --cert-name "$DOMAIN" -d "$DOMAIN"
  --non-interactive --agree-tos
)
if [[ -n "$CERTBOT_EMAIL" ]]; then
  certbot_args+=(--email "$CERTBOT_EMAIL")
else
  "$CERTBOT_BIN" show_account >/dev/null \
    || { rollback_nginx; fail "no reusable Certbot account is available"; }
fi
if ! "$CERTBOT_BIN" "${certbot_args[@]}"; then
  rollback_nginx
  fail "certificate issuance failed; previous TokenFleet site restored"
fi

render "$SCRIPT_DIR/nginx/tokenfleet-direct-tls.conf.template" "$WORK_DIR/final.conf"
install -m 0644 "$WORK_DIR/final.conf" "$SITE_FILE"
if ! nginx -t; then
  rollback_nginx
  fail "final Nginx validation failed; previous TokenFleet site restored"
fi
systemctl reload nginx

sed "s|__TOKENFLEET_DOMAIN__|$DOMAIN|g" > "$WORK_DIR/deploy-hook.sh" <<'HOOK'
#!/bin/sh
set -eu
if [ "${RENEWED_LINEAGE:-}" != "/etc/letsencrypt/live/__TOKENFLEET_DOMAIN__" ]; then
  exit 0
fi
/usr/sbin/nginx -t
/usr/bin/systemctl reload nginx
HOOK
install -m 0755 "$WORK_DIR/deploy-hook.sh" "$HOOK_FILE"

cat > "$WORK_DIR/renew.service" <<EOF
[Unit]
Description=Renew the TokenFleet TLS certificate
After=network-online.target nginx.service
Wants=network-online.target
ConditionPathExists=/etc/letsencrypt/renewal/${DOMAIN}.conf

[Service]
Type=oneshot
ExecStart=${CERTBOT_BIN} renew --cert-name ${DOMAIN} --quiet
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt
NoNewPrivileges=true
EOF

cat > "$WORK_DIR/renew.timer" <<'EOF'
[Unit]
Description=Run TokenFleet certificate renewal twice daily

[Timer]
OnCalendar=*-*-* 01,13:00:00
RandomizedDelaySec=2h
Persistent=true
Unit=tokenfleet-certbot-renew.service

[Install]
WantedBy=timers.target
EOF

install -m 0644 "$WORK_DIR/renew.service" "$SERVICE_FILE"
install -m 0644 "$WORK_DIR/renew.timer" "$TIMER_FILE"
systemctl daemon-reload
systemctl enable --now tokenfleet-certbot-renew.timer

"$CERTBOT_BIN" renew --cert-name "$DOMAIN" --dry-run --run-deploy-hooks
curl --fail --silent --show-error "https://${DOMAIN}/readyz" >/dev/null
printf 'TokenFleet HTTPS is ready: https://%s/rank\n' "$DOMAIN"
