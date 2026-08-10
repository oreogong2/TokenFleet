# TokenFleet community server

TokenFleet is a privacy-minimal FastAPI ledger for a small AI-usage community. The
official collector sends daily token counters and minimal version metadata only,
and the server schema rejects explicit prompt, response, path, repository, and
transcript fields. An enrolled malicious or custom client cannot be semantically
proven not to encode sensitive data inside an otherwise allowed label, so device
enrollment and revocation remain part of the privacy trust boundary.

The service supports SQLite by default and PostgreSQL through SQLAlchemy and
`psycopg`. Human dashboard access uses short-lived JWTs; collectors receive a
separate per-device credential that can only upload signed daily snapshots.

## Quick start

Run commands from `server/`:

`server/.env.example` is a tracked configuration inventory with deliberately
invalid placeholders. If your process supervisor loads env files, copy it to
the ignored `server/.env` and fill that private copy outside version control.
TokenFleet does not load `.env` automatically; inject database credentials,
`JWT_SECRET`, and any one-time bootstrap password through a secret manager.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt -c constraints.txt

export DATABASE_URL='sqlite:///./tokenfleet.db'
export JWT_SECRET='replace-with-at-least-32-random-bytes'

.venv/bin/alembic upgrade head
.venv/bin/python -m app.cli create-admin \
  --org-slug acme \
  --org-name 'Acme' \
  --email admin@example.com

.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
```

`create-admin` prompts without echo for the initial password. For non-interactive
bootstrap, inject `BOOTSTRAP_ADMIN_PASSWORD` only for that process and remove it
immediately afterward. There is intentionally no unauthenticated bootstrap HTTP
route.

`python -m app.cli init-db` is an idempotent alias for `alembic upgrade head`.
Do not use SQLAlchemy `create_all` for a deployed database.

### One-command local development

From the repository root:

```bash
./script/start_tokenfleet_dev.sh
```

The command creates an isolated SQLite database and virtual environment under
`${TMPDIR:-/tmp}/tokenfleet-dev`, applies migrations, creates a local-only
`dev-team` administrator when needed, mounts the repository Web app, and binds to
`127.0.0.1:4311`. It generates a new JWT signing secret in memory for every
process and never creates an `.env` file, so no real company secret is required.
The printed `admin@example.com` / `tokenfleet-local-dev-only` login is deliberately
fixed for loopback development only; do not expose this process to a network.
Restarting invalidates existing browser JWTs but preserves the local SQLite state.

Optional controls are `TOKENFLEET_DEV_STATE_DIR`, `TOKENFLEET_DEV_VENV`,
`TOKENFLEET_DEV_PORT`, `TOKENFLEET_DEV_ORG`, and
`TOKENFLEET_DEV_ADMIN_EMAIL`. Dependency installation is skipped only when
`TOKENFLEET_DEV_SKIP_INSTALL=1` and an already-installed
`TOKENFLEET_DEV_VENV` is supplied.

The startup path has a self-cleaning black-box verifier:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 script/verify_tokenfleet_dev_start.py
```

It uses a temporary database and port, verifies health/readiness, the SPA root,
unauthenticated `401`, login, and `/me`, then terminates the server and removes
the temporary state. Pass `--venv server/.venv` (or another installed server
environment) to skip dependency installation during repeated verification.

With the development server running from a fresh state, the browser boundary
checks are reproducible from a second terminal (Playwright/Chromium required):

```bash
export TOKENFLEET_LIVE_BASE_URL='http://127.0.0.1:4311'
export TOKENFLEET_E2E_ORG='dev-team'
export TOKENFLEET_E2E_ADMIN='admin@example.com'
export TOKENFLEET_E2E_PASSWORD='tokenfleet-local-dev-only'
export TOKENFLEET_E2E_CONFIRM_BASE_URL='http://127.0.0.1:4311'
export TOKENFLEET_ALLOW_MUTATING_E2E='YES'

# Run before seeding: empty ledger, one administrator, six routes at 390 px.
python3 script/verify_tokenfleet_empty_web.py

# Add randomized boundary data, then verify auth/offline and 390 px edge layouts.
python3 script/verify_tokenfleet_e2e.py --allow-write-test-data --edge-values
TOKENFLEET_VERIFY_EDGE_VALUES=1 python3 script/verify_tokenfleet_live_web.py
```

