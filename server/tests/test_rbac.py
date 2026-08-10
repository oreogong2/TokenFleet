from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select

from app.models import DailyUsage, User
from app.schemas import UserCreate


def test_member_cannot_use_admin_routes(harness) -> None:
    response = harness.client.post(
        "/api/v1/admin/users",
        headers=harness.auth("a_member"),
        json={
            "email": "new@alpha.example.com",
            "password": "a-long-enough-password",
            "role": "admin",
        },
    )
    assert response.status_code == 403
    response = harness.client.post(
        "/api/v1/prices",
        headers=harness.auth("a_member"),
        json={
            "tool": "Codex",
            "model": "gpt-5",
            "currency": "USD",
            "public_estimate": False,
            "input_per_million": "1",
            "output_per_million": "2",
            "cache_read_per_million": "0.1",
            "cache_write_per_million": "1.25",
            "effective_from": "2026-01-01",
        },
    )
    assert response.status_code == 403
    assert harness.client.get(
        "/api/v1/users", headers=harness.auth("a_member")
    ).status_code == 403
    assert harness.client.get(
        "/api/v1/pricing", headers=harness.auth("a_member")
    ).status_code == 403
    response = harness.client.post(
        "/api/v1/enrollment-tokens",
        headers=harness.auth("a_member"),
        json={"user_id": harness.users["a_member"].id, "expires_in_minutes": 60},
    )
    assert response.status_code == 403


def test_admin_login_user_creation_rejects_members_and_requires_admin(harness) -> None:
    create_schema = UserCreate.model_json_schema()
    assert create_schema["properties"]["role"]["const"] == "admin"
    assert "role" in create_schema["required"]

    for path, email in (
        ("/api/v1/admin/users", "blocked-member@alpha.example.com"),
        ("/api/v1/users", "blocked-member-alias@alpha.example.com"),
    ):
        rejected = harness.client.post(
            path,
            headers=harness.auth("a_admin"),
            json={
                "email": email,
                "password": "a-long-enough-password",
                "role": "member",
            },
        )
        assert rejected.status_code == 422

    omitted_role = harness.client.post(
        "/api/v1/admin/users",
        headers=harness.auth("a_admin"),
        json={
            "email": "ambiguous-login@alpha.example.com",
            "password": "a-long-enough-password",
        },
    )
    assert omitted_role.status_code == 422

    created = harness.client.post(
        "/api/v1/admin/users",
        headers=harness.auth("a_admin"),
        json={
            "email": "second-admin@alpha.example.com",
            "password": "a-long-enough-password",
            "display_name": "Second Admin",
            "role": "admin",
        },
    )
    assert created.status_code == 201
    assert created.json()["role"] == "admin"
    assert created.json()["can_login"] is True
    assert harness.client.post(
        "/api/v1/auth/token",
        json={
            "org_slug": "alpha",
            "email": "second-admin@alpha.example.com",
            "password": "a-long-enough-password",
        },
    ).status_code == 200

    with harness.session_factory() as session:
        assert (
            session.query(User)
            .filter(
                User.email.in_(
                    (
                        "blocked-member@alpha.example.com",
                        "blocked-member-alias@alpha.example.com",
                        "ambiguous-login@alpha.example.com",
                    )
                )
            )
            .count()
            == 0
        )


def test_tenant_isolation_for_dashboard_devices_and_enrollment(harness) -> None:
    device_a = harness.enroll(admin_name="a_admin", user_name="a_member")
    device_b = harness.enroll(admin_name="b_admin", user_name="b_member")
    assert harness.signed_post(device_a, harness.usage_payload()).status_code == 200
    assert harness.signed_post(device_b, harness.usage_payload()).status_code == 200

    admin_a = harness.client.get(
        "/api/v1/dashboard/usage", headers=harness.auth("a_admin")
    ).json()
    assert {row["device_id"] for row in admin_a["rows"]} == {device_a.id}
    admin_b = harness.client.get(
        "/api/v1/dashboard/usage", headers=harness.auth("b_admin")
    ).json()
    assert {row["device_id"] for row in admin_b["rows"]} == {device_b.id}

    foreign_filter = harness.client.get(
        "/api/v1/dashboard/usage",
        headers=harness.auth("a_admin"),
        params={"user_id": harness.users["b_member"].id},
    )
    assert foreign_filter.status_code == 200
    assert foreign_filter.json()["rows"] == []

    foreign_disable = harness.client.post(
        f"/api/v1/devices/{device_b.id}/disable", headers=harness.auth("a_admin")
    )
    assert foreign_disable.status_code == 404
    invitation_for_foreign_user = harness.client.post(
        "/api/v1/enrollment-tokens",
        headers=harness.auth("a_admin"),
        json={"user_id": harness.users["b_member"].id, "expires_in_minutes": 60},
    )
    assert invitation_for_foreign_user.status_code == 404


