# TokenFleet macOS 发布手册

本手册只描述未来可选的 Developer ID + 公证 DMG 分发，不是当前社群成员的安装前提。当前版本采用 `docs/INSTALL.md` 中的固定 tag 免费源码安装；本脚本只发布独立的 TokenFleet，不会下载、安装、退出或覆盖上游 TokenStep。若未来启用公开 DMG，才需要自己的 Apple Developer ID、公证凭据、固定社群 HTTPS 服务、更新 API 和 HTTPS 下载地址；这些外部条件未配置前不得把 DMG 路径称为“已上线”。

当前公开源码 ZIP 必须从已复核提交创建并经过仓库门禁；不要使用 Finder 临时压缩：

```bash
git archive --format=zip --prefix=TokenFleet-source/ \
  --output=/tmp/TokenFleet-source.zip HEAD
TOKENFLEET_PRIVATE_MARKERS_FILE=/absolute/private/markers.txt \
  python3 script/verify_public_source_archive.py /tmp/TokenFleet-source.zip
shasum -a 256 /tmp/TokenFleet-source.zip
```

验证器会拒绝未标 UTF-8 的中文文件名、路径穿越、凭据/数据库文件名、个人部署标记、
私钥头和异常大文件。CI 对每个提交执行同一门禁；发布附件仍需重新核对 SHA-256。

## 1. 发布前提

- Apple Developer Program 账号；
- 钥匙串中可用的 `Developer ID Application` 证书；
- Xcode Command Line Tools 与 `notarytool`；
- 发布者控制的 Bundle ID，默认开发值为 `com.lingdong.TokenFleet`，正式值可用 `TOKENFLEET_BUNDLE_ID` 覆盖；
- 证书对应的 10 位 Apple Developer Team ID；
- 发布者控制的 HTTPS 更新 API；
- 与 Web/API 同源的唯一 canonical HTTPS 社群地址（仅 origin，无尾 `/`、path、query 或 fragment）；
- 发布者控制的 HTTPS 下载地址；
- 正式版本号、变更说明和回滚包。

检查签名身份：

```bash
security find-identity -p codesigning -v
```

建议把公证凭据写入 macOS 钥匙串，不写仓库、不贴聊天：

```bash
xcrun notarytool store-credentials tokenfleet-notary \
  --apple-id "you@example.com" \
  --team-id "TEAMID"
```

命令会在终端中安全提示输入 app-specific password；不要把密码放到参数、环境示例、shell history 或日志中。CI 使用 App Store Connect API 私钥文件、Key ID 和 Issuer ID，不使用明文 Apple ID 密码参数。

## 2. 更新与社群服务合同（fail closed）

App 只从 `Info.plist` 的 `TokenFleetUpdateAPIURL` 检查更新。发布脚本要求显式提供 `TOKENFLEET_UPDATE_API_URL` 和 `TOKENFLEET_TEAM_ID`；缺失、非 HTTPS、指向上游 TokenStep 或 Team ID 非 10 位大写字母数字时直接失败。开发包缺少更新 URL 或 Team ID 时，更新检查会明确停止，不会回退到任何第三方源。

当前客户端接受 GitHub Release 风格 JSON，至少包含：

```json
{
  "tag_name": "v0.1.0",
  "name": "TokenFleet 0.1.0",
  "body": "release notes",
  "draft": false,
  "prerelease": false,
  "html_url": "https://updates.example.com/tokenfleet/0.1.0",
  "assets": [
    {
      "name": "TokenFleet-0.1.0.dmg",
      "browser_download_url": "https://downloads.example.com/TokenFleet-0.1.0.dmg",
      "size": 12345678
    }
  ]
}
```

DMG 文件名必须以 `TokenFleet-` 开头。客户端在安装前还会检查 App 名、Bundle ID、签名、公证以及签名中的 `TeamIdentifier`；Helper 安装前后都会再次核对固定 Team ID，并且只接受名为 `TokenFleet.app` 的目标。仅仅“同名 + 同 Bundle ID + 另一张 Developer ID 证书”不能通过更新门禁。