The E2E scripts create randomized development users/devices and change their
status. They must run only against a disposable test database, require both an
explicit write acknowledgement and an exact target-URL confirmation, and
suppress response/page bodies on failure so JWTs, enrollment tokens, and device
secrets cannot enter logs. Delete the configured development state directory
when that disposable run is no longer needed.

For PostgreSQL:

```bash
export DATABASE_URL='postgresql+psycopg://tokenfleet:password@db/tokenfleet'
.venv/bin/alembic upgrade head
```

The checked-in `constraints.txt` records the dependency set used for verification
on Python 3.14. `requirements.txt` retains compatible ranges; production builds
should install with the constraints file.

## Configuration

All settings are environment variables:

| Variable | Default | Notes |
| --- | --- | --- |
| `ENVIRONMENT` | `development` | Deployment label; it never weakens credential validation. |
| `DATABASE_URL` | `sqlite:///./tokenfleet.db` | Supports `postgresql+psycopg://...`. |
| `WEB_ROOT` | sibling repository `web/` | Empty string disables Web mounting; nonexistent path is ignored. |
| `JWT_SECRET` | invalid tracked placeholder | Every environment rejects the placeholder and values shorter than 32 UTF-8 bytes. The local development script generates a per-process random value. |
| `JWT_ISSUER` | `tokenfleet` | Verified on every human request. |
| `JWT_AUDIENCE` | `tokenfleet-api` | Verified on every human request. |
| `JWT_TTL_SECONDS` | `3600` | Human token lifetime. |
| `LOGIN_RATE_LIMIT_ATTEMPTS` | `10` | Per organization/account process-local login window; changing IP does not reset it. |
| `LOGIN_RATE_LIMIT_IP_ATTEMPTS` | `50` | Independent per-client-IP window to resist email rotation. |
| `LOGIN_RATE_LIMIT_WINDOW_SECONDS` | `60` | Returns `429` and `Retry-After` when full. |
| `LOGIN_RATE_LIMIT_MAX_KEYS` | `10000` | Hard cap for in-memory limiter buckets. |
| `TRUSTED_PROXY_CIDRS` | empty | Comma-separated CIDRs/addresses of trusted ingress proxies. Empty ignores forwarding headers and keys per-IP limits from the direct TCP peer. |
| `TRUSTED_PROXY_HOPS` | `0` | Exact trusted proxy hop count (1–8). Must be 0 when no proxy CIDR is configured. |
| `PUBLIC_ORG_SLUG` | empty | The one organization projected by anonymous public APIs. Empty or unknown fails closed with `404`; clients cannot select another tenant. |
| `PUBLIC_RATE_LIMIT_ATTEMPTS` | `30` | Anonymous public reads allowed per client IP in the process-local window. |
| `PUBLIC_RATE_LIMIT_WINDOW_SECONDS` | `60` | Public read sliding-window duration. |
| `PUBLIC_RATE_LIMIT_MAX_KEYS` | `10000` | Hard cap for anonymous limiter buckets. |
| `PUBLIC_MAX_SCAN_ROWS` | `250000` | Hard cap on exact visible candidate rows for one public period, checked before tool/model filters; broader requests return `503` with `public_projection_scan_limit_exceeded`. |
| `PUBLIC_CACHE_TTL_SECONDS` | `15` | Shared/browser and process-local public projection TTL; constrained to 1–300 seconds. |
| `PUBLIC_CACHE_MAX_ENTRIES` | `1024` | Process-local bounded LRU entry count. |
| `USAGE_RATE_LIMIT_DEVICE_ATTEMPTS` | `12` | Authenticated usage requests allowed per device in the database-shared window. |
| `USAGE_RATE_LIMIT_ORG_ATTEMPTS` | `600` | Authenticated usage requests allowed across an organization in that window. |
| `USAGE_RATE_LIMIT_WINDOW_SECONDS` | `60` | Usage window; must not exceed nonce retention. |
| `USAGE_MAX_ROWS_PER_DEVICE` | `100000` | Persistent natural-key rows per device, including hidden tombstones. |
| `USAGE_MAX_ROWS_PER_ORG` | `2000000` | Persistent natural-key rows across an organization; must be at least the device quota. |
| `HMAC_MAX_CLOCK_SKEW_SECONDS` | `300` | Device timestamp tolerance. |
| `NONCE_RETENTION_SECONDS` | `600` | Must cover both twice the clock-skew window and the usage rate-limit window. |
| `PBKDF2_ITERATIONS` | `600000` | Human password hashing work factor. |
| `BOOTSTRAP_ADMIN_PASSWORD` | unset | CLI-only transient bootstrap input. |

