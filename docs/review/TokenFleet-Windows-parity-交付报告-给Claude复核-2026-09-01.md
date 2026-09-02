# TokenFleet Windows parity 交付报告（给 Claude 只读复核）

## 1. 交付状态

- 真源：`https://github.com/oreogong2/TokenFleet.git`
- 基线：PR #15 head `5a65d7cebdb23737df54392d393aca3ed01645e0`
- 隔离分支：`codex/windows-parity`
- 当前状态：Claude 终审与增量确认均已通过；审定实现固定在功能提交 `374008f`，进入 beta.11 发布流程。Windows 动态安装链路仍以本次 PR CI／首批真机裁决为准。
- 发布边界：发布身份更新为 `0.1.0-beta.11` / collector `0.2.1`；Windows collector 独立号为 `0.2.0-windows.3`。最终合并提交、tag、CI 和 GitHub prerelease 证据以发布页为准，飞书加入指南在发布后同步固定提交。

## 2. 完成范围

1. 将 Mac 已冻结的 18 个来源迁移到 Windows，保留模型选择、cache/total 归一、累计屏障、请求/会话去重与优先级。ZCode 常开，Cursor 仅手动导入，另外 16 个自动来源受同一总开关控制。
2. 16 个自动实验来源的 `_SourceResult.incomplete_buckets` 全部接入 `_aggregate(excluded_keys=...)`；任一带日期、工具、模型的分量／authoritative total 冲突会扣留整个桶，不再只丢坏行后把余量贴成 `exact`。
3. Qwen `localDate` 只接受 `%Y-%m-%d`，Kimi `config.toml` 同时隔离编码错误；单个来源的畸形日期／配置不再中止整次采集。ZCode `session_id` 回退为可选列，旧 schema 不会整源归零。
4. 两端实验总开关默认开启。Windows 缺设置文件为 true，v1 设置只来自显式操作并原值迁移；Mac 无 configured 标记的旧 true 保持 true／configured，旧 false 或缺失统一迁为 true／unconfigured。新版本中任何一次显式操作都会写 configured=true，此后永久尊重。
5. dsh 使用锁定的 Python `zstandard==0.25.0` wheel，不调外部 `zstd` 进程；`.jsonl.zstd` 对同名明文权威覆盖，缺解码器时有 `missing_decoder` / `partial_missing_decoder` 状态。
6. 新增 `tokenfleet rank`，使用现有签名 GET `/api/v1/devices/me/community-rank`；支持 Top 100 之外名次，`status` 纯文本只打印一句名次摘要。服务端零改动。
7. 新增纯 HTML/CSS/JS 本机页：今日、本周、工具/模型分布、社群名次、实验开关/状态/固定扫描根目录、Cursor CSV 导入和删除。无 React/Vite/Node 运行时。
8. 本机服务只绑定 `127.0.0.1:47831`，`allow_reuse_address=False`，Windows 设置 `SO_EXCLUSIVEADDRUSE`，Handler socket timeout=10 秒。真实 HTTP 请求级测试覆盖错误 Host=421、错误 Origin/token=403、合法请求=200，以及 Cursor CSV 超过 10 MiB 在读取 body 前返回 413。
9. 写操作增加安装期随机 token（数据目录 ACL、URL fragment 注入、页面转存 `sessionStorage`）；启动器先用 challenge-HMAC 验证现有端口确属本安装实例，再把 token 交给浏览器。排行榜结果落本机缓存 5 分钟，刷新本机页不再持续消耗同步签名配额。
10. 安装器创建隔离 venv，锁定安装 zstandard；升级时若计划任务已存在，强制用安装后 runtime 重新注册。`-NoOpen` 只在旧本机服务原本运行时后台恢复 `_serve`，不拉浏览器；卸载删除失败重试 3 次并最终显错。
11. 浮点 epoch 取整接受；模型键只移除 Unicode Cc/Cf，保留 Co/Cn，空值回 `unknown`；畸形 Cursor CSV 的 `csv.Error` 在 handler 边界内转为可见错误。
12. Cursor 仍只接受用户主动选择的 Usage CSV，不扫描下载目录或登录态，使用客户端正常历史窗口而不受自动实验来源 180 天上限影响；Copilot OTel 仍需用户自行开启 exporter，采集结果会按实际来源显示为 `Copilot CLI` 或 `Copilot Chat`。

## 3. 来源逐项矩阵

`确认等级` 只评估 Windows 路径/格式证据，不代表已在当地 Windows 真机上读到个人数据。本任务没有 Windows 真机数据，所有厂商未明确承诺的 Windows 路径均保留“待真机确认”。

