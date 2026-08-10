from __future__ import annotations

import json
import os
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

# ``app.main`` builds the ASGI application at import time. Production and
# development now both reject the tracked placeholder, so the test process must
# provide its own non-production signing key before importing that module.
os.environ.setdefault(
    "JWT_SECRET", "tokenfleet-pytest-process-secret-with-at-least-32-bytes"
)

from app.config import Settings
from app.database import Base, build_engine
from app.main import create_app
from app.models import Device, Organization, User, UserRole
from app.security import hash_password, sign_device_request

PASSWORD = "correct-horse-battery-staple"


@dataclass(slots=True)
class EnrolledDevice:
    id: str
    public_id: str
    secret: str
    user_id: str


class Harness:
    def __init__(self, client: TestClient, app, users: dict[str, User]) -> None:
        self.client = client
        self.app = app
        self.users = users
        self.tokens = {name: self._login(user) for name, user in users.items()}

    @property
    def session_factory(self):
        return self.app.state.session_factory

    def _login(self, user: User) -> str:
        with self.session_factory() as session:
            organization = session.scalar(
                select(Organization).where(Organization.id == user.org_id)
            )
            assert organization is not None
            response = self.client.post(
                "/api/v1/auth/token",
                json={
                    "org_slug": organization.slug,
                    "email": user.email,
                    "password": PASSWORD,
                },
            )
        assert response.status_code == 200, response.text
        return response.json()["access_token"]

    def auth(self, user_name: str) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.tokens[user_name]}"}

    def enroll(
        self,
        *,
        admin_name: str,
        user_name: str,
        public_id: str | None = None,
        expires_in_minutes: int = 60,
    ) -> EnrolledDevice:
        user = self.users[user_name]
        invitation = self.client.post(
            "/api/v1/enrollment-tokens",
            headers=self.auth(admin_name),
            json={"user_id": user.id, "expires_in_minutes": expires_in_minutes},
        )
        assert invitation.status_code == 201, invitation.text
        public_id = public_id or str(uuid.uuid4())
        response = self.client.post(
            "/api/v1/devices/enroll",
            json={
                "enrollment_token": invitation.json()["enrollment_token"],
                "device_public_id": public_id,
                "platform": "macos",
                "app_version": "0.2.0",
                "collector_version": "0.2.0",
            },
        )
        assert response.status_code == 201, response.text
        result = response.json()
        assert result["device_public_id"] == public_id
        return EnrolledDevice(
            id=result["device_id"],
            public_id=public_id,
            secret=result["device_secret"],
            user_id=user.id,
        )

    def usage_payload(
        self,
        *,
        buckets: list[dict[str, Any]] | None = None,
        generated_at: str | None = None,
        collector_version: str = "0.2.0",
    ) -> dict[str, Any]:
        today = datetime.now(timezone.utc).date().isoformat()
        return {
            "schema_version": 1,
            "collector_version": collector_version,
            "generated_at": generated_at
            or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "buckets": buckets
            or [
                {
                    "date": today,
                    "timezone": "Asia/Shanghai",
                    "tool": "Codex",
                    "model": "gpt-5",
                    "source": "local",
                    "input_tokens": 120,
                    "output_tokens": 80,
                    "cache_read_tokens": 1000,
                    "cache_write_tokens": 50,
                    "completeness": "exact",
                }
            ],
        }

    def signed_post(
        self,
        device: EnrolledDevice,
        payload: dict[str, Any],
        *,
        timestamp: int | None = None,
        nonce: str | None = None,
        secret: str | None = None,
        path: str = "/api/v1/usage/daily",
        body_override: bytes | None = None,
        signature_body: bytes | None = None,
    ):
        body = body_override or json.dumps(
            payload, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        signature_body = signature_body if signature_body is not None else body
        timestamp_text = str(timestamp if timestamp is not None else int(time.time()))
        nonce = nonce or str(uuid.uuid4())
        signature = sign_device_request(
            device_secret=secret or device.secret,
            timestamp_text=timestamp_text,
            nonce=nonce,
            method="POST",
            path=path,
            body=signature_body,
        )
        return self.client.post(
            path,
            content=body,
            headers={
                "Content-Type": "application/json",
                "X-Device-ID": device.id,
                "X-Timestamp": timestamp_text,
                "X-Nonce": nonce,
                "X-Signature": signature,
            },
        )


@pytest.fixture()
def harness(tmp_path: Path) -> Harness:
    database_path = tmp_path / "tokenfleet-test.db"
    engine = build_engine(f"sqlite:///{database_path}")
    Base.metadata.create_all(engine)
    settings = Settings(
        database_url=f"sqlite:///{database_path}",
        jwt_secret="test-only-secret-with-more-than-32-bytes",
        pbkdf2_iterations=1_000,
    )
    app = create_app(settings=settings, engine=engine)
    factory = app.state.session_factory
    with factory() as session:
        org_a = Organization(slug="alpha", name="Alpha")
        org_b = Organization(slug="bravo", name="Bravo")
        session.add_all([org_a, org_b])
        session.flush()
        users = {
            "a_admin": User(
                org_id=org_a.id,
                email="admin@alpha.example.com",
                password_hash=hash_password(PASSWORD, settings.pbkdf2_iterations),
                role=UserRole.ADMIN,
            ),
            "a_member": User(
                org_id=org_a.id,
                email="member@alpha.example.com",
                password_hash=hash_password(PASSWORD, settings.pbkdf2_iterations),
                role=UserRole.MEMBER,
            ),
            "a_other": User(
                org_id=org_a.id,
                email="other@alpha.example.com",
                password_hash=hash_password(PASSWORD, settings.pbkdf2_iterations),
                role=UserRole.MEMBER,
            ),
            "b_admin": User(
                org_id=org_b.id,
                email="admin@bravo.example.com",
                password_hash=hash_password(PASSWORD, settings.pbkdf2_iterations),
                role=UserRole.ADMIN,
            ),
            "b_member": User(
                org_id=org_b.id,
                email="member@bravo.example.com",
                password_hash=hash_password(PASSWORD, settings.pbkdf2_iterations),
                role=UserRole.MEMBER,
            ),
        }
        session.add_all(users.values())
        session.commit()
        for user in users.values():
            session.refresh(user)
        detached = {
            name: User(
                id=user.id,
                org_id=user.org_id,
                email=user.email,
                password_hash=user.password_hash,
                role=user.role,
                is_active=user.is_active,
            )
            for name, user in users.items()
        }
    with TestClient(app) as client:
        yield Harness(client, app, detached)
