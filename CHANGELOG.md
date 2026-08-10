# Changelog

## 0.1.0-beta.3 - 2026-08-10

### Documentation

- Disclosed the optional, default-off Claude quota integration that reads the
  Claude Code Keychain credential only to query Anthropic's usage endpoint.
- Documented the Codex quota child process and the read-only external Token
  Rank identity file separately from TokenFleet community synchronization.
- Marked every Windows installation entry point as an experimental source
  candidate pending real Windows 10/11 E2E validation.

## 0.1.0-beta.2 - 2026-08-10

- Fixed macOS CI portability by using the active Xcode SDK path directly.
- Made reduced-motion rendering deterministic across macOS and Linux Chromium.
- Kept the public source preflight strict without requiring the private maintainer release workflow.
- Ran the real macOS XCTest suite and all GitHub CI jobs successfully before tagging.

## 0.1.0-beta.1 - 2026-08-10

### 首个邀请测试版

- 提供 Apple Silicon、macOS 14+ 的 TokenFleet 原生菜单栏客户端；
- 本地统计 Codex、Claude Code，并保留 macOS 上的实验性 CC Switch 采集；
- 用固定 HTTPS 社群地址、每设备一次性码和本机钥匙串凭据完成安全登记；
- 支持多设备日桶同步、公开社群榜、个人公开页和本地生成的排行榜分享图；
- 提供公开源码安装、升级、回滚、卸载和失败关闭验证脚本；
- 提供 TokenFleet 服务端、Web 管理后台、匿名公榜和阿里云单机部署模板。

### 已知限制

- 当前 Mac 版本从源码在每台设备本地构建和签名，没有 Developer ID 或 Apple 公证；
- 当前没有静默自动更新，升级需切换到维护者公布的完整 commit SHA 后重新运行安装脚本；
- Windows 客户端仍属于实验性源码，未完成真实 Windows 10/11 设备验收，本轮不对外承诺；
- 公开估算费用依赖管理员配置并公开标准价格，未定价用量会明确显示为未定价；
- 部分现代 macOS 环境不允许创建隔离的 legacy file Keychain，自动门禁会明确跳过该项，
  首批真实 Mac 仍需逐台验证首次登记、升级后读取和清除凭据。
