from datetime import datetime, timedelta, timezone
import uuid
import pytest
from sqlalchemy import select, func
from app.models import EnrollmentManagementCredential, EnrollmentToken, User, UserRole, utcnow

ROOT = "/api/v1/enrollment-management"


def issue(harness):
    response = harness.client.post(ROOT + "/credentials", headers=harness.auth("a_admin"), json={})
    assert response.status_code == 201 and response.headers["cache-control"] == "no-store"
    body = response.json()
    assert body["scope"] == "members:reissue-only"
    return body["id"], {"Authorization": "Bearer " + body["credential"]}, body["credential"]


def names(harness):
    with harness.session_factory() as session:
        for key in ("a_member", "a_other", "b_member"):
            session.get(User, harness.users[key].id).display_name = key
        session.commit()


def test_reissue_rotates_unused_codes_preserves_used_rows_and_member(harness):
    names(harness)
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    old = harness.client.post("/api/v1/enrollment-tokens", headers=harness.auth("a_admin"),
        json={"user_id": harness.users["a_member"].id})
    before = utcnow()
    old_expiry = datetime.fromisoformat(old.json()["expires_at"])
    assert timedelta(hours=23.99) < old_expiry - before < timedelta(hours=24.01)
    cid, headers, token = issue(harness)
    with harness.session_factory() as session:
        users_before = session.scalar(select(func.count()).select_from(User))
        used = session.scalar(select(EnrollmentToken).where(EnrollmentToken.used_at.is_not(None)))
        used_state = (used.id, used.used_at, used.expires_at)
        row = session.get(EnrollmentManagementCredential, cid)
        assert row.token_hash != token and len(row.token_hash) == 64
    response = harness.client.post(ROOT + "/reissue", headers=headers, json={"display_name": "a_member"})
    assert response.status_code == 201 and response.headers["cache-control"] == "no-store"
    expiry = datetime.fromisoformat(response.json()["expires_at"])
    assert timedelta(hours=23.99) < expiry - utcnow() < timedelta(hours=24.01)
    with harness.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(User)) == users_before
        rows = session.scalars(select(EnrollmentToken).where(EnrollmentToken.user_id == device.user_id)).all()
        live = [row for row in rows if row.used_at is None and row.expires_at.replace(tzinfo=timezone.utc) > utcnow()]
        assert len(live) == 1 and live[0].created_by_user_id == harness.users["a_admin"].id
        used = session.get(EnrollmentToken, used_state[0])
        assert (used.id, used.used_at, used.expires_at) == used_state
    # Code remains a normal single-use enrollment, bound to the original member.
    payload = {"enrollment_token": response.json()["enrollment_token"], "device_public_id": str(uuid.uuid4()),
               "platform": "windows", "app_version": "test", "collector_version": "test"}
    enrolled = harness.client.post("/api/v1/devices/enroll", json=payload)
    assert enrolled.status_code == 201
    assert harness.client.post("/api/v1/devices/enroll", json=payload).status_code != 201


def test_reissue_credential_cannot_escalate_or_cross_organizations(harness):
    names(harness)
    cid, headers, _ = issue(harness)
    for path in ("/api/v1/users", "/api/v1/devices", "/api/v1/prices", "/api/v1/dashboard/usage"):
        assert harness.client.get(path, headers=headers).status_code == 401
    for path, body in ((ROOT + "/credentials", {}), ("/api/v1/price-management/credentials", {}),
        ("/api/v1/admin/participants", {"display_name": "new"}),
        ("/api/v1/enrollment-tokens", {"user_id": harness.users["a_member"].id}),
        ("/api/v1/admin/invitation-batches", {})):
        assert harness.client.post(path, headers=headers, json=body).status_code == 401
    for nickname in ("unknown", "b_member", "A_MEMBER"):
        assert harness.client.post(ROOT + "/reissue", headers=headers, json={"display_name": nickname}).status_code == 404
    for extra in ({"user_id": harness.users["b_member"].id}, {"expires_in_minutes": 60}, {"org_id": "other"}):
        assert harness.client.post(ROOT + "/reissue", headers=headers, json={"display_name": "a_member", **extra}).status_code == 422
    assert harness.client.post(ROOT + "/reissue", headers=harness.auth("a_admin"), json={"display_name": "a_member"}).status_code == 401
    assert harness.client.post(ROOT + "/credentials", headers=harness.auth("a_member"), json={}).status_code == 403
    assert harness.client.delete(ROOT + "/credentials/" + cid, headers=harness.auth("b_admin")).status_code == 404
    assert harness.client.delete(ROOT + "/credentials/" + cid, headers=headers).status_code == 401
    assert harness.client.delete(ROOT + "/credentials/" + cid, headers=harness.auth("a_admin")).status_code == 204
    assert harness.client.post(ROOT + "/reissue", headers=headers, json={"display_name": "a_member"}).status_code == 401


@pytest.mark.parametrize("condition", ["expired", "owner_disabled", "owner_demoted", "member_disabled", "member_admin"])
def test_reissue_respects_current_authority(harness, condition):
    names(harness)
    cid, headers, _ = issue(harness)
    with harness.session_factory() as session:
        if condition == "expired":
            session.get(EnrollmentManagementCredential, cid).expires_at = utcnow() - timedelta(seconds=1)
        elif condition.startswith("owner"):
            owner = session.get(User, harness.users["a_admin"].id)
            if condition == "owner_disabled": owner.is_active = False
            else: owner.role = UserRole.MEMBER
        else:
            member = session.get(User, harness.users["a_member"].id)
            if condition == "member_disabled": member.is_active = False
            else: member.role = UserRole.ADMIN
        session.commit()
    status = 404 if condition.startswith("member") else 401
    assert harness.client.post(ROOT + "/reissue", headers=headers, json={"display_name": "a_member"}).status_code == status
