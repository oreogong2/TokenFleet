# TokenFleet

> 基于 MIT 许可的 TokenStep v0.1.48 改造：保留本地统计能力，新增工具/模型精确明细、多设备合并、邀请制社群排行榜和管理员后台。上游版权与许可见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。产品边界、验证状态与部署说明见 [TOKENFLEET.md](TOKENFLEET.md)。

**像记录步数一样，记录你每天的 AI Token 消耗。**

AI 时代，每个人都在和 Agent 一起工作。

但我们很少知道：今天到底用了多少 AI？有没有比昨天更进一步？

TokenFleet 包含原生 macOS 菜单栏 App 和轻量 Windows 参赛端，用来本地统计 Codex、Claude Code 等 AI 编程工具的 Token 消耗；受邀成员还可通过管理员创建的限额批次链接登记唯一昵称，领取自己的单次设备码并加入同一个社群榜。

默认目标是：**每天 1 亿 Token**。

当你超过目标，圆环会进入下一圈。用得越多，颜色越深。

它不是为了严肃比较，而是让你直观看到：今天你和 AI 一起走了多远。

## 当前发布方式

TokenFleet 当前只提供**经过复核的源码安装**，不要求 Apple Developer 付费账号，也没有可下载的官方 DMG。不要把上游 TokenStep 的 DMG 当成 TokenFleet 安装包。

- macOS：检出管理员复核并公布的完整 commit SHA 后运行仓库内的 `script/install_from_source.sh`。纯本地模式使用 ad-hoc 签名；社群同步模式会在每台 Mac 的登录钥匙串创建独立、不可导出的本机自签身份，使 TokenFleet 自己的凭据访问在源码升级后保持稳定。
- Windows：运行 `clients/windows/install.ps1`，设备 secret 由当前用户 DPAPI 加密保存。
- Developer ID、公证 DMG 和自动更新属于未来可选分发方式，不是当前安装前提。

完整流程和安全边界见 [docs/INSTALL.md](docs/INSTALL.md)。

### 社群服务器

阿里云单机部署已经整理为独立的 [deploy/README.md](deploy/README.md)：Docker
运行一个 TokenFleet 进程和 PostgreSQL 17，宿主机 Nginx 作为唯一公网入口，
Let's Encrypt 证书由 Certbot 免费申请并自动续期，并带每日备份、恢复校验和
隔离 Docker E2E。域名与证书不需要额外购买，主要成本是一台服务器。

> **Legacy 警告：**仓库根目录的 `install-launchd.sh` 只属于早期 Python/launchd 原型，已设置为安全退出；它不能安装 TokenFleet、登记设备或启用社群榜。不要把它当作 TokenFleet 安装入口。

## TokenFleet 适合谁？

TokenFleet 适合这些人：

- 每天使用 Codex / Claude Code 写代码的人
- 用 AI Agent 做内容、开发、研究、自动化的人
- 想知道自己每天到底消耗了多少 AI Token 的人
- 把 AI 当成生产力基础设施，而不是偶尔试用工具的人
- 想和同一社群的伙伴查看公开聚合排名、模型与估算费用的人

以前我们看步数，知道自己今天有没有动起来。

现在我们看 Token 消耗，知道自己今天有没有真正用 AI 推进工作。

## 它能做什么？

- 菜单栏实时显示今日 Token 消耗和进度圆环。
- 点击菜单栏打开轻量浮层。
- 原生 macOS 仪表盘：今日、历史、统计、模型与工具、隐私。
- 超过 1 亿后自动进入第 2 圈、第 3 圈。
- 最近 30 天 Token 使用趋势。
- 按客户端、按模型查看用量统计。
- 粗略估算 Token 消耗金额。
- 每日目标可设置，默认每天一个亿。
- 打开面板时按设置的新鲜度刷新；后台在接电时最低 15 分钟、电池或低电量模式下最低 30 分钟刷新，并跳过未变化的数据。
- 开机启动，可在设置里关闭。
- 多种主题色，菜单栏、圆环、活动墙和按钮会一起变化。
- 一键截图分享当前页面。
- 一键生成「昨日 AI 节奏」分享卡，展示 24 小时使用波形、峰值时段和节奏标签。
- Codex / Claude Code 剩余额度可在设置中打开，默认关闭。
- 保留已签名公证 DMG 的更新能力，但源码安装阶段不启用；当前升级方式是切换到管理员指定的新 tag 后重跑安装脚本。
- 管理员可创建最多 50 人、最长 24 小时的自助批次链接；成员只填唯一昵称并明确同意公开，系统原子生成非登录参赛者和 60 分钟单次设备码。
- 第二台设备或个别补发仍由管理员为已有参赛者生成独立短期、单次接入码。
- 同一参赛者的多台 Mac 或 Windows 设备分别登记、统一求和；不要求共享 Codex / Claude 账号。
- 匿名可读的蓝白社群榜、公开个人页和浏览器本地生成的 Top 10 分享海报。
- 本地数据路径：macOS 为 `~/Library/Application Support/TokenFleet`，Windows 为 `%LOCALAPPDATA%\TokenFleet`。

## 当前支持

