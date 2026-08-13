# TokenFleet macOS App

TokenFleet 的原生 macOS 客户端。Swift target/module 为兼容上游仍叫 `TokenStepSwift`，对外 App、可执行文件、Helper、Bundle ID、数据目录和更新源全部是独立 TokenFleet 身份。

Use the root scripts instead of running this directory directly:

```bash
./script/build_and_run.sh --verify
./script/build_swiftui_and_run.sh --no-launch
./script/package_release.sh
```

The installed app stores user data under:

```text
~/Library/Application Support/TokenFleet
```

## Optional community leaderboard sync

Team sync sends only exact daily aggregates (date, timezone, tool, model, and
four Token counters). It never sends hostnames, serial numbers, local paths,
prompts, code, or session content. Device secrets must be stored in macOS
Keychain; builds without an enabled secure credential store keep registration
disabled instead of falling back to plaintext storage.

Each member/device enrollment is independent of Codex or Claude login identity.
One member can enroll multiple Macs; the server shows and sums devices without
cross-device deduplication. Shared AI provider accounts are not recommended.
Third-party ranking or community credentials remain separate personal connections.

Public releases embed one canonical community HTTPS origin in the signed
`Info.plist`. Members paste only a one-time enrollment code; neither runtime
environment variables nor local settings can replace that server. Once enrolled,
the popover opens only the same origin's fixed `/rank` page and never adds a
credential, query, or automatic-login parameter.

The current collector's accounting day is fixed to `Asia/Shanghai`. Team sync
uploads that local accounting date and timezone unchanged; it does not regroup
history into an organization timezone. Configurable accounting timezones need a
versioned migration and must not silently recut existing history.
