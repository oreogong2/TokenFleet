from __future__ import annotations

import argparse
import getpass
import json
import os
import subprocess
import sys
import webbrowser
from pathlib import Path

from tokenfleet.client import TokenFleetClient
from tokenfleet.constants import APP_VERSION, TASK_NAME
from tokenfleet.credential import CredentialError, CredentialStore
from tokenfleet.installation import (
    CommunityInstallationConfigStore,
    InstallationConfigError,
)
from tokenfleet.paths import ClientPaths, default_source_home
from tokenfleet.protocol import ProtocolError
from tokenfleet.scheduler import SchedulerError, is_registered, register, unregister
from tokenfleet.sensitive_clipboard import SensitiveClipboardError, copy_sensitive_text
from tokenfleet.state import StateError, StateStore


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tokenfleet",
        description="TokenFleet Windows 社群 Token 用量客户端",
    )
    parser.add_argument("--version", action="version", version=f"TokenFleet {APP_VERSION}")
    commands = parser.add_subparsers(dest="command", required=True)

    connect = commands.add_parser("connect", help="使用一次性码连接当前设备")
    connect.add_argument(
        "--no-initial-sync",
        action="store_true",
        help=argparse.SUPPRESS,
    )

    preview = commands.add_parser("preview", help="只在本机预览将上传的日聚合")
    preview.add_argument("--json", action="store_true", dest="as_json")

    sync = commands.add_parser("sync", help="立即同步一次")
    sync.add_argument("--json", action="store_true", dest="as_json")
    sync.add_argument("--quiet", action="store_true", help=argparse.SUPPRESS)

    status = commands.add_parser("status", help="查看连接和自动同步状态")
    status.add_argument("--json", action="store_true", dest="as_json")

    commands.add_parser("open-rank", help="打开公开排行榜")
    commands.add_parser(
        "new-device-code",
        help="为同一成员的另一台设备生成一次性码并复制到安全剪贴板",
    )

    uninstall = commands.add_parser("uninstall", help="卸载本机客户端和同步凭据")
    uninstall.add_argument("--yes", action="store_true", help="确认移除本机数据")
    return parser


def _client(paths: ClientPaths) -> TokenFleetClient:
    config = CommunityInstallationConfigStore(
        paths.community_config, paths.community_digest
    ).load()
    return TokenFleetClient(
        credential_store=CredentialStore(paths.credential),
        state_store=StateStore(paths.state),
        source_home=default_source_home(),
        community_origin=config.community_server,
    )


def _preview_value(result) -> dict[str, object]:  # type: ignore[no-untyped-def]
    token_fields = (
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
    )
    return {
        "bucket_count": len(result.buckets),
        "total_tokens": result.total_tokens,
        "token_breakdown": {
            field: sum(bucket[field] for bucket in result.buckets)
            for field in token_fields
        },
        "dates": sorted({bucket["date"] for bucket in result.buckets}),
        "tools": sorted({bucket["tool"] for bucket in result.buckets}),
        "models": sorted({bucket["model"] for bucket in result.buckets}),
        "source_files": result.diagnostics.source_files,
        "exact_records": result.diagnostics.exact_records,
        "skipped_records": result.diagnostics.skipped_records,
        "cc_switch": result.diagnostics.cc_switch_status,
        "privacy": "daily aggregates only; no prompts, responses, code, paths, or account IDs",
    }


def _print_value(value: dict[str, object], *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, ensure_ascii=False, sort_keys=True))
        return
    for key, item in value.items():
        print(f"{key}: {item}")


def _connect(args: argparse.Namespace, paths: ClientPaths) -> int:
    client = _client(paths)
    code = getpass.getpass("一次性接入码（输入不会显示）: ")
    try:
        credential = client.connect(enrollment_token=code)
    finally:
        code = ""  # do not retain the one-time code beyond enrollment
    schedule_warning: str | None = None
    try:
        register(Path(__file__))
    except SchedulerError:
        schedule_warning = "设备已连接，但自动同步任务创建失败；请运行 tokenfleet sync 重试。"
    print(f"设备已连接：{credential.device_public_id}")
    if schedule_warning:
        print(schedule_warning, file=sys.stderr)
        return 2
    if not args.no_initial_sync:
        summary = client.sync()
        print(f"首次同步完成：{summary.buckets} 个日聚合，{summary.total_tokens} Token")
    return 0


