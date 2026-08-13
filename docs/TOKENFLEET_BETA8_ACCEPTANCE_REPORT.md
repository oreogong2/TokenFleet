# TokenFleet beta.8 本地独立验收报告

验收日期：2026-08-14

工作分支：`codex/tokenfleet-beta8`

基线：`origin/main` / `ee6a4e1fa750c4039bbba5cb4c8911e72e950257`

本报告只记录当前正式工作树的可复现证据。beta.8 尚未发布、尚未部署生产，也尚未具备让 beta.7 自动收到 prerelease 的完整外部条件。

## 用户可见结果

- 保留 TokenFleet、“每天一个亿”和原有主要导航；去掉步数式多圈表达，改为 TokenFleet 分段信号环，超过目标后继续显示真实百分比。
- 单屏默认只使用系统右侧紧凑菜单栏入口；用户可选“信号＋今日 Token”，刘海旁 Token Island 必须由用户显式选择。
- 快览恢复全宽“社群排行／连接社群”入口，直接显示本人名次、参榜人数与超过成员比例；主窗口社群页同时显示最近同步时间。
- 今日、历史、快览和分享图增加连续活跃与相对近 7 个活跃日的节奏；样本不足时不显示误导百分比，连续活跃碰到本地留存边界时显示“至少／≥”，不伪装成精确起点。
- 主题扩展为青绿、海蓝、信号青、靛蓝、紫藤、玫瑰、珊瑚、琥珀、石墨 9 套；工具识别色独立保持稳定。
- 费用统一称“API 标准价估算”：优先使用来源费用，否则按精确模型和四类 Token 使用版本化公开价；未知部分显示未计价和覆盖率。Anthropic 缓存写缺少 TTL 时，只保留该组件未计价，不丢弃同一记录里可确定的输入、输出和缓存读费用。
- 分享图改用 TokenFleet 标识和水平刻度，并区分渲染、编码、剪贴板与写文件失败；完整门禁会实际渲染分享卡、生成复制用 PNG 并把 JPEG 写入隔离临时目录。
- 管理员可从成员列表或详情页直接为已有成员补发 60 分钟一次性设备码；同一事务会让旧的未使用有效码立即失效，只保留一个有效未用码，不会新建重复成员、占批次名额或改变已使用码与审计记录。
- App 与 Helper 均构建为 `arm64 + x86_64`，Intel Mac 与 Apple Silicon 使用同一 universal App。

## 本地自动化证据

| 范围 | 结果 | 证据摘要 |
| --- | --- | --- |
| 服务端 | 通过 | `150 passed, 16 skipped`；跳过项为未配置 PostgreSQL 的 smoke。本人排名接口与补发回归验证私密资料、成员数、批次名额、已使用旧码状态不变，遗失的未使用有效码立即失效，明文码不落库；并发补发只留一个有效码的 PostgreSQL 测试等待 PR CI。 |
| Web 单元 | 通过 | Node `50 / 50`；补发请求固定为既有 `user_id + 60 分钟`，无多余字段。 |
| 静态浏览器 | 通过 | 1440、820、390 px；7 条管理路由、空／长模型／最大数、401/403/503、键盘焦点、reduced motion、对比度；console/page error 为 0。 |
| 社群浏览器竞态 | 通过 | 排行、分享、补发一次性码和退出的跨路由慢响应均不泄露旧弹窗或原始码。 |
| 临时真实联调 | 通过 | 临时 SQLite 完成批次领取、成员补发、3 台设备、极值 Token、公开榜、成本、错误登录、退出清理；浏览器 console/page error 为 0，完成后服务与临时状态均删除。 |
| Swift 完整门禁 | 通过 | 源码与 XCTest typecheck、网络/Keychain/同步状态机、Codex/Claude/CC Switch fixture、费用覆盖、迁移、本地化和语言刷新通过；分享卡实际完成 ImageRenderer、复制用 PNG 和临时 JPEG 写入。当前 Command Line Tools 没有可执行 XCTest 模块，真实 XCTest 留给 PR macOS CI。 |
| universal 构建 | 本地产物通过／Intel CI 待跑 | `TokenFleet` 与 `Contents/Helpers/TokenFleetHelper` 均由 `lipo` 确认为 `x86_64 arm64`；版本 `0.1.0-beta.8`；新 ICNS 有效。PR 新增官方 `macos-15-intel` runner，必须原生执行 XCTest、完整采集／同步门禁、App/Helper 构建及安装／升级／回滚／卸载后，才完成 Intel 正式验收。 |
| 分发身份 | 通过 | 独立构建、固定 Bundle/Team/update origin、恶意版本、重复发布目录、签名失败原子性、旧发布物保留门禁通过。 |
| 源码安装与回滚 | 通过 | fail closed、ad-hoc／社群模式、灾难与 staged rollback、显式降级、卸载以及不修改正式 `dist` 通过；本机不支持隔离 legacy file Keychain 的项目明确跳过。 |
| Windows 跨平台 | 通过／真机待跑 | macOS 上 `26 passed, 2 skipped`；两个跳过项只在真实 Windows 验证 DPAPI round-trip 与计划任务。CI 已增加安装、同源升级、preview、status 与卸载。 |

