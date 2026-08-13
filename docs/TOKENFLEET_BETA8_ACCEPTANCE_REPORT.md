# TokenFleet beta.8 本地独立验收报告

验收日期：2026-08-13

工作分支：`codex/tokenfleet-beta8`

基线：`origin/main` / `ee6a4e1fa750c4039bbba5cb4c8911e72e950257`

本报告只记录当前正式工作树的可复现证据。beta.8 尚未发布、尚未部署生产，也尚未具备让 beta.7 自动收到 prerelease 的完整外部条件。

## 用户可见结果

- 保留 TokenFleet、“每天一个亿”和原有主要导航；去掉步数式大圆环，改为三段信号标识与水平目标刻度。
- 单屏默认只使用系统右侧紧凑菜单栏入口；刘海旁 Token Island 必须由用户显式选择。
- 快览恢复全宽“社群排行／连接社群”入口，排名显示名次、参榜人数、超过比例和榜单更新时间。
- 今日、历史、快览和分享图增加连续活跃与相对近 7 个活跃日的节奏；样本不足时不显示误导百分比。
- 主题扩展为青绿、海蓝、信号青、靛蓝、紫藤、玫瑰、珊瑚、琥珀、石墨 9 套；工具识别色独立保持稳定。
- 费用统一称“API 标准价估算”：优先使用来源费用，否则按精确模型和四类 Token 使用版本化公开价；未知部分显示未计价和覆盖率。Anthropic 缓存写缺少 TTL 时，只保留该组件未计价，不丢弃同一记录里可确定的输入、输出和缓存读费用。
- 分享图改用 TokenFleet 标识和水平刻度，并区分渲染、编码、剪贴板与写文件失败。
- 管理员可从成员列表或详情页直接为已有成员补发 60 分钟一次性设备码；不会新建重复成员、占批次名额、恢复或改变旧码。
- App 与 Helper 均构建为 `arm64 + x86_64`，Intel Mac 与 Apple Silicon 使用同一 universal App。

## 本地自动化证据

| 范围 | 结果 | 证据摘要 |
| --- | --- | --- |
| 服务端 | 通过 | `147 passed, 15 skipped`；跳过项为未配置 PostgreSQL 的 smoke。补发回归验证成员数、批次名额、旧码状态不变，明文码不落库。 |
| Web 单元 | 通过 | Node `50 / 50`；补发请求固定为既有 `user_id + 60 分钟`，无多余字段。 |
| 静态浏览器 | 通过 | 1440、820、390 px；7 条管理路由、空／长模型／最大数、401/403/503、键盘焦点、reduced motion、对比度；console/page error 为 0。 |
| 社群浏览器竞态 | 通过 | 排行、分享、补发一次性码和退出的跨路由慢响应均不泄露旧弹窗或原始码。 |
| 临时真实联调 | 通过 | 临时 SQLite 完成批次领取、成员补发、3 台设备、极值 Token、公开榜、成本、错误登录、退出清理；浏览器 console/page error 为 0，完成后服务与临时状态均删除。 |
| Swift 完整门禁 | 通过 | 源码 typecheck、网络/Keychain/同步状态机、Codex/Claude/CC Switch fixture、费用覆盖、迁移、本地化和语言刷新通过。当前 Command Line Tools 没有 XCTest 模块，真实 XCTest 留给 PR macOS CI。 |
| universal 构建 | 通过 | `TokenFleet` 与 `Contents/Helpers/TokenFleetHelper` 均由 `lipo` 确认为 `x86_64 arm64`；版本 `0.1.0-beta.8`；新 ICNS 有效。 |
| 分发身份 | 通过 | 独立构建、固定 Bundle/Team/update origin、恶意版本、重复发布目录、签名失败原子性、旧发布物保留门禁通过。 |
| 源码安装与回滚 | 通过 | fail closed、ad-hoc／社群模式、灾难与 staged rollback、显式降级、卸载以及不修改正式 `dist` 通过；本机不支持隔离 legacy file Keychain 的项目明确跳过。 |
| Windows 跨平台 | 通过／真机待跑 | macOS 上 `26 passed, 2 skipped`；两个跳过项只在真实 Windows 验证 DPAPI round-trip 与计划任务。CI 已增加安装、同源升级、preview、status 与卸载。 |

## schema 与后端影响

- 连续活跃由本地既有 `DailyUsage` 日桶计算，beta.8 不需要新增服务端 API、数据库列或迁移。
- 设备码补发复用既有 enrollment token 表与端点，只增加安全后台流程和回归测试，不改变 schema。
- 9 套主题、相对节奏、定价目录、菜单栏规则和分享修复均为客户端变化。
- Kimi、DeepSeek、Cursor、Gemini CLI 的原生采集没有在缺少安全真实样本时强行启用；可行性与隐私边界见 `TOKENFLEET_BETA8_COLLECTOR_MATRIX.md`。CC Switch 只有出现真实成功代理行才显示相应实验来源。

## PR / 发布前仍然阻断

1. PR 的 macOS runner 必须跑真实 `swift test --parallel`，包含主题对比度、费用、分享编码、相对节奏和连续活跃 XCTest。
2. PR 的 PostgreSQL 17 服务必须让 15 条 smoke 全部通过。
3. Windows runner 必须完成真实 DPAPI、计划任务、安装、同源升级、preview/status 和卸载；真实 Windows 10/11 成员机仍需发布前人工 E2E。
4. 自动更新仍缺真实 Apple Team ID、Developer ID 签名、公证凭据和独立 HTTPS 更新源。beta.7 必须手工迁移一次；没有这些条件不得声称 beta.8 能自动推送。
5. 生产服务、更新源切换、成员通知、DMG 发布与合并均未执行。执行前必须再次用中文说明影响范围和回滚，并等待奥哥单独确认。