def test_member_can_only_query_self_and_own_devices(harness) -> None:
    own = harness.enroll(admin_name="a_admin", user_name="a_member")
    other = harness.enroll(admin_name="a_admin", user_name="a_other")
    assert harness.signed_post(own, harness.usage_payload()).status_code == 200
    assert harness.signed_post(other, harness.usage_payload()).status_code == 200

    forbidden = harness.client.get(
        "/api/v1/dashboard/usage",
        headers=harness.auth("a_member"),
        params={"user_id": harness.users["a_other"].id},
    )
    assert forbidden.status_code == 403
    own_devices = harness.client.get(
        "/api/v1/devices", headers=harness.auth("a_member")
    )
    assert own_devices.status_code == 200
    assert {item["id"] for item in own_devices.json()} == {own.id}

    cannot_disable_other = harness.client.post(
        f"/api/v1/devices/{other.id}/disable", headers=harness.auth("a_member")
    )
    assert cannot_disable_other.status_code == 404


def test_admin_user_list_is_tenant_scoped_and_user_detail_is_not_enumerable(harness) -> None:
    listed = harness.client.get("/api/v1/users", headers=harness.auth("a_admin"))
    assert listed.status_code == 200
    assert {item["org_id"] for item in listed.json()} == {
        harness.users["a_admin"].org_id
    }
    foreign = harness.client.get(
        f"/api/v1/users/{harness.users['b_member'].id}",
        headers=harness.auth("a_admin"),
    )
    assert foreign.status_code == 404


def test_admin_can_disable_and_reenable_member_without_deleting_history(harness) -> None:
    device = harness.enroll(admin_name="a_admin", user_name="a_member")
    assert harness.signed_post(device, harness.usage_payload()).status_code == 200

    disabled = harness.client.patch(
        f"/api/v1/users/{harness.users['a_member'].id}",
        headers=harness.auth("a_admin"),
        json={"is_active": False},
    )
    assert disabled.status_code == 200
    assert disabled.json()["is_active"] is False

    # The already-issued human JWT and every device credential stop working
    # immediately, while the historical ledger remains available to admins.
    assert harness.client.get(
        "/api/v1/me", headers=harness.auth("a_member")
    ).status_code == 401
    assert harness.signed_post(device, harness.usage_payload()).status_code == 403
    with harness.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(DailyUsage)) == 1
    history = harness.client.get(
        "/api/v1/dashboard", headers=harness.auth("a_admin")
    )
    assert history.status_code == 200
    assert len(history.json()["rows"]) == 1

    enabled = harness.client.patch(
        f"/api/v1/users/{harness.users['a_member'].id}",
        headers=harness.auth("a_admin"),
        json={"is_active": True},
    )
    assert enabled.status_code == 200
    assert enabled.json()["is_active"] is True
    assert harness.client.get(
        "/api/v1/me", headers=harness.auth("a_member")
    ).status_code == 200
    restarted_payload = harness.usage_payload(
        generated_at=(datetime.now(timezone.utc) + timedelta(seconds=1))
        .isoformat()
        .replace("+00:00", "Z")
    )
    assert harness.signed_post(device, restarted_payload).status_code == 200


def test_user_status_patch_enforces_role_tenant_and_self_protection(harness) -> None:
    member_forbidden = harness.client.patch(
        f"/api/v1/users/{harness.users['a_other'].id}",
        headers=harness.auth("a_member"),
        json={"is_active": False},
    )
    assert member_forbidden.status_code == 403

    cross_tenant = harness.client.patch(
        f"/api/v1/users/{harness.users['b_member'].id}",
        headers=harness.auth("a_admin"),
        json={"is_active": False},
    )
    assert cross_tenant.status_code == 404

    self_disable = harness.client.patch(
        f"/api/v1/users/{harness.users['a_admin'].id}",
        headers=harness.auth("a_admin"),
        json={"is_active": False},
    )
    assert self_disable.status_code == 409
    assert harness.client.get(
        "/api/v1/me", headers=harness.auth("a_admin")
    ).status_code == 200


def test_user_status_patch_is_strict_and_requires_a_field(harness) -> None:
    path = f"/api/v1/users/{harness.users['a_member'].id}"
    assert harness.client.patch(
        path, headers=harness.auth("a_admin"), json={}
    ).status_code == 422
    assert harness.client.patch(
        path, headers=harness.auth("a_admin"), json={"is_active": "false"}
    ).status_code == 422
    assert harness.client.patch(
        path,
        headers=harness.auth("a_admin"),
        json={"is_active": False, "password": "not-accepted"},
    ).status_code == 422