- Codex：读取本地 JSONL 用量元数据并维护逐会话增量缓存；缓存异常时自动重建，必要时回退 Codex 本地 SQLite 汇总。
- Claude Code：读取 `~/.claude/projects/**/*.jsonl` 里的 usage 元数据。
- CC Switch（macOS）：实验支持，读取本机 `proxy_request_logs` 中成功且 token 数大于 0 的请求行。
- 额度显示：Codex 读取本机 Codex 账户限额；Claude Code 会在本机读取 Claude Code 钥匙串凭证，并请求 Anthropic usage 接口获取 5 小时 / 7 天剩余额度。
- Windows 10/11 参赛端：读取 Codex 与 Claude Code 本地 JSONL，用当前用户 DPAPI 保护设备 secret，通过计划任务自动同步，并提供预览、状态、手动同步和打开公榜命令。

Windows 首版不采集 CC Switch，也尚未提供与 macOS 原生 App 等同的完整桌面历史与统计界面。Kimi Code、Gemini CLI、OpenCode 等候选只在出现真实需求并完成可靠本地日志验证后增加，首版不猜数据。

支持策略和候选 Agent 说明见 [docs/AGENT_SUPPORT.md](docs/AGENT_SUPPORT.md)。

## 隐私

TokenFleet 默认只做本地统计；社群同步由成员打开管理员发出的受限批次链接或专属设备链接、阅读公开范围并在客户端主动确认后开启。

它只读取 Token 用量元数据，例如日期、模型、客户端名称和 Token 数量，用于生成趋势、圆环和统计图。

它不会上传你的代码、prompt、对话正文或项目文件。官方安装命令会把唯一社群 HTTPS
地址写进客户端配置，运行时不提供成员覆盖入口，因此历史日聚合不能改发到任意服务器；
这个地址由安装/构建产物固定，而不是把某个域名硬编码进通用源码。

「消耗金额」只是本地粗略估算，不等于真实账单。

完整说明见 [docs/PRIVACY.md](docs/PRIVACY.md)。

## 安装方式

### macOS

要求 macOS 14+、Apple Silicon 和 Xcode Command Line Tools。先从维护者指定的官方仓库检出管理员公布的完整 commit SHA；普通 Git tag 可以被移动，不能只凭 tag 名称信任代码：

```bash
git clone <official-repo-url> TokenFleet
cd TokenFleet
git checkout --detach <reviewed-commit-sha>
test "$(git rev-parse HEAD)" = "<reviewed-commit-sha>"
./script/install_from_source.sh \
  --enable-community-sync \
  --community-server https://<community-domain>
```

脚本会构建、验证并原子安装到 `~/Applications/TokenFleet.app`；它不接受一次性连接码。首次接入时先从管理员发出的批次链接登记唯一昵称并复制个人设备码，再在 App 的“社群榜同步”安全输入框粘贴。

如果只看本地统计、不加入社群榜：

```bash
./script/install_from_source.sh
```

升级时在同一 clone 切换到管理员给出的新 tag，再重复相同安装命令。回滚和卸载：

```bash
./script/rollback_source_install.sh
./script/uninstall_source_install.sh
```

更详细的安装说明见 [docs/INSTALL.md](docs/INSTALL.md)。

### Windows 10/11

Windows 首版从经过复核的源码发布包安装：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clients\windows\install.ps1 `
  -CommunityServer https://<community-domain>
```

安装后运行 `tokenfleet connect`，在隐藏输入中粘贴管理员为这台设备单独生成的一次性码。社群地址在安装时固定，升级必须保持一致；`connect` 不接受任意服务器参数。完整说明见 [clients/windows/README.md](clients/windows/README.md)。它支持采集、安全连接、自动同步和上榜，但不是 macOS 原生桌面界面的 Windows 复刻版。

## 为什么做 TokenFleet？

因为 AI 编程工具正在变成新的「工作现场」。

过去我们用日历看时间，用步数看运动，用记账软件看消费。

但 AI 使用量一直是隐形的。

TokenFleet 想把个人使用和团队费用一起变得可见：

**今天你不是用了多少工具，而是和 AI 一起走了多少步。**

## macOS 本地构建

要求：

- macOS 14+
- Xcode Command Line Tools

构建并运行：

```bash
./script/build_and_run.sh --verify
```

只构建不启动：

```bash
./script/build_swiftui_and_run.sh --no-launch
```

不提供 `TOKENFLEET_COMMUNITY_SERVER_URL` 时，本地开发包仍可查看本机统计，但社群榜
登记与同步会 fail closed。正式发布必须把唯一的小写 ASCII DNS HTTPS origin 固定进
签名包；成员运行时不能通过环境变量或设置覆盖。

生成的 App 位于：

```text
TokenStepSwift/dist/TokenFleet.app
```

## 未来可选：付费 Apple 分发

Developer ID 签名 + Apple 公证：

```bash
TOKENFLEET_VERSION=0.1.0-beta.7 \
TOKENFLEET_BUNDLE_ID="com.yourcompany.TokenFleet" \
TOKENFLEET_TEAM_ID="ABCDE12345" \
TOKENFLEET_UPDATE_API_URL="https://updates.example.com/tokenfleet/latest" \
TOKENFLEET_COMMUNITY_SERVER_URL="https://tokenfleet.example.com" \
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TOKENFLEET_NOTARY_PROFILE="tokenfleet-notary" \
./script/package_release.sh
```

产物会生成到：

```text
release/TokenFleet-<version>/TokenFleet-<version>.zip
release/TokenFleet-<version>/TokenFleet-<version>.dmg
release/TokenFleet-<version>/TokenFleet-<version>-SHA256SUMS
```

维护者说明见 [docs/RELEASE.md](docs/RELEASE.md)。

## 开源协议

基于 MIT License。见 [LICENSE](LICENSE) 与上游归属说明 [NOTICE](NOTICE)。
