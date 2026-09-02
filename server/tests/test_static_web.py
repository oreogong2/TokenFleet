from __future__ import annotations

from fastapi.testclient import TestClient

from app.config import Settings
from app.database import Base, build_engine
from app.main import create_app


def _assert_security_headers(response) -> None:
    csp = response.headers["content-security-policy"]
    assert "default-src 'self'" in csp
    assert "frame-ancestors 'none'" in csp
    assert "script-src 'self'" in csp
    assert "style-src 'self' 'unsafe-inline'" in csp
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["referrer-policy"] == "no-referrer"
    assert "camera=()" in response.headers["permissions-policy"]
    assert response.headers["x-frame-options"] == "DENY"


def test_optional_same_origin_web_mount_keeps_api_routes_ahead_of_spa(
    tmp_path,
) -> None:
    web_root = tmp_path / "web"
    web_root.mkdir()
    (web_root / "index.html").write_text(
        "<!doctype html><title>TokenFleet test shell</title>", encoding="utf-8"
    )
    admin_root = web_root / "admin"
    admin_root.mkdir()
    (admin_root / "index.html").write_text(
        "<!doctype html><title>TokenFleet admin shell</title>", encoding="utf-8"
    )
    (web_root / "styles.css").write_text("body { color: black; }", encoding="utf-8")
    engine = build_engine(f"sqlite:///{tmp_path / 'static-web.db'}")
    Base.metadata.create_all(engine)
    app = create_app(
        settings=Settings(
            database_url=f"sqlite:///{tmp_path / 'static-web.db'}",
            web_root=str(web_root),
            jwt_secret="static-web-test-secret-with-at-least-32-bytes",
            pbkdf2_iterations=1_000,
        ),
        engine=engine,
    )
    with TestClient(app) as client:
        root = client.get("/")
        assert "TokenFleet test shell" in root.text
        assert root.headers["cache-control"] == "no-cache"
        _assert_security_headers(root)
        revalidated = client.get("/", headers={"if-none-match": root.headers["etag"]})
        assert revalidated.status_code == 304
        stylesheet = client.get("/styles.css")
        assert stylesheet.headers["content-type"].startswith("text/css")
        assert "cache-control" not in stylesheet.headers
        _assert_security_headers(stylesheet)
        spa_fallback = client.get("/people/member-id")
        assert "TokenFleet test shell" in spa_fallback.text
        assert spa_fallback.headers["cache-control"] == "no-cache"
        assert "x-robots-tag" not in spa_fallback.headers
        admin_redirect = client.get("/admin", follow_redirects=False)
        assert admin_redirect.status_code in {307, 308}
        assert admin_redirect.headers["x-robots-tag"] == "noindex, nofollow"
        admin = client.get("/admin/")
        assert "TokenFleet admin shell" in admin.text
        assert admin.headers["x-robots-tag"] == "noindex, nofollow"
        admin_fallback = client.get("/admin/not-a-real-page")
        assert admin_fallback.headers["x-robots-tag"] == "noindex, nofollow"
        unauthorized_api = client.get("/api/v1/me")
        assert unauthorized_api.status_code == 401
        assert unauthorized_api.headers["cache-control"] == "no-store"
        _assert_security_headers(unauthorized_api)
        unknown_api = client.get("/api/not-a-real-route")
        assert unknown_api.status_code == 404
        assert unknown_api.json() == {"detail": "API route not found"}
        _assert_security_headers(unknown_api)
        validation_error = client.post("/api/v1/auth/token", json={})
        assert validation_error.status_code == 422
        _assert_security_headers(validation_error)


def test_hsts_is_limited_to_production_https_responses(tmp_path) -> None:
    database_url = f"sqlite:///{tmp_path / 'production-headers.db'}"
    engine = build_engine(database_url)
    Base.metadata.create_all(engine)
    app = create_app(
        settings=Settings(
            environment=" \tPrOdUcTiOn\n",
            database_url=database_url,
            web_root="",
            jwt_secret="production-header-test-secret-32-bytes-minimum",
            pbkdf2_iterations=1_000,
        ),
        engine=engine,
    )

    with TestClient(app, base_url="https://testserver") as https_client:
        response = https_client.get("/api/not-a-real-route")
        assert response.status_code == 404
        _assert_security_headers(response)
        assert response.headers["strict-transport-security"] == (
            "max-age=31536000; includeSubDomains"
        )

    with TestClient(app, base_url="http://testserver") as http_client:
        response = http_client.get("/healthz")
        assert response.status_code == 200
        _assert_security_headers(response)
        assert "strict-transport-security" not in response.headers

        spoofed = http_client.get(
            "/healthz",
            headers={
                "X-Forwarded-For": "198.51.100.25",
                "X-Forwarded-Proto": "https",
            },
        )
        assert "strict-transport-security" not in spoofed.headers

    trusted_app = create_app(
        settings=Settings(
            environment="production",
            database_url=database_url,
            web_root="",
            jwt_secret="production-header-test-secret-32-bytes-minimum",
            pbkdf2_iterations=1_000,
            trusted_proxy_cidrs="10.0.0.0/8",
            trusted_proxy_hops=1,
        ),
        engine=engine,
    )
    with TestClient(
        trusted_app,
        base_url="http://testserver",
        client=("10.20.30.40", 50_000),
    ) as proxy_client:
        response = proxy_client.get(
            "/healthz",
            headers={
                "X-Forwarded-For": "198.51.100.25",
                "X-Forwarded-Proto": "https",
            },
        )
        assert response.headers["strict-transport-security"] == (
            "max-age=31536000; includeSubDomains"
        )

    # Uvicorn uses scope.client=None for Unix-domain sockets. A configured
    # proxy chain must fail closed without raising TypeError or trusting XFP.
    with TestClient(
        trusted_app,
        base_url="http://testserver",
        client=None,
    ) as uds_client:
        response = uds_client.get(
            "/healthz",
            headers={
                "X-Forwarded-For": "198.51.100.25",
                "X-Forwarded-Proto": "https",
            },
        )
        assert response.status_code == 200
        assert "strict-transport-security" not in response.headers
