#!/bin/zsh

set -euo pipefail
umask 077

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_ROOT/.." && pwd)"
SERVER_ROOT="$REPO_ROOT/server"
INVOCATION_ROOT="$PWD"
STATE_DIR="${TOKENFLEET_DEV_STATE_DIR:-${TMPDIR:-/tmp}/tokenfleet-dev}"
DEV_VENV_OVERRIDE="${TOKENFLEET_DEV_VENV:-}"
DEV_HOST="127.0.0.1"
DEV_PORT="${TOKENFLEET_DEV_PORT:-4311}"
DEV_ORG="${TOKENFLEET_DEV_ORG:-dev-team}"
DEV_EMAIL="${TOKENFLEET_DEV_ADMIN_EMAIL:-admin@example.com}"
DEV_PASSWORD="tokenfleet-local-dev-only"

mkdir -p "$STATE_DIR"
STATE_DIR="$(cd "$STATE_DIR" && pwd)"
if [[ -n "$DEV_VENV_OVERRIDE" ]]; then
  if [[ "$DEV_VENV_OVERRIDE" == /* ]]; then
    DEV_VENV="$DEV_VENV_OVERRIDE"
  else
    DEV_VENV="$INVOCATION_ROOT/$DEV_VENV_OVERRIDE"
  fi
else
  DEV_VENV="$STATE_DIR/venv"
fi

if [[ ! -x "$DEV_VENV/bin/python" ]]; then
  if [[ "${TOKENFLEET_DEV_SKIP_INSTALL:-0}" == "1" ]]; then
    print -u2 "TOKENFLEET_DEV_SKIP_INSTALL=1 requires an existing TOKENFLEET_DEV_VENV"
    exit 1
  fi
  python3 -m venv "$DEV_VENV"
fi

if [[ "${TOKENFLEET_DEV_SKIP_INSTALL:-0}" != "1" ]]; then
  DEPS_FINGERPRINT="$(cksum \
    "$SERVER_ROOT/requirements.txt" \
    "$SERVER_ROOT/requirements-dev.txt" \
    "$SERVER_ROOT/constraints.txt" | cksum | awk '{print $1 "-" $2}')"
  DEPS_STAMP="$DEV_VENV/.tokenfleet-dependencies"
  INSTALLED_FINGERPRINT=""
  if [[ -f "$DEPS_STAMP" ]]; then
    INSTALLED_FINGERPRINT="$(<"$DEPS_STAMP")"
  fi
  if [[ "$INSTALLED_FINGERPRINT" != "$DEPS_FINGERPRINT" ]]; then
    "$DEV_VENV/bin/pip" install \
      -r "$SERVER_ROOT/requirements-dev.txt" \
      -c "$SERVER_ROOT/constraints.txt"
    print -r -- "$DEPS_FINGERPRINT" > "$DEPS_STAMP"
  fi
elif [[ ! -x "$DEV_VENV/bin/uvicorn" ]]; then
  print -u2 "the supplied TOKENFLEET_DEV_VENV does not contain uvicorn"
  exit 1
fi

export PYTHONDONTWRITEBYTECODE=1
export ENVIRONMENT=development
export DATABASE_URL="sqlite:///$STATE_DIR/tokenfleet.db"
export WEB_ROOT="$REPO_ROOT/web"
export JWT_SECRET
JWT_SECRET="$("$DEV_VENV/bin/python" -c 'import secrets; print(secrets.token_urlsafe(48))')"

cd "$SERVER_ROOT"
"$DEV_VENV/bin/python" -m app.cli init-db

if ! "$DEV_VENV/bin/python" -c '
import sys
from sqlalchemy import create_engine, text

engine = create_engine(sys.argv[1])
try:
    with engine.connect() as connection:
        exists = connection.scalar(
            text(
                "SELECT COUNT(*) FROM users u "
                "JOIN organizations o ON o.id = u.org_id "
                "WHERE o.slug = :slug AND u.email = :email AND u.role = :role"
            ),
            {"slug": sys.argv[2], "email": sys.argv[3].lower(), "role": "ADMIN"},
        )
finally:
    engine.dispose()
raise SystemExit(0 if exists else 1)
' "$DATABASE_URL" "$DEV_ORG" "$DEV_EMAIL"; then
  BOOTSTRAP_ADMIN_PASSWORD="$DEV_PASSWORD" \
    "$DEV_VENV/bin/python" -m app.cli create-admin \
      --org-slug "$DEV_ORG" \
      --org-name "TokenFleet Dev Team" \
      --email "$DEV_EMAIL"
fi

print "TokenFleet development server: http://$DEV_HOST:$DEV_PORT"
print "Development login: organization=$DEV_ORG email=$DEV_EMAIL password=$DEV_PASSWORD"
print "Local state: $STATE_DIR"
print "The runtime JWT signing secret is generated in memory and is not written to disk."

exec "$DEV_VENV/bin/uvicorn" app.main:app --host "$DEV_HOST" --port "$DEV_PORT"