The in-process account login limiter is always active. Without an explicit
trusted-proxy configuration, per-IP login and public-read limits use the direct
TCP peer and ignore caller-supplied forwarding headers. Behind a reverse proxy,
configure both `TRUSTED_PROXY_CIDRS` and `TRUSTED_PROXY_HOPS`; otherwise every
caller will legitimately appear to be the proxy and share its bucket. Trusted
requests select the client from `X-Forwarded-For` at the configured hop, and
production HSTS may use the matching trusted `X-Forwarded-Proto`. A missing or
invalid trusted chain is rejected with `400`, rather than bypassing limits or
joining a global unresolved bucket. Run the application behind a TCP proxy
connection: Unix-domain-socket peers do not expose an IP that this CIDR trust
model can verify. Configure Uvicorn's own proxy allow-list to the same ingress
CIDRs and prevent direct public access to the application socket.

These in-process login and public-read limiters are defense in depth for a single
instance. They cannot observe attempts handled by another worker or host, and the
application cannot reliably infer its deployment topology. **Production release
gate:** run exactly one application process, or provide and verify a gateway,
Redis, or another shared limiter for both route classes before any multi-worker or
multi-instance rollout. Process-local `429` tests are not evidence that this
multi-instance gate is satisfied.

## Database lifecycle

The Alembic revisions create all tenant constraints, indexes, checks, the usage
tombstone marker column, and the `alembic_version` marker. SQLite connections
always enable `PRAGMA foreign_keys=ON`.

```bash
# Apply or re-apply safely
.venv/bin/alembic upgrade head

# Verify model metadata matches the migration head
.venv/bin/alembic check
```

Readiness queries columns from the migrated organizations, tombstones, public
member identity/visibility, and public-price gate. `/healthz` continues to report
process liveness when the database is unavailable; `/readyz` returns a generic
`503` for a missing, stale, or unreachable database.

## API surface

All API paths are under `/api/v1` except health checks. Known API routes are
registered before the optional SPA mount, and unknown `/api/*` paths return JSON
404 instead of `index.html`.

### Human authentication and organization

- `POST /api/v1/auth/token` (alias `/api/v1/auth/login`)
  - request: `{org_slug, email, password}`
  - response: `{access_token, token_type, expires_in}`
- `GET /api/v1/me`
  - response: `{id, org_id, email, display_name, role, is_active}`
- `GET /api/v1/organization/settings` (alias `/api/v1/organization`)
- `PATCH /api/v1/organization/settings` (alias `/api/v1/organization`, admin)
  - optional fields: `{name, default_timezone, retention_days}`; at least one
  - response includes `ledger_version` and
    `retention_enforcement="external_scheduler_required"`

JWT identity, organization, and role are never trusted from request bodies. Each
request re-reads the user from the database, so disabling a member takes effect
immediately.

### Members and devices

- `GET /api/v1/users` (alias `/api/v1/admin/users`, admin)
- `GET /api/v1/users/{user_id}` (admin sees organization; member sees self)
- `POST /api/v1/users` (alias `/api/v1/admin/users`, admin)
  - creates administrator login accounts only; `role=admin` is required
    explicitly, while an omitted role or `role=member` is rejected with `422`
  - existing login-capable legacy members remain readable and may still log in,
    but this route cannot create more of them
