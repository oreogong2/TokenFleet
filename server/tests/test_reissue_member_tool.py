import importlib.util
from pathlib import Path
import secrets
import urllib.error
from datetime import datetime, timedelta, timezone
import json
import pytest

spec = importlib.util.spec_from_file_location("reissue_tool", Path(__file__).resolve().parents[2] / "script/reissue_member_code.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def test_private_files_reject_broad_permissions_and_symlinks(tmp_path):
    path = tmp_path / "credential"
    secret = "tfreissue_" + secrets.token_urlsafe(32)
    path.write_text(secret)
    path.chmod(0o600)
    assert tool.private_file(path) == secret
    path.chmod(0o644)
    with pytest.raises(tool.SafeError): tool.private_file(path)
    path.chmod(0o600)
    link = tmp_path / "link"
    link.symlink_to(path)
    with pytest.raises(tool.SafeError): tool.private_file(link)


def test_success_only_copies_code_and_prints_receipt(monkeypatch, capsys):
    credential, code = "tfreissue_" + secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    copied = []
    monkeypatch.setattr(tool.sys, "platform", "darwin")
    monkeypatch.setattr(tool.Path, "is_file", lambda _: True)
    monkeypatch.setattr(tool, "configuration", lambda _: ("https://community.example", credential))
    monkeypatch.setattr(tool, "fetch_code", lambda origin, token, nickname: code)
    monkeypatch.setattr(tool, "copy_code", copied.append)
    assert tool.main(["test member"]) == 0
    output = capsys.readouterr()
    assert copied == [code] and output.out == "已复制，24 小时内有效\n" and not output.err
    assert credential not in output.out and code not in output.out


def test_http_error_never_prints_raw_body_or_credential(monkeypatch):
    credential = "tfreissue_" + secrets.token_urlsafe(32)
    class Opener:
        def open(self, request, timeout):
            assert request.full_url.endswith("/api/v1/enrollment-management/reissue")
            assert json.loads(request.data) == {"display_name": "old member"}
            raise urllib.error.HTTPError(request.full_url, 401, credential, {}, None)
    monkeypatch.setattr(tool.urllib.request, "build_opener", lambda _: Opener())
    with pytest.raises(tool.SafeError) as error:
        tool.fetch_code("https://community.example", credential, "old member")
    assert credential not in str(error.value)
    assert tool.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.example") is None


@pytest.mark.parametrize("hours", [1, 48])
def test_wrong_expiry_is_rejected_without_copying(monkeypatch, hours):
    class Response:
        status = 201
        headers = {}
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self, limit):
            return json.dumps({"enrollment_token": secrets.token_urlsafe(32),
                "expires_at": (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat()}).encode()
    class Opener:
        def open(self, request, timeout): return Response()
    monkeypatch.setattr(tool.urllib.request, "build_opener", lambda _: Opener())
    with pytest.raises(tool.SafeError): tool.fetch_code("https://community.example", "unused", "member")


@pytest.mark.parametrize("origin", ["http://community.example", "https://user@community.example.test", "https://community.example:444", "https://community.example/path", "https://community.example/?foo=1", "https://community.example/#part"])
def test_configuration_rejects_unsafe_origins(tmp_path, origin):
    tmp_path.chmod(0o700)
    for name, value in {"credential": "tfreissue_" + secrets.token_urlsafe(32), "metadata.json": json.dumps({"origin": origin, "scope": "members:reissue-only"})}.items():
        path = tmp_path / name; path.write_text(value); path.chmod(0o600)
    with pytest.raises(tool.SafeError): tool.configuration(tmp_path)


def test_configuration_checks_directory_scope_and_git_location(tmp_path):
    tmp_path.chmod(0o700)
    credential = "tfreissue_" + secrets.token_urlsafe(32)
    metadata = {"origin": "https://community.example", "scope": "members:reissue-only"}
    for name, value in {"credential": credential, "metadata.json": json.dumps(metadata)}.items():
        path = tmp_path / name; path.write_text(value); path.chmod(0o600)
    assert tool.configuration(tmp_path) == (metadata["origin"], credential)
    tmp_path.chmod(0o755)
    with pytest.raises(tool.SafeError): tool.configuration(tmp_path)
    tmp_path.chmod(0o700)
    metadata["scope"] = "prices:missing-only"
    (tmp_path / "metadata.json").write_text(json.dumps(metadata))
    with pytest.raises(tool.SafeError): tool.configuration(tmp_path)
    metadata["scope"] = "members:reissue-only"
    (tmp_path / "metadata.json").write_text(json.dumps(metadata))
    tool.subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    with pytest.raises(tool.SafeError): tool.configuration(tmp_path)


def test_expiry_uses_https_server_clock(monkeypatch):
    from email.utils import format_datetime
    clock = datetime.now(timezone.utc) + timedelta(hours=2)
    code = secrets.token_urlsafe(32)
    class Response:
        status = 201
        headers = {"Date": format_datetime(clock, usegmt=True)}
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self, limit):
            return json.dumps({"enrollment_token": code, "expires_at": (clock + timedelta(hours=24)).isoformat()}).encode()
    class Opener:
        def open(self, request, timeout): return Response()
    monkeypatch.setattr(tool.urllib.request, "build_opener", lambda _: Opener())
    assert tool.fetch_code("https://community.example", "unused", "member") == code