App 只从签名范围内的 `Info.plist` key `TokenFleetCommunityServerURL` 读取社群
origin。构建脚本只接受至少含一个点的 ASCII 小写 DNS hostname 与精确 canonical
HTTPS origin；拒绝 raw IP、单标签、localhost/数字 IP 别名、HTTP、userinfo、尾
`/`、path、query、fragment、百分号编码、默认 `:443` 和非法 DNS label。
正式发布缺失 `TOKENFLEET_COMMUNITY_SERVER_URL` 时直接失败；运行时不读取环境变量、
UserDefaults、旧设置或成员输入来覆盖该地址。

## 3. 本地构建预检（不启动）

```bash
TOKENFLEET_BUNDLE_ID="com.yourcompany.TokenFleet" \
TOKENFLEET_TEAM_ID="ABCDE12345" \
TOKENFLEET_UPDATE_API_URL="https://updates.example.com/tokenfleet/latest" \
TOKENFLEET_COMMUNITY_SERVER_URL="https://tokenfleet.example.com" \
TOKENFLEET_CREDENTIAL_BACKEND="file-login-v1" \
TOKENFLEET_EXTERNAL_SIGNING_STAGE="1" \
./script/build_swiftui_and_run.sh --no-launch
```

输出必须是：

```text
TokenStepSwift/dist/TokenFleet.app
```

运行独立身份门禁：

```bash
./script/verify_tokenfleet_desktop_identity.sh
```

它会在独立的 `mktemp` 输出目录重新构建但不启动 App，并验证 App/可执行文件/Helper/
Bundle ID/App Support/LaunchAgent/通知/锁/更新源都不会碰 TokenStep；成功或失败都不
覆盖 `TokenStepSwift/dist/TokenFleet.app`。

## 4. 签名、公证和打包

发布脚本强制执行安全版本号校验、Developer Team ID 固定、Developer ID 签名、ZIP 公证、App stapling、DMG 签名与公证、Gatekeeper 校验和 SHA-256 生成；没有公证凭据时不会产出“正式包”。App 直接构建到独立临时目录，签名前用 `plutil` 与 `PlistBuddy` 精确核对名称、版本、Bundle ID、更新源、Team ID 和固定社群 origin，签名后及 ZIP 解包后再次核对。所有产物先在 `release/` 内的隐藏临时目录完成，全部门禁通过后才以同文件系统 rename 发布；中途失败不覆盖本地 `dist`，不留下看似正式的 ZIP/DMG，也不删除旧版本回滚包。

```bash
TOKENFLEET_VERSION="0.1.0" \
TOKENFLEET_BUNDLE_ID="com.yourcompany.TokenFleet" \
TOKENFLEET_TEAM_ID="ABCDE12345" \
TOKENFLEET_UPDATE_API_URL="https://updates.example.com/tokenfleet/latest" \
TOKENFLEET_COMMUNITY_SERVER_URL="https://tokenfleet.example.com" \
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TOKENFLEET_NOTARY_PROFILE="tokenfleet-notary" \
./script/package_release.sh
```

也可使用 App Store Connect API 密钥；在上一条完整发布命令中保留版本、Bundle ID、
Team ID、更新源、社群 origin 和签名身份，只把
`TOKENFLEET_NOTARY_PROFILE="tokenfleet-notary"` 替换为以下三项。私钥文件只通过路径
传入，脚本不会把私钥内容放进命令行参数：

```bash
TOKENFLEET_NOTARY_KEY="/secure/path/AuthKey_ABC123DEFG.p8" \
TOKENFLEET_NOTARY_KEY_ID="ABC123DEFG" \
TOKENFLEET_NOTARY_ISSUER="00000000-0000-0000-0000-000000000000"
```

成功后生成：