- `PATCH /api/v1/users/{user_id}` with any of
  `{is_active, display_name, public_profile_enabled}` (admin)
  - same-organization only; an administrator cannot disable their own account
  - disabling immediately rejects existing JWTs and all owned device uploads
  - re-enabling restores access for credentials that have not otherwise expired
  - historical usage and devices are retained; password reset is out of scope
- `POST /api/v1/admin/participants` (admin)
  - request: `{display_name, public_profile_enabled, expires_in_minutes}`;
    visibility is a required explicit boolean and expiry defaults to 60 minutes,
    with a maximum of 1,440 minutes
  - transactionally creates a non-login member plus one enrollment token;
    response is `{participant, enrollment_token, expires_at}` and never trusts a
    request Host to construct a join URL
  - participant `email` and `password_hash` are genuinely `NULL`; no placeholder
    address or shared password is created
- `POST /api/v1/enrollment-tokens` (admin)
  - request: `{user_id, expires_in_minutes}`
  - response: `{enrollment_token, expires_at}`; plaintext is returned once
- `POST /api/v1/devices/enroll` (one-time token)
  - request:
    `{enrollment_token, device_public_id, platform, app_version, collector_version}`
  - response:
    `{device_id, device_public_id, device_secret, signing_key_derivation}`
- `GET /api/v1/devices`
  - admin sees the organization; member sees owned devices only
- `PATCH /api/v1/devices/{device_id}` with `{is_active}`
- `POST /api/v1/devices/{device_id}/disable`

`device_id` is the server UUID used in `X-Device-ID`. `device_public_id` is only a
stable display/enrollment identifier and is unique inside its organization.
Members may disable their own devices; only an admin may re-enable one. Device
responses distinguish `last_seen_at` (valid HMAC) from
`last_successful_sync_at` (committed ledger sync).

Re-enrolling the same organization, `device_public_id`, and member reuses the
existing device row and `device_id`, rotates the signing key, refreshes registered
versions, and re-enables the device. The old secret stops authenticating
immediately; historical usage remains attached to the stable device and is not
counted twice. If that `device_public_id` already belongs to another member in the
organization, enrollment returns `409` and never transfers or alters the device.

Enrollment tokens are stored as SHA-256 hashes and claimed with one conditional
`UPDATE ... RETURNING`, so concurrent enrollment has one winner. The raw device
secret is never stored. The database stores the derived signing key described
below.

Only active `member` rows may receive or exchange enrollment tokens. Disabling a
participant blocks enrollment and also turns off public visibility. Re-enabling
the member does not silently republish history; an administrator must explicitly
enable the public profile again.

### Signed usage upload

`POST /api/v1/usage/daily` accepts no query string or content encoding and is
limited to 2 MiB while ASGI chunks are read, before JSON parsing. Headers:

```text
X-Device-ID: <server device_id>
X-Timestamp: <decimal Unix seconds>
X-Nonce: <16..128 URL-safe characters; UUID recommended>
X-Signature: <lowercase HMAC-SHA256 hex>
```

Canonical bytes have no trailing newline:

```text
timestamp + "\n" + nonce + "\n" + method.upper() + "\n" + path + "\n" + sha256(raw_body).hexdigest()
```

The signing key and signature are:

```text
signing_key = SHA256(UTF8("TokenFleet-HMAC-v1:\n") + UTF8(device_secret))
signature   = HMAC-SHA256(signing_key, UTF8(canonical)).hexdigest()
```

The fixed path is `/api/v1/usage/daily`; the body hash covers exact bytes,
including whitespace. A successfully authenticated nonce is consumed even if
schema validation later fails. A retry must use a new nonce; daily upsert makes
the data operation idempotent.

After HMAC verification, PostgreSQL takes organization then device row locks and
checks device and organization request counts against the retained nonce ledger.
This shared sliding window applies across workers and instances using the same
database. A full window returns `429` with `Retry-After` before inserting the
request nonce. SQLite keeps the same API contract for local development but does
not provide PostgreSQL's row-lock concurrency semantics. With the defaults, the
retention boundary plus ten complete windows bounds a continuously saturated
device to about 132 nonce rows and an organization to about 6,600 after cleanup.

Request shape:

```json
{
  "schema_version": 1,
  "collector_version": "0.2.0",
  "generated_at": "2026-08-09T01:30:00Z",
  "buckets": [
    {
      "date": "2026-08-09",
      "timezone": "Asia/Shanghai",
      "tool": "Codex",
      "model": "gpt-5",
      "source": "local",
      "input_tokens": 120,
      "output_tokens": 80,
      "cache_read_tokens": 1000,
      "cache_write_tokens": 50,
      "completeness": "exact",
      "deleted": false
    }
  ]
}
```

`source` defaults to `local`. Unknown fields are rejected at both levels; the
official client does not send content-bearing fields. `tool`, `model`, and
`source` reject Unicode control, format, surrogate, and line-separator
characters. Token fields are strict non-negative integers, the whole batch
commits atomically, and the maximum is 2,000 buckets. `deleted` is an optional
strict boolean defaulting to `false`; `true` requires `completeness="exact"` and
all four token counters to be zero. Response:

```json
{"created": 1, "updated": 0, "unchanged": 0, "ledger_version": 1}
```

The natural key is:

```text
org / user / device / date / timezone / tool / model / source
```

`completeness` is overwriteable and is not part of the key. Stored quality is
monotonic in the order `fallback_estimate < legacy_marginal < exact`: a higher
quality snapshot upgrades the row even when it arrives with an older
`generated_at`, while a lower quality snapshot is ignored and cannot advance the
stored timestamp. Within the same quality, older snapshots are ignored and equal
timestamps with different contents return `409`. Overlapping batches use a
stable lock order.

A tombstone is stored as a hidden version on that same natural-key row, including
when no visible row currently exists. It never appears in dashboard rows, totals,
cost totals, or timezone warnings. Persisting the first marker, advancing a
marker, deleting a visible row, or resurrecting it counts as `updated`; a marker
is never `created`. At equal `generated_at`, a tombstone wins deterministically.
Only an exact active snapshot with a strictly newer `generated_at` may clear the
marker; older/equal active snapshots and newer estimates are `unchanged`. A
deleted priced row retains its frozen price-version reference so a valid later
resurrection does not silently reprice history.

In an ingest response, `created` means a natural key was first inserted;
`updated` means an accepted same/higher-quality snapshot changed persisted
counters, completeness, collector/schema metadata, frozen cost state, or the
hidden deletion version; and `unchanged` covers duplicates, stale snapshots,
quality downgrades, and writes outside retention. Only `created` or `updated`
advances the organization ledger version.

The persistent device and organization row quotas count every natural-key row,
including hidden tombstones. Existing-key updates, idempotent reports, and
turning an existing row into a tombstone remain valid at the limit; only a new
natural key consumes capacity. Ingestion holds organization then device locks,
checks capacity and inserts in one transaction, so concurrent PostgreSQL writers
cannot pass the hard limit. A report that would exceed capacity returns `422`
with `detail.code="usage_row_quota_exceeded"` and `detail.scope` set to
`device` or `organization`; the entire report is rolled back and does not change
usage, ledger version, or `last_successful_sync_at`. The defaults support roughly
five years at 54 distinct daily dimensions per device and about twenty devices
at that maximum; normal retention keeps substantially less history.

### Pricing and dashboards

- `GET /api/v1/pricing` (alias `/api/v1/prices`, admin)
- `POST /api/v1/pricing` (alias `/api/v1/prices`, admin)
- `PATCH /api/v1/prices/{price_id}` with `{public_estimate}` (admin)
- `GET /api/v1/dashboard` (aliases `/api/v1/usage`,
  `/api/v1/dashboard/usage`)
  - filters: `start_date`, `end_date`, `user_id`, `device_id`, `tool`, `model`,
    `source`, `timezone`
  - omitted dates default to the latest 30 calendar days ending on "today" in
    the authenticated user's organization timezone; explicit dates are unchanged
  - maximum range: 366 days; maximum result: 5,000 daily rows
  - members are forcibly scoped to self; admins are scoped to their organization

The dashboard returns daily rows, four atomic counters, derived `total_tokens`,
cost fields, totals by currency, unpriced count, `organization_timezone`,
`mixed_timezones`, and a warning when local-date buckets cannot be compared
losslessly.

