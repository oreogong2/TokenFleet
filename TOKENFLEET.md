# TokenFleet

TokenFleet 是基于 TokenStep v0.1.48 的邀请制社群 AI Token 账本：保留原有 macOS 本地统计能力，并提供轻量 Windows 参赛端，同时新增精确工具/模型明细、非登录参赛者、多设备、管理员后台、公开社群榜和独立成本账本。

## 核心边界

- 只同步日期、时区、工具、模型、四类 Token 和匿名设备 ID；
- 不采集 prompt、回复、代码、文件、项目路径或会话正文；
- 不读取、保存或转发生财 OpenToken 的个人 URL/secret；
- 管理员只填昵称创建参赛者，每台设备使用一个默认 60 分钟、最长 24 小时的单次接入码；参赛者没有邮箱、密码、微信或 Web session；
- 同一参赛者可以登记任意多台设备，后台与公开投影明确按设备求和，不冒充跨设备去重；
- 同一安装重新连接会复用设备账本并轮换密钥，既不复制历史，也不允许把设备身份转给另一成员；
- 匿名公开页只展示显式开启者的昵称、排名、四类 Token、工具/模型、日趋势和公开标准价估算；不展示邮箱、内部 ID、设备、小时、会话、消息或城市；
- Token 不作为员工绩效或个人产出指标。

## 目录

- `TokenStepSwift/`：原生 macOS 客户端、本地采集、精确历史和团队同步；
- `clients/windows/`：Windows 10/11 Codex / Claude Code 采集、DPAPI 凭据、计划任务同步和公榜入口；
- `server/`：FastAPI 多租户账本、RBAC、设备注册、HMAC、价格和留存；
- `web/`：无构建依赖的管理员后台、匿名社群榜、公开个人页和本地分享海报；
- `docs/TOKENFLEET_PRODUCT_SPEC.md`：产品范围；
- `docs/TOKENFLEET_ARCHITECTURE.md`：跨端协议；
- `docs/TOKENFLEET_ACCEPTANCE.md`：发布证据与未完成门槛；
- `docs/TOKENFLEET_OPERATIONS.md`：部署、备份、恢复与事故处理。

## 验证

```bash
# 服务端
cd server
PYTHONDONTWRITEBYTECODE=1 .venv/bin/pytest -p no:cacheprovider -q

# Web
cd ../web
npm test
python3 tests/community_browser.py

# macOS 客户端（适配当前 CLT/SDK 错配环境）
cd ..
bash script/verify_tokenstep_swift.sh
bash script/verify_source_distribution.sh
bash script/verify_tokenfleet_desktop_identity.sh

# Windows 客户端的跨平台单元检查
PYTHONPATH=clients/windows python3 -m unittest discover -s clients/windows/tests -v
```

真实 API 和浏览器联调脚本：

- `script/verify_tokenfleet_e2e.py`
- `script/verify_tokenfleet_live_web.py`
- `script/verify_tokenfleet_web.py`

前两条脚本会写入随机测试数据，只能对可丢弃实例运行，并要求显式写入确认与精确目标 URL；详细命令见 `server/README.md`。

具体环境创建与运行方式见 `server/README.md` 和 `web/README.md`。

## 当前发布判断

- SQLite 单实例开发/小团队试运行：已通过自动化与真实浏览器联调；
- PostgreSQL 数据层：真实 PostgreSQL 17 迁移、回滚/再升级、schema 漂移、自然键/质量/tombstone/配额并发、跨连接设备与组织限速、一次性注册竞争和三设备极值黑盒均已通过；
- PostgreSQL 生产部署：仍需在目标环境完成 TLS、数据库/备份加密、单进程或网关级共享人类登录限流、监控和恢复演练；
- 生产稳定版：当前 50 人邀请测试用于集中收集反馈；要改称稳定版，仍须完成至少 14 天
  连续运行且 P0/P1 为 0；
- macOS 社群连接：file-login Keychain 凭据存储、固定 HTTPS origin、本机稳定自签安装、升级回滚与安全关闭路径均已落地；自动化只使用隔离临时钥匙串。向社群下发前仍须在一台干净 Mac 的真实登录钥匙串完成首次登记、重启、升级复用和卸载保留人工验收。
- Windows 参赛端：首版支持 Codex / Claude Code 采集、DPAPI 安全连接、安装时固定社群 origin、计划任务自动同步和上榜，跨平台自动化 26 项通过；不采集 CC Switch，也不宣称具备 macOS 同级完整桌面明细。向社群下发前仍须在真实 Windows 10/11 完成 DPAPI、计划任务、升级和卸载 E2E。

TokenStep 上游代码遵循 MIT License；本仓库保留原版权与许可声明，见 `LICENSE` 与 `NOTICE`。
