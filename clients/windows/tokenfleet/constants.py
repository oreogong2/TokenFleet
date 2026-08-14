from __future__ import annotations

APP_VERSION = "0.1.1"
COLLECTOR_VERSION = "0.2.0-windows.1"
SCHEMA_VERSION = 1

ENROLLMENT_PATH = "/api/v1/devices/enroll"
DAILY_USAGE_PATH = "/api/v1/usage/daily"
PUBLIC_RANK_PATH = "/rank"
SIGNING_KEY_CONTEXT = b"TokenFleet-HMAC-v1:\n"
SIGNING_KEY_DERIVATION = "sha256-tokenfleet-hmac-v1"

ACCOUNTING_TIMEZONE = "Asia/Shanghai"
MAX_BUCKETS_PER_REQUEST = 2_000
MAX_UPLOAD_BODY_BYTES = 1_900_000
MAX_RESPONSE_BYTES = 1_048_576
MAX_TOKEN_VALUE = 9_000_000_000_000_000
MAX_RELEVANT_LINE_BYTES = 1_048_576
MAX_SOURCE_FILES = 50_000

TASK_NAME = "TokenFleet Community Sync"
RUN_KEY_PATH = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_VALUE_NAME = "TokenFleet Community Sync"
STARTUP_LOOP_MUTEX_NAME = r"Local\TokenFleetCommunitySyncLoop"
SYNC_INTERVAL_SECONDS = 6 * 60 * 60
SYNC_RETRY_SECONDS = 5 * 60
DPAPI_FILE_MAGIC = b"TFDPAPI1\x00"
DPAPI_ENTROPY = b"TokenFleet Windows TeamSync credential v1"
