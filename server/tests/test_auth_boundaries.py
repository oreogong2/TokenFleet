from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timedelta, timezone

import jwt
import pytest

import app.api as api_module
from app.security import create_access_token


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _claims(harness) -> dict[str, object]:
    settings = harness.app.state.settings
    user = harness.users["a_member"]
    now = datetime.now(timezone.utc)
    return {
        "sub": user.id,
        "org": user.org_id,
        "role": user.role.value,
        "iss": settings.jwt_issuer,
        "aud": settings.jwt_audience,
        "iat": now,
        "exp": now + timedelta(minutes=5),
        "jti": "auth-boundary-test",
    }


def test_login_401_and_permission_403_contract(harness) -> None:
    valid = harness.client.get("/api/v1/me", headers=harness.auth("a_member"))
    assert valid.status_code == 200

    wrong_password = harness.client.post(
        "/api/v1/auth/token",
        json={
            "org_slug": "alpha",
            "email": harness.users["a_member"].email,
            "password": "wrong-password-value",
        },
    )
    assert wrong_password.status_code == 401
    assert wrong_password.json() == {"detail": "invalid credentials"}
    assert harness.users["a_member"].email not in wrong_password.text

    missing = harness.client.get("/api/v1/me")
    assert missing.status_code == 401
    assert missing.headers["WWW-Authenticate"] == "Bearer"
    malformed = harness.client.get(
        "/api/v1/me", headers=_bearer("not-a-jwt")
    )
    assert malformed.status_code == 401
    assert malformed.headers["WWW-Authenticate"] == "Bearer"

    forbidden = harness.client.get(
        "/api/v1/users", headers=harness.auth("a_member")
    )
    assert forbidden.status_code == 403


def test_unknown_login_still_executes_configured_password_hash_check(
    harness, monkeypatch
) -> None:
    calls: list[tuple[str, str]] = []
    real_verify_password = api_module.verify_password

    def recording_verify_password(password: str, encoded: str) -> bool:
        calls.append((password, encoded))
        return real_verify_password(password, encoded)

    monkeypatch.setattr(api_module, "verify_password", recording_verify_password)
    response = harness.client.post(
        "/api/v1/auth/token",
        json={
            "org_slug": "alpha",
            "email": "missing@alpha.example.com",
            "password": "not-the-right-password",
        },
    )

    assert response.status_code == 401
    assert response.json() == {"detail": "invalid credentials"}
    assert len(calls) == 1
    supplied_password, checked_hash = calls[0]
    assert supplied_password == "not-the-right-password"
    algorithm, iterations, _salt, _digest = checked_hash.split("$", 3)
    assert algorithm == "pbkdf2_sha256"
    assert int(iterations) == harness.app.state.settings.pbkdf2_iterations


def test_expired_human_jwt_is_rejected(harness) -> None:
    expired_settings = replace(
        harness.app.state.settings,
        jwt_ttl_seconds=-1,
    )
    token = create_access_token(harness.users["a_member"], expired_settings)
    response = harness.client.get("/api/v1/me", headers=_bearer(token))
    assert response.status_code == 401
    assert response.json() == {"detail": "invalid or expired access token"}
    assert response.headers["WWW-Authenticate"] == "Bearer"


@pytest.mark.parametrize(
    "claim,value",
    [
        ("iss", "wrong-issuer"),
        ("aud", "wrong-audience"),
    ],
)
def test_wrong_jwt_issuer_or_audience_is_rejected(harness, claim, value) -> None:
    settings = harness.app.state.settings
    claims = _claims(harness)
    claims[claim] = value
    token = jwt.encode(claims, settings.jwt_secret, algorithm="HS256")
    assert harness.client.get(
        "/api/v1/me", headers=_bearer(token)
    ).status_code == 401


@pytest.mark.filterwarnings(
    "ignore:The HMAC key is .*:jwt.warnings.InsecureKeyLengthWarning"
)
def test_unapproved_jwt_algorithm_is_rejected(harness) -> None:
    settings = harness.app.state.settings
    token = jwt.encode(_claims(harness), settings.jwt_secret, algorithm="HS384")
    assert harness.client.get(
        "/api/v1/me", headers=_bearer(token)
    ).status_code == 401