Prices are append-only versions selected by effective date. Existing priced
history keeps its price version when a collector overwrites counters. Cost is
derived only for `completeness="exact"`; `legacy_marginal` and
`fallback_estimate` remain explicitly unpriced. Currency totals are never mixed.
Cost uses all four fields and `ROUND_HALF_UP` under an explicit safe Decimal
precision; every schema-valid price/token combination either succeeds or returns
contract `422`, and overflow beyond signed 64-bit microcurrency never reaches the
database as a `500`.

`POST /prices` requires an explicit `public_estimate` boolean. The default after
migration is false for every existing price version. A public projection reads a
frozen `cost_microunits` value only when its exact bucket points to a price version
that an administrator explicitly marked as a public estimate; private negotiated
or invoice rates therefore produce `cost=null`, `unpriced=true`, and an exact
public status without exposing the underlying row count. Public responses never
expose the underlying rates or device/date/tool/model/source bucket cardinality.

### Anonymous community leaderboard

- `GET /api/v1/public/leaderboard`
- `GET /api/v1/public/members/{public_id}`
- query contract: `period=today|yesterday|3d|7d|30d|90d|all`,
  `metric=tokens|norm|cost`, and optional exact `tool`/`model`; leaderboard
  `limit` is 1–100

Anonymous reads are a read-only projection of the single `PUBLIC_ORG_SLUG` ledger.
They never provide enrollment or upload authority. Only active members with the
explicit visibility flag are projected, and only `completeness="exact"`,
non-tombstoned daily buckets are included. Device disable stops new uploads but
does not erase already accepted member history.

The stable normalization contract is `norm_tokens = input_tokens +
output_tokens`; `total_tokens` is all four token classes. Token counts and cost
microunits are emitted as decimal strings so JavaScript does not lose valid
BigInt-scale values. The leaderboard also returns up to 100 independently derived
`available_tools` and `available_models`. Member detail contains only public ID,
nickname, exact rank under the same filters (or null for no matching usage or an
incomparable cost), aggregate counters/cost state, tool/model distributions, and
daily trend. The hard scan budget applies to the unfiltered public candidate
scope before tool/model filters or label discovery. If that scope is too large,
the request fails closed; callers must choose a shorter period rather than using
a rare label to force a full historical scan. Public responses never return
email, organization slug,
internal user/device IDs, device details, IP, hourly data, city, sessions, or
messages. Hidden, disabled, missing, malformed, and cross-tenant profile IDs share
the same `404` contract.

Token and cost aggregation is executed with SQL `GROUP BY` over members and, for
detail pages, tool/model/date dimensions. SQLite uses a connection-local exact
integer aggregate and PostgreSQL uses `NUMERIC`, so neither backend falls back to
64-bit-overflowing `SUM(bigint)` or materializes every matching ledger row in the
application. Successful anonymous responses use a short public cache. Its key
contains organization, resolved date range/period, metric, filters, public
ledger version, and profile identity where applicable; visibility, nickname,
timezone, price-publication, usage, and retention changes advance that version.
Client/server error responses remain `no-store`.

Daily dates are the collector's local dates in the supplied IANA timezone.
Version 1 does not claim it can re-bucket a daily aggregate into another timezone.
Lossless arbitrary-timezone regrouping requires a future UTC hourly ledger.

## Retention

`retention_days` is a policy value. Enforcement is an operator-scheduled CLI job,
not an internal background scheduler:

```bash
# Auditable preview; never deletes
.venv/bin/python -m app.cli purge-retention

# Enforce each organization's cutoff
.venv/bin/python -m app.cli purge-retention --apply
```

The JSON result records each organization, exclusive cutoff, matched rows, and
deleted rows. A deletion advances that organization's `ledger_version`. Configure
the apply command in an external scheduler and retain its output. Until that is
done, the API deliberately reports
`external_scheduler_required` rather than implying automatic deletion.

