# Changelog

## 0.1.0-beta.8 - Unreleased

### Desktop identity, accuracy, and recovery

- Replaced the inherited multi-ring fitness skin with one clean TokenFleet goal
  ring while keeping “100M a day”, uncapped goal percentages and lap context,
  familiar navigation, full tool/model detail, quota views, and all three
  share-card workflows.
- Added relative pace, current streak, contextual community rank, a discoverable
  community action, and nine accessible themes with stable tool identity colors.
- Replaced the unrelated external rank card with TokenFleet's device-authenticated
  community rank context; private profiles remain unranked and no schema migration
  is required.
- Fixed the single-screen entry to macOS's native, compact right-side menu-bar
  item so TokenFleet cannot cover Apple or third-party status items. Legacy
  notch/automatic placement values are normalized to the native menu bar; users
  with enough space may opt into the ring plus today's Token count.
- Added an AppKit reopen bridge so a running TokenFleet can always restore its
  single main window from Applications or Spotlight when macOS hides the native
  menu-bar ring on a crowded built-in display. Early reopen requests are held
  until app state binds, and a minimized main window is explicitly restored.
- Added a versioned public API price catalog with model- and component-specific
  rates, source-cost priority, pricing coverage, and explicit unpriced handling.
  Ambiguous Anthropic cache-write TTLs no longer erase the known cost components.
- Kept WorkBuddy unsupported because its observed project logs colocate usage with
  conversation/tool content; beta.8 does not open those files. Kimi and DeepSeek
  remain explicitly experimental only when real CC Switch proxy rows exist.
- Reworked image export around explicit render, PNG/JPEG encoding, clipboard,
  and file-write failures, and replaced the inherited icon with a TokenFleet
  progress-ring icon.
- Added a safe existing-member device-code reissue path that keeps the member,
  invitation-batch count, and consumed-code audit rows unchanged, expires every
  older live unused code in the same member-locked transaction, and never stores
  the one-time plaintext code.
- Built the macOS App and helper as universal arm64 + x86_64 binaries and expanded
  CI with a native `macos-15-intel` lifecycle gate; Windows CI exercises install,
  same-origin upgrade, preview, status, DPAPI, scheduled-task, and uninstall paths.
  Windows uninstall is idempotent when the scheduled task is already absent and
  still removes it when present.
- The headless Intel runner validates native x86_64 logic, collectors, builds,
  and source lifecycle; because it exposes no Metal device, the same x86_64
  share-card render/copy/save path is executed under Rosetta on a GPU-capable
  Apple runner instead of being silently skipped.
- Documented strict feasibility and privacy boundaries for Kimi Code, DeepSeek,
  Cursor, and Gemini CLI; only observed CC Switch proxy rows are labeled as
  experimental support. Supported source logs are processed read-only on the
  device; prompt, response, and code fields are not included in statistics or
  uploaded, while local paths and request/session identifiers may be retained
  only as incremental and deduplication metadata. The privacy card counts only
  sources that actually contributed usage, not disabled, missing, or deliberately
  unsupported collectors.
- Added prerelease-channel rules and an explicit beta.7 migration plan. Existing
  source installs can manually upgrade from a reviewed, pinned commit while
  retaining the same per-Mac source-signing identity; this path does not require
  a paid Apple Developer account. A Developer ID signed/notarized package and
  pinned HTTPS automatic-update feed remain optional future distribution work.

## 0.1.0-beta.7 - 2026-08-11

### Community experience refinement

- Rebuilt the public leaderboard as a responsive warm-paper interface with
  direct period, accounting, tool, and model filters and clearer participant
  counts.
- Consolidated sharing into one accessible poster preview with global Top 10
  context, an extra selected-member summary when launched from a member profile,
  a scannable leaderboard QR code, and save/close actions.
- Added mouse-hover and keyboard-focus values to Web trend charts, and simplified
  the Mac client around Today, History, Community, and Settings with explicit
  daily-goal progress and 7/30/90-day/all-time history.
- Added a privacy-safe first-50 feedback checklist for measuring unsupported
  tools without collecting prompts, conversations, code, paths, or secrets.

## 0.1.0-beta.6 - 2026-08-11

### Invitation claim boundary hardening

- Rejected public nicknames whose NFKC/casefold identity exceeds the database
  limit during request validation, before participant or token writes.
- Gave invitation-batch claims a dedicated process-local limiter of 10 attempts
  per verified client IP per minute, independent of the 60/minute device
  enrollment bucket.
- Added direct-client, trusted-proxy, malformed-chain, UDS, SQLite, PostgreSQL,
  and production-configuration regressions for the two boundary fixes.

## 0.1.0-beta.5 - 2026-08-11

### Bounded self-service invitation batches

- Added administrator-created invitation batches capped at 50 people and 24
  hours, with hashed tokens, explicit close, and one uniform unavailable state.
- Added organization-scoped NFKC/casefold nickname uniqueness enforced by a
  database index, not a read-then-write check.
- Made batch claim one PostgreSQL row-locked transaction that creates the
  participant, a 60-minute personal enrollment token, and the capacity count.
- Added `/join/batch` with fragment-only token capture, immediate URL scrubbing,
  closure-only secrets, explicit public-profile consent, and no account system.
- Moved private public-source markers out of repository source and added
  fail-closed ZIP regression fixtures for traversal, encoding, size, and secret
  markers.

## 0.1.0-beta.4 - 2026-08-10

### 50-person invited beta

- Added application- and Nginx-level enrollment rate limits and a real
  PostgreSQL capacity regression for 50 independent participants.
- Prevented source reinstall and rollback from silently disabling community
  sync or changing the pinned community origin.
- Scrubbed unsupported path-shaped join codes, cleared private in-memory Web
  state at logout, and warned when a newly private price makes future public
  usage explicitly unpriced.
- Hardened Codex quota process lookup and added a fail-closed public source ZIP
  verifier for paths, UTF-8 filenames, size limits and sensitive markers.
- Replaced staged eligibility with a same-day 50-person operations checklist;
  each member and device still receives an independent one-time code.

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
