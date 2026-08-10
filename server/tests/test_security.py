from __future__ import annotations

import json
import time
import uuid

from sqlalchemy import select

from app.models import Device
from app.security import body_sha256, derive_device_signing_key, sign_device_request


def test_hmac_golden_vector() -> None:
    secret = "test-device-secret-00000000000000000000"
    body = (
        b'{"schema_version":1,"collector_version":"0.2.0","generated_at":'
        b'"2026-08-09T01:30:00Z","buckets":[{"date":"2026-08-09",'
        b'"timezone":"Asia/Shanghai","tool":"Codex","model":"gpt-5",'
        b'"source":"local","input_tokens":120,"output_tokens":80,'
        b'"cache_read_tokens":1000,"cache_write_tokens":50,"completeness":"exact"}]}'
    )
    assert body_sha256(body) == "3bfc3e7d12a7bbfdb5493d5914fbc656074527e523006653d55c071aa0019b38"
    assert (
        derive_device_signing_key(secret).hex()
        == "74b86767b4085ccab9074108032b32ecf45f7c1e23addb8ae0d169e31bf4a446"
    )
    assert sign_device_request(
        device_secret=secret,
        timestamp_text="1786240000",
        nonce="123e4567-e89b-12d3-a456-426614174000",
        method="POST",
        path="/api/v1/usage/daily",
        body=body,
    ) == "b6f61ec4a68f4693d1baa5115584db1cde917fbc80c376e8d6166af25334bb42"


def test_secret_is_returned_once_and_only_derived_key_is_stored(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    with harness.session_factory() as session:
        stored = session.scalar(select(Device).where(Device.id == device.id))
        assert stored is not None
        assert stored.signing_key != device.secret
        assert stored.signing_key == derive_device_signing_key(device.secret).hex()
        assert device.secret not in repr(stored.__dict__)


def test_hmac_tamper_expiry_and_replay(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    payload = harness.usage_payload()

    original_body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    tampered_payload = dict(payload)
    tampered_payload["collector_version"] = "tampered"
    tampered_body = json.dumps(
        tampered_payload, sort_keys=True, separators=(",", ":")
    ).encode()
    response = harness.signed_post(
        device,
        tampered_payload,
        body_override=tampered_body,
        signature_body=original_body,
    )
    assert response.status_code == 401

    # Keep a multi-second margin outside the allowed window. A one-second
    # margin is flaky because request handling can cross the next wall-clock
    # second before the server evaluates the signature timestamp.
    outside_window = harness.app.state.settings.hmac_max_clock_skew_seconds + 5
    now = int(time.time())
    expired = harness.signed_post(device, payload, timestamp=now - outside_window)
    assert expired.status_code == 401
    future = harness.signed_post(device, payload, timestamp=now + outside_window)
    assert future.status_code == 401

    nonce = str(uuid.uuid4())
    first = harness.signed_post(device, payload, nonce=nonce)
    assert first.status_code == 200, first.text
    replay = harness.signed_post(device, payload, nonce=nonce)
    assert replay.status_code == 409


def test_disabled_device_is_rejected(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    disabled = harness.client.post(
        f"/api/v1/devices/{device.id}/disable", headers=harness.auth("a_admin")
    )
    assert disabled.status_code == 200
    response = harness.signed_post(device, harness.usage_payload())
    assert response.status_code == 403


def test_signed_endpoint_rejects_query_and_content_encoding(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    payload = harness.usage_payload()
    body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    timestamp = str(int(time.time()))
    nonce = str(uuid.uuid4())
    signature = sign_device_request(
        device_secret=device.secret,
        timestamp_text=timestamp,
        nonce=nonce,
        method="POST",
        path="/api/v1/usage/daily",
        body=body,
    )
    headers = {
        "Content-Type": "application/json",
        "X-Device-ID": device.id,
        "X-Timestamp": timestamp,
        "X-Nonce": nonce,
        "X-Signature": signature,
    }
    assert harness.client.post("/api/v1/usage/daily?x=1", content=body, headers=headers).status_code == 400
    headers["X-Nonce"] = str(uuid.uuid4())
    headers["Content-Encoding"] = "gzip"
    assert harness.client.post("/api/v1/usage/daily", content=body, headers=headers).status_code == 400
