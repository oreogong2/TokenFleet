# TokenFleet beta.8 Windows 回归说明

成员反馈“Windows 能正常使用”与当前实现一致：Windows 端不是 macOS App 的兼容层，而是一套独立 Python CLI。它直接读取 Windows 用户目录下 Codex 与 Claude Code 的本地 JSONL usage 事件，并只读 ZCode 独立 SQLite `model_usage` 完成行，生成与 macOS 相同的 `date × tool × model` 四类 Token 聚合，再使用同一套一次性设备码和 HMAC 协议同步到服务端。ZCode 支持基于 Windows 11 / ZCode 0.16.5 的真实数据底座反馈补入；采集器不打开 transcript，也不读取 Coding Plan 额度。

## 为什么它能工作

- Codex 和 Claude Code 在 Windows 仍使用用户目录中的结构化 usage 事件，字段口径与跨平台采集器一致。
- ZCode 在 `%USERPROFILE%\.zcode\cli\db\db.sqlite` 提供独立逐请求用量表，可在不读取会话正文的前提下完成精确聚合。
- 设备凭据使用 Windows CurrentUser DPAPI 加密，不依赖 macOS Keychain。
- 自动同步使用当前用户、LIMITED 权限的 Task Scheduler，每 6 小时运行一次；不是系统服务。
- 服务端只看协议、设备签名和聚合桶，不要求客户端是 macOS。
- 安装目录固定在 `%LOCALAPPDATA%\TokenFleet`，社群 HTTPS 源被完整性摘要固定，重复安装不能静默换源。

## beta.8 新增回归门槛

Windows CI 除已有协议、采集器、安装安全单元测试外，还在真实 Windows runner 上执行：

1. DPAPI 加密/解密与落盘密文检查；
2. LIMITED 定时任务创建、查询与清理；
3. PowerShell 源码安装；
4. 未连接状态下的 `preview --json` 与 `status --json`；
5. 同源覆盖升级；
6. 卸载并确认安装目录清理。

仍需发布前真人硬件验收：用反馈成员的 Windows 11 / ZCode 0.16.5 执行更新后 `preview --json` 与真实同步验收；Windows 10、中文用户路径、睡眠后计划任务、真实一次性码、生产只读同步和旧版覆盖升级仍在完整矩阵内。没有完成真人矩阵前，文案保持 beta，不写“全面支持”。
