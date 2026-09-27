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
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self, limit):
            return json.dumps({"enrollment_token": secrets.token_urlsafe(32),
                "expires_at": (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat()}).encode()
    class Opener:
        def open(self, request, timeout): return Response()
    monkeypatch.setattr(tool.urllib.request, "build_opener", lambda _: Opener())
    with pytest.raises(tool.SafeError): tool.fetch_code("https://community.example", "unused", "member")