| 来源 | Windows 扫描位置 | 冻结口径 | 公开证据 / 确认等级 |
|---|---|---|---|
| ZCode | `%USERPROFILE%\.zcode\cli\db\db.sqlite` | 只查 `model_usage` 已完成行；核心列必须存在；reasoning/cache/provider/computed total 有则严格校验；不读 transcript | 沿用 Mac 冻结规则；Windows 路径待真机确认 |
| Hermes Agent | `%USERPROFILE%\.hermes\state.db` | `sessions` 表，会话级 input/output/cache/reasoning，只读 SQLite | [Hermes 官方 session storage](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/session-storage.md) 确认路径、表和字段 |
| WorkBuddy | `%USERPROFILE%\.workbuddy\projects` + `%APPDATA%\WorkBuddyExtension` | `usage/rawUsage`；request id 去重；model 优先 `requestModelId`；按 explicit total 判定 input 是否已含 cache | 未找到厂商公开 Windows 路径；待真机确认 |
| CodeBuddy | `%USERPROFILE%\.codebuddy\projects` + `sessions` | 只计 assistant；request/session 去重；Claude-shaped usage 归一 | 未找到厂商公开 Windows 路径；待真机确认 |
| Qoder | `%USERPROFILE%\.qoder\projects` | 只计 assistant；额外拒绝 `session_summary` / cumulative 状态行；request/session 去重 | [公开样例](https://github.com/nwflower/dsh-chat-import/blob/main/CHANGELOG.md) 确认 Claude-style JSONL 布局，非厂商一手文档；待真机确认 |
| Kimi | `%USERPROFILE%\.kimi-code\sessions\**\wire.jsonl` | `step.end` 逐步 usage；`config.update` 跟踪 model；event id 去重 | [Kimi 官方 sessions 文档](https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/guides/sessions.md) 确认路径与 `wire.jsonl` |
| OpenCode | `%USERPROFILE%\.local\share\opencode` 为 Windows 实际默认，同时容忍 `%LOCALAPPDATA%\opencode` / `OPENCODE_DATA_DIR` | 只读 `message` / `session_message`；只计 assistant；message/session 去重；cache/total 严格归一 | OpenCode 官方仓库 Windows 报告 [#26573](https://github.com/anomalyco/opencode/issues/26573) 和 [#26207](https://github.com/anomalyco/opencode/issues/26207) 均显示 `%USERPROFILE%\.local\share\opencode\opencode.db`；属项目样例，仍待真机回归 |
| Grok | `%USERPROFILE%\.grok\sessions\**\updates.jsonl` | 只计 `turn_completed.usage`，优先 `modelUsage`；不把 context total 当消耗；cached input 从 input 中拆出 | [公开真实样例](https://github.com/robinebers/openusage/issues/1126) 和 [TokenTracker 回归](https://github.com/xiufengsun/TokenTracker/issues/362) 确认形状，非 xAI 一手文档；待 Windows 真机确认 |
| Qwen Code | `%QWEN_RUNTIME_DIR%\usage` / `%QWEN_HOME%\usage` / `%USERPROFILE%\.qwen\usage` | `token-usage-*` schema v1；id 去重；`thoughtsTokens` 并入 output；cache/total 校验 | [Qwen 官方配置](https://github.com/QwenLM/qwen-code/blob/main/docs/users/configuration/settings.md) 确认 `QWEN_HOME` / `QWEN_RUNTIME_DIR`；`usage` 子布局沿用 Mac 冻结样例，待真机确认 |
| Cursor | `%LOCALAPPDATA%\TokenFleet\data\cursor-usage.json` 内部归档（不扫描 Cursor 目录） | 用户手动 CSV；BOM 容错；日期/时间；全字段稳定键幂等合并/删除；使用正常 history_days，不套自动实验来源 180 天上限 | [Cursor 官方 Analytics](https://cursor.com/docs/account/teams/analytics) 确认 CSV 下载；个人账号 CSV 列形状需继续真机验证 |
| Cline | `%USERPROFILE%\.cline\data` / `CLINE_DATA_DIR`，加 VS Code/Cursor/Windsurf/Trae 等 `%APPDATA%\...\globalStorage` 兼容根 | 优先 v1 `*.messages.json`；只计 assistant metrics；同 session 不再计旧 `ui_messages.json`；旧 API start/finish 合并 | [Cline 官方 CLI 文档](https://github.com/cline/cline/blob/main/docs/cli/cli-reference.mdx) 确认 `~/.cline` / `CLINE_DATA_DIR`；IDE 扩展兼容根待 Windows 真机确认 |
| Copilot CLI | `%USERPROFILE%\.copilot\session-store.db` / `COPILOT_HOME` | `assistant_usage_events`；token details 与总量一致时优先；row id 去重 | [GitHub 官方目录参考](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference) 确认 `~/.copilot/session-store.db`；表形状仍按 Mac 冻结口径失败关闭 |
| Copilot OTel（输出 `Copilot CLI` / `Copilot Chat`） | `COPILOT_OTEL_FILE_EXPORTER_PATH`，另兼容 `.copilot\otel` / `%LOCALAPPDATA%` / `%APPDATA%` | 只计 `chat` span；GenAI usage 字段；trace/span 去重；同 session 窗口优先 session-store，无会话 id 时仅同日保守回退 | [GitHub 官方 OTel 文档](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference) 确认 file exporter 与 token 属性 |
| Antigravity | `%USERPROFILE%\.gemini\{antigravity,antigravity-cli,antigravity-ide}\brain` | 只计 result/complete，不计 statusline 累计；Gemini `thoughtsTokenCount` 并入 output | 公开样例确认 [antigravity-cli brain transcript](https://github.com/srjn45/warden/blob/main/docs/agent-backends/antigravity.md)，非 Google 正式存储合约；待 Windows 真机确认 |
| Droid | `%USERPROFILE%\.factory\projects\**\session.jsonl` | 只计 result/complete，明确丢弃 `TokenUsageUpdate` 累计行 | 未找到 Factory 一手 Windows 存储合约；待真机确认 |
| dsh | `%DSH_HOME%\sessions` / `%USERPROFILE%\.dsh\sessions` | Python zstandard；压缩优先；assistant chunk 优先 message；每 step 只落一条；解码不全显示 partial | [公开迁移样例](https://github.com/nwflower/dsh-chat-import/blob/main/CHANGELOG.md) 确认 `session.jsonl.zstd` 及去外部进程方向，非 dsh 厂商一手文档；待真机确认 |
| Pi | `%PI_CODING_AGENT_SESSION_DIR%` / `%PI_CODING_AGENT_DIR%\sessions` / `%USERPROFILE%\.pi\agent\sessions` | 只计 assistant message usage；session + entry id 去重；reasoning 仅在 total 证明额外时并入 | [Pi 公开 session 文档](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/session.md) 和 [settings 文档](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/settings.md) 确认默认路径与环境变量 |
| OpenClaw | `%OPENCLAW_STATE_DIR%` / `%USERPROFILE%\.openclaw` | 优先每 agent `openclaw-agent.sqlite` 的 `transcript_events`，兼容旧/归档 JSONL；session + event id 跨存储去重 | [OpenClaw 官方 FAQ](https://github.com/openclaw/openclaw/blob/main/docs/help/faq.md) 和 [database schema](https://github.com/openclaw/openclaw/blob/main/docs/reference/database-schemas.md) 确认 state root、DB 位置与迁移布局 |

## 4. 差异与保守处理

- **dsh 解压方式**：Mac 旧路径使用系统 `zstd`；Windows 按任务要求改为安装器内的 Python `zstandard`，避免系统依赖与外部进程。
- **OpenCode Windows 默认路径**：公开 Windows 样例显示它仍用 `%USERPROFILE%\.local\share\opencode`，因此实现与披露都包含该路径；也容忍 `OPENCODE_DATA_DIR` 和 `%LOCALAPPDATA%\opencode`，但不默认它们已被上游在 Windows 信赖。
- **Qoder 累计屏障**：比当前 Mac 函数多一道 `session_summary` / cumulative 守卫，是按本任务明确要求添加的保守偏差，防止会话累计量冒充单请求。
- **本机页安全**：Host 防 DNS rebinding；Origin + action header 防浏览器跨站写；安装随机 token 防同机普通进程直接伪造写；challenge-HMAC 防抢占端口的进程骗取 fragment token。读接口仍只在回环提供聚合数据，`/health` 的可指纹化按 P2 保留。
- **Mac 改动边界**：仅改实验总开关的默认值、显式配置标记、归一化传递和对应测试，没有改 Mac 采集器冻结口径。
- **默认开启后的巡检**：按原计划跑 7 天；口径错误立即修复并由相同 naturalKey 覆盖自愈。修复后不再发送旧桶、无法自愈的残留要列清单走管理员通道清理。
- **文档边界**：CHANGELOG、README、安装、隐私、支持策略、产品规格与公告已统一为 beta.11 口径；飞书加入指南在发布完成后同步 tag 与固定 SHA。

## 5. 验证证据

| 门禁 | 结果 |
|---|---|
| Windows Python unit tests | 正确命令必须先 `cd clients/windows`，再运行 `PYTHONDONTWRITEBYTECODE=1 <venv>/bin/python -m unittest discover -s tests -v`：安装锁定依赖后为 `62 passed + 3 skipped`，共 65 项；3 项仅因当前为 macOS 而 skip（DPAPI、Task Scheduler、Windows `SO_EXCLUSIVEADDRUSE`／真实 IPv4 loopback bind）。新增项以 cp1252 输出流验证 `status --json` 不因中文字段崩溃 |
| 来源覆盖 | 18/18；覆盖各来源规则、cache/total、累计屏障、去重、Copilot 优先级、Qwen/Kimi 崩溃隔离、实验残缺桶整桶扣留、Grok 累计/context total 拒收、Cursor BOM/幂等/删除与历史窗口 |
| 总开关 | Windows/Mac 默认 true；Windows 缺文件、v1 显式 false/true、v2 configured 标记均有回归；Mac 旧 true、旧 false、缺字段与新版 configured round-trip 均有门禁；关闭时 monkeypatch 证明未调 16 个自动来源的路径解析；自动来源 180 天上限有动态时间回归；ZCode/Cursor 不受关闭影响 |
| 名次 | 没有独立“签名 GET 黄金向量”。GET 用例断言路径、第 137 名和签名字段，但期望值由同一个 `signed_headers` 重算；算法独立钉死依赖现有 POST HMAC 黄金向量（含服务端持有向量）间接覆盖。`status` 单行摘要有回归 |
| 服务端既有合约 | `server/tests/test_public_community.py -k device_rank`：`2 passed` |
| 本机页 | 请求级 Host/Origin/action token；403 回传“请从桌面快捷方式重新打开”；10 MiB 上传上限在读 body 前返回 413；Handler timeout=10；challenge-HMAC；今日/本周多桶、排序、排除上周；名次缓存两次刷新只请求一次；非回环拒绝；Windows CI 增加真实 socket bind 与独占端口测试 |
| dsh | 实际安装 `zstandard==0.25.0` 后执行：压缩优先、`missing_decoder`、`partial_missing_decoder`、多 step／多 usage chunk 取每步最终值。跨 SQLite/JSONL 去重属于 OpenClaw，不再误写成 dsh 覆盖 |
| 模型／拒收 | Cc、Cf 清除；Co 保留（实现同样保留 Cn）；无模型 `unknown`；浮点 epoch 取整；Grok explicit total 冲突扣整桶，只有累计/context total 而无精确分量时拒收；畸形 CSV 可见错误 |
| Mac 变更门禁 | `TOKENFLEET_SWIFT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk bash script/verify_tokenstep_swift.sh`：全量 type-check、App 链接、logic harness 与采集/迁移 fixture 通过；本机 CommandLineTools 无 XCTest runtime，因此 XCTest 源码仅 type-check，CI 仍负责真实 XCTest |
| 安装器 | 静态验证隔离 runtime、self-healing launcher、桌面/开始菜单 `.lnk`、action token ACL、升级任务重注册、`-NoOpen` 恢复、卸载重试；动态 PowerShell 留给 Windows CI／真机 |
| 语法/静态 | Python `compileall`、`node --check clients/windows/web/app.js`、`git diff --check` 全通过 |
| 发布身份 | `script/verify_release_identity.py` 通过；release `0.1.0-beta.11`、collector `0.2.1`、默认安装／构建版本一致 |
| 范围审计 | `server/` 零变更；`TokenStepSwift/` 只含默认值/迁移标记及测试；无 React/Vite/Node runtime；无账号/schema/自更新/单来源开关/原生壳 |

CI Windows job 已改为安装锁定 `requirements.txt` 后执行整套测试，因此上述 3 项真 Windows 用例会在 PR CI 中实际执行；安装/升级/卸载链路也使用 `-NoOpen` 避免 CI 弹浏览器。当前 macOS 主机没有 PowerShell，所以 PowerShell 动态执行与 `.lnk` 真机落盘必须由 Windows CI/真机给最终证据。

## 6. 条件通过后的增量快速确认

1. Mac 旧设置无 configured 标记时：true → true/configured；false 或缺失 → true/unconfigured；新版本显式关闭 round-trip 为 false/configured。
2. 新增请求级 10 MiB 上限回归；Handler timeout=10；写操作 403 提示从桌面快捷方式重新打开。
3. 新增 Grok 只有累计/context total、没有可核对分量时拒收的行为回归。
4. Cursor 从自动实验来源 180 天过滤中拆出，181 天前的手动导入记录在 366 天调用窗口内仍入账。
5. 本机页、README、CHANGELOG、PRIVACY、INSTALL、Agent 支持策略、公告草稿和飞书指南已补齐 `Copilot Chat` 与新迁移口径。

Claude 已逐项核验上述增量并放行，功能提交 `374008f` 已形成；beta.11 可按发布门禁进入 PR、CI、合并、tag 与 prerelease 流程。Windows PowerShell 动态路径和 3 个专属用例以该 PR CI 与首批真机反馈为最终证据。