def _preview(args: argparse.Namespace, paths: ClientPaths) -> int:
    result = _client(paths).preview()
    _print_value(_preview_value(result), as_json=args.as_json)
    return 0


def _sync(args: argparse.Namespace, paths: ClientPaths) -> int:
    if not is_registered():
        register(Path(__file__))
    summary = _client(paths).sync()
    value = {
        "bucket_count": summary.buckets,
        "total_tokens": summary.total_tokens,
        "created": summary.created,
        "updated": summary.updated,
        "unchanged": summary.unchanged,
        "ledger_version": summary.ledger_version,
        "generated_at": summary.generated_at,
    }
    if not args.quiet:
        _print_value(value, as_json=args.as_json)
    return 0


def _status(args: argparse.Namespace, paths: ClientPaths) -> int:
    config = CommunityInstallationConfigStore(
        paths.community_config, paths.community_digest
    ).load()
    store = CredentialStore(paths.credential)
    connected = store.exists
    origin: str | None = None
    public_id: str | None = None
    if connected:
        credential = store.load()
        origin = credential.server_origin
        if origin != config.community_server:
            raise InstallationConfigError(
                "TokenFleet credential does not match the installed community server"
            )
        public_id = credential.device_public_id
    state = StateStore(paths.state).load()
    value = {
        "connected": connected,
        "server": origin,
        "device_public_id": public_id or state.device_public_id,
        "scheduled_sync": is_registered(),
        "scheduled_task": TASK_NAME,
        "last_sync_at": state.last_sync_at,
        "last_bucket_count": state.last_bucket_count,
        "last_uploaded_tokens": state.last_uploaded_tokens,
        "collectors": ["Codex JSONL", "Claude Code JSONL"],
        "cc_switch": "unsupported_in_windows_v1",
    }
    _print_value(value, as_json=args.as_json)
    return 0


def _open_rank(paths: ClientPaths) -> int:
    url = _client(paths).rank_url()
    if not webbrowser.open(url, new=2):
        raise RuntimeError("系统未能打开默认浏览器")
    return 0


def _new_device_code(paths: ClientPaths) -> int:
    code = _client(paths).issue_additional_device_code()
    try:
        copy_sensitive_text(code)
    finally:
        code = ""
    print("新的 60 分钟单次设备码已复制；请只粘贴到另一台设备的 TokenFleet。")
    print("设备码不会在终端显示，也不会加入 Windows 剪贴板历史或云同步。")
    return 0


def _uninstall(args: argparse.Namespace, paths: ClientPaths) -> int:
    if not args.yes:
        print("此操作会删除本机 TokenFleet 同步凭据和定时任务。请加 --yes 确认。")
        return 2
    unregister(ignore_missing=True)
    CredentialStore(paths.credential).clear()
    StateStore(paths.state).clear()
    print("本机同步凭据和定时任务已移除；服务端历史保留，由管理员管理。")
    if paths.install_marker.is_file():
        uninstall_script = paths.root / "app" / "uninstall.ps1"
        if uninstall_script.is_file():
            flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            subprocess.Popen(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    os.fspath(uninstall_script),
                    "-FromClient",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=flags,
                close_fds=True,
            )
            print("客户端程序将在当前命令结束后删除。")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        paths = ClientPaths.default()
        handlers = {
            "connect": _connect,
            "preview": _preview,
            "sync": _sync,
            "status": _status,
            "open-rank": lambda _args, selected: _open_rank(selected),
            "new-device-code": lambda _args, selected: _new_device_code(selected),
            "uninstall": _uninstall,
        }
        return handlers[args.command](args, paths)
    except (
        CredentialError,
        InstallationConfigError,
        ProtocolError,
        SchedulerError,
        StateError,
        RuntimeError,
        SensitiveClipboardError,
    ) as exc:
        # Error types are deliberately constructed without enrollment tokens,
        # device secrets, response bodies, prompt text, or local source paths.
        print(f"TokenFleet: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