Ingest independently enforces the same exclusive cutoff using calendar today in
the organization's configured IANA timezone: buckets with `date < cutoff` are
processed as `unchanged` without writing either an active row or marker, while a
bucket exactly on the cutoff remains eligible. Therefore a force sync cannot
recreate history after the purge job physically removes an old row/marker.

## Privacy and operational security

- Official TokenFleet clients send aggregate counters and minimal version
  metadata only; the upload schema has no prompt, response, code, path, project,
  repository, or transcript field and rejects unknown fields.
- Schema validation cannot prove the semantics of text supplied by a malicious
  or modified enrolled client. Treat device enrollment, signing credentials,
  disable controls, and label review as a trust boundary rather than claiming
  absolute content non-collection for arbitrary clients.
- Validation errors strip rejected input, so passwords, enrollment tokens, and
  signed request bodies are not reflected to clients or proxy logs.
- Static, API, and handled error responses carry a same-origin CSP, deny framing,
  disable MIME sniffing, minimize referrers and browser permissions, and add HSTS
  when `ENVIRONMENT=production` is served over HTTPS.
- Login, participant/enrollment, and device-secret responses carry
  `Cache-Control: no-store`. Successful anonymous projections use the configured
  short public TTL; handled public errors remain `no-store`.
- Device credentials have upload permission only and cannot read dashboards.
- Cross-tenant foreign keys and application filters bind users, devices, prices,
  and usage to one organization.
- Logs and tracing must redact `Authorization`, enrollment tokens, device secrets,
  signatures, and raw bodies. Do not enable body logging at the proxy.
- The stored `signing_key` is sufficient to forge a device signature even though
  it cannot recover `device_secret`. Encrypt the database and backups, restrict
  database access, rotate/disable devices on compromise, and plan an Ed25519
  protocol upgrade if the server must hold only non-signing public material.
- Backups, restore drills, database encryption, centralized audit events, shared
  login rate limiting, and self-service deletion are deployment concerns not
  implemented by this service. Dashboard JSON provides scoped usage export;
  retention deletion is the only built-in deletion workflow.

## Tests

```bash
PYTHONDONTWRITEBYTECODE=1 \
  .venv/bin/pytest -p no:cacheprovider -q
```

The suite covers tenant isolation, RBAC, enrollment concurrency, derived-secret
storage, HMAC golden vector/tampering/expiry/replay, request-size enforcement,
disabled devices, strict schemas, atomic/idempotent overwrite, stale and equal
timestamp handling, multiple devices, timezone/range filters, versioned pricing,
non-exact/unpriced behavior, cost overflow, SQLite foreign keys, readiness,
login throttling and missing-account password work, Unicode label controls,
security headers, hidden tombstone ordering/resurrection/cost filtering,
organization settings, ingest and purge retention semantics, and SPA/API route
precedence. Public-community coverage additionally locks non-login participant
creation, one-time/expiry bounds, explicit visibility and public-price gates,
exact-only projection, all periods, organization-calendar day boundaries,
tool/model discovery, stable sorting, decimal-string extremes, explicit unpriced
state without row-count disclosure, cross-currency refusal, scan/rate limits,
enumeration resistance, tenant isolation, and safe migration downgrade refusal
when participant data exists.

The repository includes the PostgreSQL driver and PostgreSQL-specific atomic
upsert path. The real PostgreSQL release smoke is opt-in so the normal SQLite
suite remains self-contained:

```bash
TEST_POSTGRES_URL='postgresql+psycopg://user:password@host/postgres' \
  PYTHONDONTWRITEBYTECODE=1 \
  .venv/bin/pytest -p no:cacheprovider -q tests/test_postgres_smoke.py
```

`TEST_POSTGRES_URL` must point to a PostgreSQL management database whose role may
create and drop databases. The test creates a random temporary database, migrates
it from empty, verifies two real backend connections racing on one usage natural
key, races one enrollment token, verifies stable-device re-enrollment, exercises
public participant/cost projection, performs upgrade/downgrade safety checks, and
drops the temporary database in fixture teardown. It never logs the URL,
enrollment token, or device secret. Without the variable, these tests report
`skipped`.

Make this smoke a required production CI/release gate. The SQLite suite alone does
not substitute for PostgreSQL MVCC and driver verification.