```text
release/TokenFleet-0.1.0/TokenFleet-0.1.0.zip
release/TokenFleet-0.1.0/TokenFleet-0.1.0.dmg
release/TokenFleet-0.1.0/TokenFleet-0.1.0-SHA256SUMS
```

App 内同时保留 `LICENSE.txt` 和 `NOTICE.txt`，声明源自 MIT 许可的 TokenStep；产品名独立不代表上游作者背书。

如使用 GitHub Actions，必须先由负责人确认版本号并创建指向待发布提交的 `v<版本>` tag，再从该 tag 手动触发 `TokenFleet Release`。工作流会先复用完整 CI（Server、PostgreSQL、Web 浏览器、live E2E、Swift 与桌面身份），随后读取仓库 Variables `TOKENFLEET_BUNDLE_ID`、`TOKENFLEET_TEAM_ID`、`TOKENFLEET_UPDATE_API_URL`、`TOKENFLEET_COMMUNITY_SERVER_URL`，以及 Actions Secrets `CERTIFICATE_P12_BASE64`、`CERTIFICATE_PASSWORD`、`KEYCHAIN_PASSWORD`、`CODE_SIGN_IDENTITY`、`NOTARY_KEY_P8_BASE64`、`NOTARY_KEY_ID`、`NOTARY_ISSUER_ID`。公证私钥仅在 runner 临时目录以 `0600` 文件存在；无论步骤成功或失败，临时私钥、证书文件和签名钥匙串都会清理。tag、输入版本或当前提交任一不一致都会停止，不会自动从分支创建未知 tag。

## 5. 发布前复核

```bash
xcrun stapler validate release/TokenFleet-0.1.0/TokenFleet-0.1.0.dmg
```

```bash
cd release/TokenFleet-0.1.0
shasum -a 256 -c TokenFleet-0.1.0-SHA256SUMS
```

`package_release.sh` 已在隔离临时构建中执行 plist 合同、App/Helper/DMG 签名、Gatekeeper 和 stapler 校验；它不会读取或覆盖 `TokenStepSwift/dist/TokenFleet.app`。该 `dist` 路径只属于未签名的手工开发构建，不要把它下发给成员。

未来 DMG 发布者还必须在一台没有开发环境的干净 Mac 上独立验收：

1. 从发布地址下载 DMG 与 SHA256SUMS，先执行 `shasum -a 256 -c`；
2. 只读挂载 DMG，分别执行 `codesign --verify --deep --strict`、`spctl --assess --type execute` 与 `xcrun stapler validate`；
3. 核对 App 的 Bundle ID、TeamIdentifier、版本和 `TokenFleetCommunityServerURL` 与该发布版本完全一致；
4. 将 App 拖入 `/Applications`，完成首次启动、一次性设备登记、历史补传告知、开机启动和同步；
5. 从上一版升级到本版，确认原凭据可用；再用保留的上一版 DMG 手工回滚，确认本地数据仍在且不会操作 TokenStep。

当前成员使用的免费源码安装流程见 `docs/INSTALL.md`；上面的 DMG 流程只在未来真的启用 Developer ID 分发时执行。签名脚本通过不能替代真实设备验收。

## 6. 发布与回滚

1. 从 `release/TokenFleet-<version>/` 上传 ZIP、DMG、SHA256SUMS 到发布者控制的下载地址；
2. 核对公开 SHA-256 与本地产物一致；
3. 最后更新发布者控制的 latest API，不要先让客户端看到未上传完整的版本；
4. 小范围灰度，确认团队同步和每人独立的官方 OpenToken 常驻上榜链路；
5. 保留上一个已签名、公证版本及其 checksum；
6. 客户端只接受高于当前版本的自动更新，不能靠把 latest API 指回旧版本来降级；需要回滚时，由管理员从保留的上一版 checksum 校验过的已签名、公证 DMG 手动安装，并先在一台测试机验证。回滚不操作 TokenStep，也不删除两者的 App Support。

Apple 官方说明：[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)。
