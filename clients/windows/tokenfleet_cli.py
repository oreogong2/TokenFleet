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
from tokenfleet.collectors import (
    experimental_scan_paths,
    import_cursor_csv,
    remove_cursor_import,
)
from tokenfleet.constants import APP_VERSION, TASK_NAME
from tokenfleet.credential import CredentialError, CredentialStore
from tokenfleet.installation import (
    CommunityInstallationConfigStore,
    InstallationConfigError,
)
from tokenfleet.paths import ClientPaths, default_source_home
from tokenfleet.protocol import ProtocolError
from tokenfleet.scheduler import SchedulerError, is_registered, register, unregister
from tokenfleet.state import StateError, StateStore
from tokenfleet.settings import SettingsStore
from tokenfleet.local_dashboard import dashboard_url, open_dashboard, serve_dashboard


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

    rank = commands.add_parser("rank", help="查询自己的社群名次")
    rank.add_argument("--json", action="store_true", dest="as_json")

    commands.add_parser("open", help="打开本机统计页面")
    commands.add_parser("open-rank", help="打开公开排行榜")

    experimental = commands.add_parser("experimental", help="管理实验 Agent 来源总开关")
    experimental.add_argument("action", choices=("status", "enable", "disable"))
    experimental.add_argument("--json", action="store_true", dest="as_json")

    cursor = commands.add_parser("cursor", help="管理 Cursor Usage CSV 手动导入")
    cursor_commands = cursor.add_subparsers(dest="cursor_action", required=True)
    cursor_import = cursor_commands.add_parser("import", help="导入 Cursor Usage CSV")
    cursor_import.add_argument("file", type=Path)
    cursor_import.add_argument("--json", action="store_true", dest="as_json")
    cursor_delete = cursor_commands.add_parser("delete", help="删除 Cursor 导入归档")
    cursor_delete.add_argument("--json", action="store_true", dest="as_json")

    commands.add_parser("_serve", help=argparse.SUPPRESS)

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
        settings_store=SettingsStore(paths.settings),
        cursor_archive=paths.cursor_usage,
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
        "experimental_sources_enabled": result.diagnostics.experimental_sources_enabled,
        "experimental_sources": result.diagnostics.source_status,
        "experimental_scan_paths": result.diagnostics.scan_paths,
        "zcode": result.diagnostics.zcode_status,
        "cc_switch": result.diagnostics.cc_switch_status,
        "privacy": "configured scan roots are disclosed; only daily aggregate usage leaves this device; no prompts, responses, code, per-record paths, or account IDs",
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
        if args.as_json:
            value["local_page"] = dashboard_url()
        _print_value(value, as_json=args.as_json)
        if not args.as_json:
            print(f"本机统计：tokenfleet open（{dashboard_url()}）")
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
    settings = SettingsStore(paths.settings).load()
    rank_summary: str
    rank_value: dict[str, object] | None = None
    if connected:
        try:
            rank = _client(paths).community_rank()
            rank_value = {
                "rank": rank["rank"],
                "total_entries": rank["total_entries"],
                "metric_value": rank["metric_value"],
            }
            rank_summary = _rank_summary(rank)
        except RuntimeError:
            rank_summary = "暂时无法读取"
    else:
        rank_summary = "尚未连接"
    value = {
        "connected": connected,
        "server": origin,
        "device_public_id": public_id or state.device_public_id,
        "scheduled_sync": is_registered(),
        "scheduled_task": TASK_NAME,
        "last_sync_at": state.last_sync_at,
        "last_bucket_count": state.last_bucket_count,
        "last_uploaded_tokens": state.last_uploaded_tokens,
        "collectors": ["Codex JSONL", "Claude Code JSONL", "实验 Agent 来源（总开关）"],
        "experimental_sources_enabled": settings.experimental_sources_enabled,
        "community_rank": rank_value,
        "rank_summary": rank_summary,
        "cc_switch": "unsupported_in_windows_v1",
        "local_page": dashboard_url(),
    }
    if args.as_json:
        _print_value(value, as_json=True)
    else:
        text_value = dict(value)
        text_value.pop("community_rank")
        text_value.pop("rank_summary")
        _print_value(text_value, as_json=False)
        print(f"我的名次：{rank_summary}")
        print(f"本机统计：tokenfleet open（{dashboard_url()}）")
    return 0


def _rank_summary(value: dict[str, object]) -> str:
    rank = value.get("rank")
    metric = value.get("metric_value")
    total_entries = value.get("total_entries")
    if rank is None:
        return "当前没有公开名次"
    return f"第 {rank} 名 / {total_entries} 人，本期 {metric or '0'} Token"


def _rank(args: argparse.Namespace, paths: ClientPaths) -> int:
    value = _client(paths).community_rank()
    if args.as_json:
        _print_value(value, as_json=True)
    else:
        print(_rank_summary(value))
    return 0


def _open(paths: ClientPaths) -> int:
    open_dashboard(Path(__file__).resolve(), paths)
    return 0


def _experimental(args: argparse.Namespace, paths: ClientPaths) -> int:
    store = SettingsStore(paths.settings)
    if args.action == "enable":
        settings = store.set_experimental_sources(True)
    elif args.action == "disable":
        settings = store.set_experimental_sources(False)
    else:
        settings = store.load()
    value: dict[str, object] = {
        "enabled": settings.experimental_sources_enabled,
        "history_backfill_days": 180,
        "scan_paths": experimental_scan_paths(default_source_home()),
        "privacy": "只提取结构化 usage；不保存、展示或上传 prompt、回复或代码正文",
    }
    _print_value(value, as_json=args.as_json)
    return 0


def _cursor(args: argparse.Namespace, paths: ClientPaths) -> int:
    if args.cursor_action == "import":
        value: dict[str, object] = import_cursor_csv(args.file, paths.cursor_usage)
    else:
        value = {"removed": remove_cursor_import(paths.cursor_usage)}
    _print_value(value, as_json=args.as_json)
    return 0


def _open_rank(paths: ClientPaths) -> int:
    url = _client(paths).rank_url()
    if not webbrowser.open(url, new=2):
        raise RuntimeError("系统未能打开默认浏览器")
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
            flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
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
            "rank": _rank,
            "open": lambda _args, selected: _open(selected),
            "open-rank": lambda _args, selected: _open_rank(selected),
            "experimental": _experimental,
            "cursor": _cursor,
            "_serve": lambda _args, selected: serve_dashboard(selected),
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
    ) as exc:
        # Error types are deliberately constructed without enrollment tokens,
        # device secrets, response bodies, prompt text, or local source paths.
        print(f"TokenFleet: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
