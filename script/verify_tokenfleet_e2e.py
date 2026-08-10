#!/usr/bin/env python3
"""Black-box TokenFleet API verification using two devices for one participant.

The script creates only randomized test identities and never prints access tokens,
enrollment tokens, or device secrets.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import time
import uuid
from datetime import datetime, timezone
from urllib.parse import urlsplit

import httpx


SIGNING_KEY_PREFIX = b"TokenFleet-HMAC-v1:\n"
TOKEN_MAX = 9_000_000_000_000_000


def expect(response: httpx.Response, status: int) -> dict:
    if response.status_code != status:
        raise AssertionError(
            f"{response.request.method} {response.request.url.path}: "
            f"expected {status}, got {response.status_code}; response body suppressed"
        )
    if not response.content:
        return {}
    return response.json()


def login(client: httpx.Client, org_slug: str, email: str, password: str) -> str:
    payload = expect(
        client.post(
            "/api/v1/auth/token",
            json={"org_slug": org_slug, "email": email, "password": password},
        ),
        200,
    )
    assert payload["token_type"] == "bearer"
    return payload["access_token"]


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def enroll(
    client: httpx.Client,
    admin_token: str,
    user_id: str,
    *,
    device_public_id: str | None = None,
) -> tuple[str, str, str]:
    invitation = expect(
        client.post(
            "/api/v1/enrollment-tokens",
            headers=auth(admin_token),
            json={"user_id": user_id, "expires_in_minutes": 30},
        ),
        201,
    )
    return enroll_with_token(
        client,
        invitation["enrollment_token"],
        device_public_id=device_public_id,
    )


def enroll_with_token(
    client: httpx.Client,
    enrollment_token: str,
    *,
    device_public_id: str | None = None,
) -> tuple[str, str, str]:
    public_id = device_public_id or str(uuid.uuid4())
    enrolled = expect(
        client.post(
            "/api/v1/devices/enroll",
            json={
                "enrollment_token": enrollment_token,
                "device_public_id": public_id,
                "platform": "macos",
                "app_version": "0.2.0-e2e",
                "collector_version": "0.2.0-e2e",
            },
        ),
        201,
    )
    assert enrolled["device_public_id"] == public_id
    assert enrolled["signing_key_derivation"] == "sha256-tokenfleet-hmac-v1"
    return enrolled["device_id"], enrolled["device_secret"], public_id


def signed_upload(
    client: httpx.Client,
    device_id: str,
    device_secret: str,
    payload: dict,
    *,
    expected_status: int = 200,
) -> dict:
    body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    timestamp = str(int(time.time()))
    nonce = str(uuid.uuid4())
    path = "/api/v1/usage/daily"
    body_hash = hashlib.sha256(body).hexdigest()
    canonical = f"{timestamp}\n{nonce}\nPOST\n{path}\n{body_hash}".encode()
    signing_key = hashlib.sha256(
        SIGNING_KEY_PREFIX + device_secret.encode()
    ).digest()
    signature = hmac.new(signing_key, canonical, hashlib.sha256).hexdigest()
    return expect(
        client.post(
            path,
            content=body,
            headers={
                "Content-Type": "application/json",
                "X-Device-ID": device_id,
                "X-Timestamp": timestamp,
                "X-Nonce": nonce,
                "X-Signature": signature,
            },
        ),
        expected_status,
    )


def usage_payload(tool: str, model: str, multiplier: int = 1) -> dict:
    now = datetime.now(timezone.utc)
    return {
        "schema_version": 1,
        "collector_version": "0.2.0-e2e",
        "generated_at": now.isoformat().replace("+00:00", "Z"),
        "buckets": [
            {
                "date": now.date().isoformat(),
                "timezone": "Asia/Shanghai",
                "tool": tool,
                "model": model,
                "source": "local",
                "input_tokens": 100 * multiplier,
                "output_tokens": 50 * multiplier,
                "cache_read_tokens": 1_000 * multiplier,
                "cache_write_tokens": 25 * multiplier,
                "completeness": "exact",
            }
        ],
    }


def total_tokens(totals: dict) -> int:
    return sum(
        int(totals.get(key, 0))
        for key in (
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
        )
    )


def nested_keys(value: object) -> set[str]:
    if isinstance(value, dict):
        return set(value) | set().union(*(nested_keys(item) for item in value.values()))
    if isinstance(value, list):
        return set().union(*(nested_keys(item) for item in value))
    return set()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:4311")
    parser.add_argument(
        "--allow-write-test-data",
        action="store_true",
        help="required acknowledgement: this test creates and changes server data",
    )
    parser.add_argument("--org-slug", default=os.getenv("TOKENFLEET_E2E_ORG", "e2e-team"))
    parser.add_argument("--admin-email", default=os.getenv("TOKENFLEET_E2E_ADMIN", "admin@example.com"))
    parser.add_argument("--admin-password", default=os.getenv("TOKENFLEET_E2E_PASSWORD"))
    parser.add_argument(
        "--edge-values",
        action="store_true",
        help="also upload maximum counters with an exact 128-character model name",
    )
    args = parser.parse_args()
    normalized_base_url = args.base_url.rstrip("/")
    parsed_base_url = urlsplit(normalized_base_url)
    confirmed_base_url = os.getenv("TOKENFLEET_E2E_CONFIRM_BASE_URL", "").rstrip("/")
    if not args.allow_write_test_data or confirmed_base_url != normalized_base_url:
        raise SystemExit(
            "refusing to write test data: pass --allow-write-test-data and set "
            "TOKENFLEET_E2E_CONFIRM_BASE_URL to the exact disposable test URL"
        )
    if (
        parsed_base_url.scheme not in {"http", "https"}
        or not parsed_base_url.hostname
        or parsed_base_url.username
        or parsed_base_url.password
        or parsed_base_url.query
        or parsed_base_url.fragment
    ):
        raise SystemExit("base URL must be a plain HTTP(S) origin without credentials, query, or fragment")
    if not args.admin_password:
        raise SystemExit("set TOKENFLEET_E2E_PASSWORD; it is never printed")

    run_id = uuid.uuid4().hex[:10]
    codex_model = f"gpt-e2e-{run_id}"
    claude_model = f"claude-e2e-{run_id}"
    edge_model = (f"edge-model-{run_id}-" + "x" * 128)[:128]
    assert len(edge_model) == 128
    today = datetime.now(timezone.utc).date().isoformat()

    with httpx.Client(base_url=normalized_base_url, timeout=10) as client:
        assert expect(client.get("/healthz"), 200)["status"] == "ok"
        assert expect(client.get("/readyz"), 200)["status"] == "ready"
        admin_token = login(
            client, args.org_slug, args.admin_email, args.admin_password
        )
        admin_me = expect(client.get("/api/v1/me", headers=auth(admin_token)), 200)
        assert admin_me["role"] == "admin"

        # One bounded invitation batch must create exactly one public
        # participant and personal enrollment token without exposing internals.
        batch_created = expect(
            client.post(
                "/api/v1/admin/invitation-batches",
                headers=auth(admin_token),
                json={"capacity": 1, "expires_in_hours": 1},
            ),
            201,
        )
        batch_token = batch_created["invitation_token"]
        batch_claim = client.post(
            "/api/v1/public/invitation-batches/claim",
            json={
                "invitation_token": batch_token,
                "display_name": f"批次参赛者 {run_id}",
                "public_profile_enabled": True,
            },
        )
        batch_claim_body = expect(batch_claim, 201)
        assert batch_claim.headers["Cache-Control"] == "no-store"
        assert set(batch_claim_body) == {
            "nickname",
            "enrollment_token",
            "expires_at",
        }
        batch_device = enroll_with_token(
            client,
            batch_claim_body["enrollment_token"],
        )
        assert batch_device[0] and batch_device[1]
        unavailable = client.post(
            "/api/v1/public/invitation-batches/claim",
            json={
                "invitation_token": batch_token,
                "display_name": f"批次满额 {run_id}",
                "public_profile_enabled": True,
            },
        )
        assert unavailable.status_code == 409
        assert unavailable.json() == {"detail": "invitation batch unavailable"}
        listed_batches = expect(
            client.get(
                "/api/v1/admin/invitation-batches",
                headers=auth(admin_token),
            ),
            200,
        )
        assert all("invitation_token" not in item for item in listed_batches)
        assert batch_token not in json.dumps(listed_batches)

        # Login-account creation is admin-only in the community product. A
        # member payload must fail rather than silently creating a legacy login.
        expect(
            client.post(
                "/api/v1/users",
                headers=auth(admin_token),
                json={
                    "email": f"blocked-member-{run_id}@example.com",
                    "password": f"Member-{run_id}-safe-password",
                    "role": "member",
                },
            ),
            422,
        )
        private_participant = expect(
            client.post(
                "/api/v1/admin/participants",
                headers=auth(admin_token),
                json={
                    "display_name": f"E2E 参赛者 {run_id}",
                    "public_profile_enabled": False,
                    "expires_in_minutes": 30,
                },
            ),
            201,
        )
        member = private_participant["participant"]
        assert member["email"] is None
        assert member["can_login"] is False

        for tool, model in (("Codex", codex_model), ("Claude Code", claude_model)):
            expect(
                client.post(
                    "/api/v1/pricing",
                    headers=auth(admin_token),
                    json={
                        "tool": tool,
                        "model": model,
                        "currency": "USD",
                        "public_estimate": True,
                        "input_per_million": "1.25",
                        "output_per_million": "10",
                        "cache_read_per_million": "0.125",
                        "cache_write_per_million": "1.25",
                        "effective_from": today,
                    },
                ),
                201,
            )

        if args.edge_values:
            expect(
                client.post(
                    "/api/v1/pricing",
                    headers=auth(admin_token),
                    json={
                        "tool": "Boundary",
                        "model": edge_model,
                        "currency": "USD",
                        "public_estimate": False,
                        "input_per_million": "0",
                        "output_per_million": "0",
                        "cache_read_per_million": "0",
                        "cache_write_per_million": "0",
                        "effective_from": today,
                    },
                ),
                201,
            )

        public_participant = expect(
            client.post(
                "/api/v1/admin/participants",
                headers=auth(admin_token),
                json={
                    "display_name": f"公开参赛者 {run_id}",
                    "public_profile_enabled": True,
                    "expires_in_minutes": 30,
                },
            ),
            201,
        )
        public_user = public_participant["participant"]
        assert public_user["email"] is None
        assert public_user["can_login"] is False
        public_first_device = enroll_with_token(
            client,
            public_participant["enrollment_token"],
        )
        expect(
            client.post(
                "/api/v1/devices/enroll",
                json={
                    "enrollment_token": public_participant["enrollment_token"],
                    "device_public_id": str(uuid.uuid4()),
                    "platform": "macos",
                    "app_version": "0.2.0-e2e",
                    "collector_version": "0.2.0-e2e",
                },
            ),
            400,
        )
        public_second_device = enroll(client, admin_token, public_user["id"])
        public_first_payload = usage_payload("Codex", codex_model, 3)
        public_second_payload = usage_payload("Claude Code", claude_model, 4)
        assert signed_upload(
            client, *public_first_device[:2], public_first_payload
        )["created"] == 1
        assert signed_upload(
            client, *public_second_device[:2], public_second_payload
        )["created"] == 1

        public_board = expect(
            client.get(
                "/api/v1/public/leaderboard",
                params={"period": "all", "metric": "tokens"},
            ),
            200,
        )
        public_entry = next(
            item
            for item in public_board["entries"]
            if item["public_id"] == public_user["public_id"]
        )
        assert public_entry["totals"]["total_tokens"] == str(1_175 * 3 + 1_175 * 4)
        assert public_entry["totals"]["unpriced"] is False
        public_detail = expect(
            client.get(
                f"/api/v1/public/members/{public_user['public_id']}",
                params={"period": "all", "metric": "tokens"},
            ),
            200,
        )
        assert public_detail["rank"] == public_entry["rank"]
        assert {item["name"] for item in public_detail["tool_distribution"]} == {
            "Codex",
            "Claude Code",
        }
        forbidden_public_keys = {
            "email",
            "org_id",
            "org_slug",
            "user_id",
            "device_id",
            "device_public_id",
            "devices",
            "ip",
            "city",
            "sessions",
            "messages",
            "unpriced_rows",
        }
        assert not (nested_keys(public_board) & forbidden_public_keys)
        assert not (nested_keys(public_detail) & forbidden_public_keys)

        first_device = enroll_with_token(
            client,
            private_participant["enrollment_token"],
        )
        second_device = enroll(client, admin_token, member["id"])
        edge_device = enroll(client, admin_token, member["id"]) if args.edge_values else None
        first_payload = usage_payload("Codex", codex_model, 1)
        second_payload = usage_payload("Claude Code", claude_model, 2)
        assert signed_upload(client, *first_device[:2], first_payload)["created"] == 1
        assert signed_upload(client, *first_device[:2], first_payload)["unchanged"] == 1
        assert signed_upload(client, *second_device[:2], second_payload)["created"] == 1
        if edge_device is not None:
            edge_payload = usage_payload("Boundary", edge_model)
            edge_payload["buckets"][0].update(
                {
                    "input_tokens": TOKEN_MAX,
                    "output_tokens": TOKEN_MAX,
                    "cache_read_tokens": TOKEN_MAX,
                    "cache_write_tokens": TOKEN_MAX,
                }
            )
            assert signed_upload(client, *edge_device[:2], edge_payload)["created"] == 1

        dashboard = expect(
            client.get(
                "/api/v1/dashboard",
                headers=auth(admin_token),
                params={"user_id": member["id"], "start_date": today, "end_date": today},
            ),
            200,
        )
        expected_rows = 3 if args.edge_values else 2
        expected_tokens = 1_175 + 2_350 + (TOKEN_MAX * 4 if args.edge_values else 0)
        assert len(dashboard["rows"]) == expected_rows
        assert total_tokens(dashboard["totals"]) == expected_tokens
        assert dashboard["totals"]["unpriced_rows"] == 0

        # Re-enrolling one installation must rotate its secret while preserving
        # its device identity and natural keys. Otherwise a reconnect would make
        # the same local history appear as a second device and double the total.
        rotated_first_device = enroll(
            client,
            admin_token,
            member["id"],
            device_public_id=first_device[2],
        )
        assert rotated_first_device[0] == first_device[0]
        assert rotated_first_device[1] != first_device[1]
        signed_upload(
            client,
            *first_device[:2],
            first_payload,
            expected_status=401,
        )
        assert signed_upload(
            client,
            *rotated_first_device[:2],
            first_payload,
        )["unchanged"] == 1
        dashboard_after_reenrollment = expect(
            client.get(
                "/api/v1/dashboard",
                headers=auth(admin_token),
                params={"user_id": member["id"], "start_date": today, "end_date": today},
            ),
            200,
        )
        assert len(dashboard_after_reenrollment["rows"]) == expected_rows
        assert dashboard_after_reenrollment["totals"] == dashboard["totals"]

        devices = expect(client.get("/api/v1/devices", headers=auth(admin_token)), 200)
        own_device_ids = {item["id"] for item in devices if item["user_id"] == member["id"]}
        expected_device_ids = {rotated_first_device[0], second_device[0]}
        if edge_device is not None:
            expected_device_ids.add(edge_device[0])
        assert own_device_ids == expected_device_ids
        expect(
            client.patch(
                f"/api/v1/devices/{rotated_first_device[0]}",
                headers=auth(admin_token),
                json={"is_active": False},
            ),
            200,
        )
        signed_upload(
            client,
            *rotated_first_device[:2],
            first_payload,
            expected_status=403,
        )

    print(
        json.dumps(
            {
                "status": "ok",
                "member_count_created": 1,
                "devices_enrolled": 3 if args.edge_values else 2,
                "usage_rows": 3 if args.edge_values else 2,
                "maximum_token_fields": 4 if args.edge_values else 0,
                "model_name_length": 128 if args.edge_values else 0,
                "idempotent_replay": "unchanged",
                "reenrollment_device_id": "reused",
                "history_double_count": "absent",
                "disabled_device": "rejected",
                "secrets_printed": 0,
                "public_participants_created": 1,
                "public_devices_aggregated": 2,
                "public_private_keys_exposed": 0,
                "self_service_batch_claimed": 1,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
