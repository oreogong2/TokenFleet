from __future__ import annotations

import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.models import DailyUsage, Device, EnrollmentToken, User, utcnow
from app.security import opaque_token_hash


def _invite(harness, *, user_name: str = "a_member") -> str:
    response = harness.client.post(
        "/api/v1/enrollment-tokens",
        headers=harness.auth("a_admin"),
        json={
            "user_id": harness.users[user_name].id,
            "expires_in_minutes": 60,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()["enrollment_token"]


def _enrollment_body(token: str, public_id: str) -> dict[str, str]:
    return {
        "enrollment_token": token,
        "device_public_id": public_id,
        "platform": "macos",
        "app_version": "0.2.0",
        "collector_version": "0.2.0",
    }


def test_enrollment_token_is_one_time_and_raw_value_is_not_stored(harness) -> None:
    token = _invite(harness)
    first = harness.client.post(
        "/api/v1/devices/enroll",
        json=_enrollment_body(token, str(uuid.uuid4())),
    )
    assert first.status_code == 201, first.text
    second = harness.client.post(
        "/api/v1/devices/enroll",
        json=_enrollment_body(token, str(uuid.uuid4())),
    )
    assert second.status_code == 400

    with harness.session_factory() as session:
        stored = session.scalar(
            select(EnrollmentToken).where(
                EnrollmentToken.token_hash == opaque_token_hash(token)
            )
        )
        assert stored is not None and stored.used_at is not None
        assert stored.token_hash != token
        assert token not in repr(stored.__dict__)


def test_concurrent_enrollment_consumes_token_exactly_once_on_sqlite(harness) -> None:
    token = _invite(harness)
    barrier = threading.Barrier(2)

    def attempt() -> int:
        with TestClient(harness.app) as client:
            barrier.wait(timeout=5)
            response = client.post(
                "/api/v1/devices/enroll",
                json=_enrollment_body(token, str(uuid.uuid4())),
            )
            return response.status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        statuses = sorted(executor.map(lambda _index: attempt(), range(2)))
    assert statuses == [201, 400]
    with harness.session_factory() as session:
        count = session.scalar(
            select(func.count()).select_from(Device).where(
                Device.user_id == harness.users["a_member"].id
            )
        )
        assert count == 1


def test_expired_or_inactive_member_enrollment_is_rejected(harness) -> None:
    expired_token = _invite(harness)
    with harness.session_factory() as session:
        stored = session.scalar(
            select(EnrollmentToken).where(
                EnrollmentToken.token_hash == opaque_token_hash(expired_token)
            )
        )
        assert stored is not None
        stored.expires_at = utcnow() - timedelta(seconds=1)
        session.commit()
    expired = harness.client.post(
        "/api/v1/devices/enroll",
        json=_enrollment_body(expired_token, str(uuid.uuid4())),
    )
    assert expired.status_code == 400

    inactive_token = _invite(harness)
    with harness.session_factory() as session:
        user = session.scalar(
            select(User).where(User.id == harness.users["a_member"].id)
        )
        assert user is not None
        user.is_active = False
        session.commit()
    inactive = harness.client.post(
        "/api/v1/devices/enroll",
        json=_enrollment_body(inactive_token, str(uuid.uuid4())),
    )
    assert inactive.status_code == 403


def test_same_member_reenrollment_reuses_identity_rotates_secret_and_history(
    harness,
) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    assert harness.signed_post(device, harness.usage_payload()).status_code == 200
    assert harness.client.post(
        f"/api/v1/devices/{device.id}/disable",
        headers=harness.auth("a_admin"),
    ).status_code == 200

    old_secret = device.secret
    token = _invite(harness)
    reenrolled = harness.client.post(
        "/api/v1/devices/enroll",
        json={
            **_enrollment_body(token, device.public_id),
            "app_version": "0.3.0",
            "collector_version": "0.3.0",
        },
    )
    assert reenrolled.status_code == 201, reenrolled.text
    response = reenrolled.json()
    assert response["device_id"] == device.id
    assert response["device_secret"] != old_secret

    generated_at = (
        datetime.now(timezone.utc) + timedelta(seconds=1)
    ).isoformat().replace("+00:00", "Z")
    payload = harness.usage_payload(
        generated_at=generated_at,
        collector_version="0.3.0",
    )
    rejected_old_secret = harness.signed_post(
        device, payload, secret=old_secret
    )
    assert rejected_old_secret.status_code == 401

    device.secret = response["device_secret"]
    accepted_new_secret = harness.signed_post(device, payload)
    assert accepted_new_secret.status_code == 200, accepted_new_secret.text

    listed = harness.client.get(
        "/api/v1/devices", headers=harness.auth("a_admin")
    )
    assert listed.status_code == 200
    assert len(listed.json()) == 1
    assert listed.json()[0]["id"] == device.id
    assert listed.json()[0]["is_active"] is True
    assert listed.json()[0]["app_version"] == "0.3.0"

    dashboard = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    ).json()
    assert len(dashboard["rows"]) == 1
    assert dashboard["totals"]["input_tokens"] == 120
    assert dashboard["totals"]["total_tokens"] == 1250
    with harness.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(Device)) == 1
        assert session.scalar(select(func.count()).select_from(DailyUsage)) == 1


def test_reenrollment_cannot_transfer_device_to_another_member(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    with harness.session_factory() as session:
        stored = session.scalar(select(Device).where(Device.id == device.id))
        assert stored is not None
        original_signing_key = stored.signing_key

    token = _invite(harness, user_name="a_other")
    conflict = harness.client.post(
        "/api/v1/devices/enroll",
        json=_enrollment_body(token, device.public_id),
    )
    assert conflict.status_code == 409
    assert "device_secret" not in conflict.text

    with harness.session_factory() as session:
        stored = session.scalar(select(Device).where(Device.id == device.id))
        assert stored is not None
        assert stored.user_id == harness.users["a_member"].id
        assert stored.signing_key == original_signing_key

    # The original owner and credential remain valid after the rejected transfer.
    assert harness.signed_post(device, harness.usage_payload()).status_code == 200