## schema 与后端影响

- 连续活跃由本地既有 `DailyUsage` 日桶计算，beta.8 不需要新增服务端 API、数据库列或迁移。
- 设备码补发复用既有 enrollment token 表与端点，只增加成员事务锁、旧未用码过期处理和回归测试，不改变 schema；已使用码保持原样。
- App 内本人排名新增设备签名鉴权的只读 API，只返回公开 ID、公开昵称状态、今日名次、参榜人数和公开口径 Token；不新增数据库列或迁移，也不返回设备密钥、内部成员 ID 或逐条用量。
- 9 套主题、相对节奏、定价目录、菜单栏规则和分享修复均为客户端变化。
- Kimi、DeepSeek、Cursor、Gemini CLI 的原生采集没有在缺少安全真实样本时强行启用；WorkBuddy 的项目日志混有会话／工具内容，beta.8 即使发现目录也不打开。可行性与隐私边界见 `TOKENFLEET_BETA8_COLLECTOR_MATRIX.md`。CC Switch 只有出现真实成功代理行才显示相应实验来源。
- 设置页的“已采集客户端”只统计成功且确有用量记录的来源（含 Codex SQLite 成功回退）；禁用、缺失及受隐私边界阻止的来源只保留诊断状态，不计入用户可见数量。

## PR / 发布前仍然阻断

1. PR 的 Apple Silicon 与官方 `macos-15-intel` runner 必须跑真实 `swift test --parallel`；Intel runner 还必须通过完整采集／同步、App/Helper 和源码安装生命周期门禁。
2. PR 的 PostgreSQL 17 服务必须让 16 条 smoke 全部通过，包含并发补发只保留一个有效未用码。
3. Windows runner 必须完成真实 DPAPI、计划任务、安装、同源升级、preview/status 和卸载；真实 Windows 10/11 成员机仍需发布前人工 E2E。
4. beta.7 当时的分享图片报错缺少入口、错误文字和环境，无法证明原故障已经复现；自动化已覆盖 App 真实分享视图渲染／复制数据／保存文件及 Web 海报边界，但仍需在奥哥安装后的真实桌面入口点击复制、保存各一次才能关单。
5. 自动更新仍缺真实 Apple Team ID、Developer ID 签名、公证凭据和独立 HTTPS 更新源。beta.7 必须手工迁移一次；没有这些条件不得声称 beta.8 能自动推送。
6. 生产服务、更新源切换、成员通知、DMG 发布与合并均未执行。执行前必须再次用中文说明影响范围和回滚，并等待奥哥单独确认。
