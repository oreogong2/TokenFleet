#!/usr/bin/env python3
"""Reissue an existing member's code directly to the macOS clipboard.

Secrets and codes never become command arguments, stdout, or exception text.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import urllib.error
import urllib.request
from urllib.parse import urlsplit

DEFAULT_DIR = Path.home() / ".config" / "tokenfleet" / "member-reissue"
MAX_BYTES = 4096


class SafeError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def private_file(path: Path) -> str:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
                raise SafeError("本地配置必须由当前用户拥有，且权限为 0600")
            raw = stream.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise SafeError("本地配置格式不正确")
        return raw.decode("utf-8").strip()
    except SafeError:
        raise
    except (OSError, UnicodeError):
        raise SafeError("无法读取本地受保护配置") from None


def configuration(directory: Path) -> tuple[str, str]:
    try:
        directory_info = directory.lstat()
        if (not stat.S_ISDIR(directory_info.st_mode) or directory_info.st_uid != os.getuid()
                or stat.S_IMODE(directory_info.st_mode) != 0o700):
            raise SafeError("本地配置目录必须由当前用户拥有，且权限为 0700")
    except OSError:
        raise SafeError("无法读取本地受保护配置目录") from None
    # Refuse any config kept inside a Git checkout, including ignored files.
    result = subprocess.run(["git", "-C", str(directory), "rev-parse", "--is-inside-work-tree"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    if result.returncode == 0:
        raise SafeError("补发配置必须放在仓库外")
    credential = private_file(directory / "credential")
    if not re.fullmatch(r"tfreissue_[A-Za-z0-9_-]{43}", credential):
        raise SafeError("补发专用凭据格式不正确")
    try:
        metadata = json.loads(private_file(directory / "metadata.json"))
        origin = metadata["origin"]
        parsed = urlsplit(origin)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
                or parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.port
                or metadata["scope"] != "members:reissue-only"):
            raise ValueError()
    except (ValueError, KeyError, TypeError):
        raise SafeError("补发服务配置格式不正确") from None
    return origin.rstrip("/"), credential


def fetch_code(origin: str, credential: str, nickname: str) -> str:
    request = urllib.request.Request(origin + "/api/v1/enrollment-management/reissue",
        data=json.dumps({"display_name": nickname}, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + credential, "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            raw = response.read(MAX_BYTES + 1)
            if response.status != 201 or len(raw) > MAX_BYTES:
                raise SafeError("补发响应不符合预期，未复制；请核查服务状态")
            body = json.loads(raw)
            server_date = response.headers.get("Date")
            now = parsedate_to_datetime(server_date) if server_date else datetime.now(timezone.utc)
        if set(body) != {"enrollment_token", "expires_at"}:
            raise ValueError()
        code = body["enrollment_token"]
        # Device codes are opaque URL-safe tokens, not links or commands.
        if not isinstance(code, str) or not re.fullmatch(r"[A-Za-z0-9_-]{20,256}", code):
            raise ValueError()
        expiry = datetime.fromisoformat(body["expires_at"].replace("Z", "+00:00"))
        hours = (expiry - now).total_seconds() / 3600
        if not (23.9 <= hours <= 24.1 if server_date else 23 <= hours <= 25):
            raise ValueError()
        return code
    except urllib.error.HTTPError as error:
        messages = {401: "补发凭据已失效，请管理员更新", 403: "补发凭据没有此权限",
                    404: "没有找到该昵称的有效成员，请核对原昵称", 422: "昵称格式不正确"}
        raise SafeError(messages.get(error.code, "服务未完成补发，请核查后再试")) from None
    except SafeError:
        raise
    except (OSError, ValueError, TypeError, KeyError):
        raise SafeError("补发响应无法确认，未复制；请核查后再试") from None


def copy_code(code: str) -> None:
    result = subprocess.run(["/usr/bin/pbcopy"], input=code.encode("utf-8"),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if result.returncode:
        raise SafeError("设备码已生成，但复制失败；请检查剪贴板后重新补发")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="将已有成员的 24 小时设备码直接复制到 Mac 剪贴板")
    parser.add_argument("nickname", help="本人确认的原昵称")
    parser.add_argument("--config-dir", type=Path, default=DEFAULT_DIR)
    args = parser.parse_args(argv)
    try:
        if sys.platform != "darwin" or not Path("/usr/bin/pbcopy").is_file():
            raise SafeError("请在管理员的 Mac 上运行此工具")
        nickname = args.nickname.strip()
        if not nickname or len(nickname) > 128 or any(ord(c) < 32 or ord(c) == 127 for c in nickname):
            raise SafeError("昵称格式不正确")
        origin, credential = configuration(args.config_dir)
        copy_code(fetch_code(origin, credential, nickname))
        print("已复制，24 小时内有效")
        return 0
    except SafeError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print("本地补发未完成，请核查配置和剪贴板", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
