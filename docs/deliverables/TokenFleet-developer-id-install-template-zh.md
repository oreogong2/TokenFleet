# TokenFleet 未来 Developer ID / DMG 安装模板

> 这不是当前免费源码版的成员说明。当前安装请使用 `docs/INSTALL.md`；只有未来另行启用 Developer ID / 公证 DMG，且管理员补齐正式版本、维护者 HTTPS 下载地址、SHA-256、Bundle ID、Apple Team ID 后，才能使用本模板。

## 1. 每人、每台设备的身份规则

- 每位成员使用自己的 Codex / Claude 账号，不共用 AI 供应商账号。
- TokenFleet 以“昵称参赛者 + 设备”记账，不要求成员注册、登录或绑定微信；同一参赛者可登记多台 Mac 或 Windows 设备，每台设备都要单独生成一次性接入码。
- 其他第三方排行榜或社区服务是独立链路。仍需使用的人继续保留自己的连接，不把其 URL、访问令牌或 secret 填进 TokenFleet。
- 灰度期 TokenFleet 与 TokenStep 可以共存；正式试运行通过前不要卸载 TokenStep。

## 2. macOS 终端下载安装

把下面的 `<版本>`、`<下载地址>`、`<SHA-256>`、`<Bundle ID>`、`<Apple Team ID>` 替换成管理员提供的公开值；另向管理员核对固定社群 HTTPS 地址。不要使用 `curl | sh`，也不要把一次性设备接入码写进命令行。

```bash
mkdir -p "$HOME/Downloads/TokenFleet-install"
```

```bash
curl --fail --location --proto '=https' --tlsv1.2 \
  --output "$HOME/Downloads/TokenFleet-install/TokenFleet-<版本>.dmg" \
  '<下载地址>/TokenFleet-<版本>.dmg'
```

```bash
printf '%s  %s\n' '<SHA-256>' \
  "$HOME/Downloads/TokenFleet-install/TokenFleet-<版本>.dmg" \
  | shasum -a 256 -c -
```

只有看到 `OK` 才继续：

```bash
hdiutil verify "$HOME/Downloads/TokenFleet-install/TokenFleet-<版本>.dmg"
```

```bash
mkdir -p "$HOME/Downloads/TokenFleet-install/mount"
hdiutil attach -nobrowse -readonly \
  -mountpoint "$HOME/Downloads/TokenFleet-install/mount" \
  "$HOME/Downloads/TokenFleet-install/TokenFleet-<版本>.dmg"
```

```bash
codesign --verify --deep --strict --verbose=2 \
  "$HOME/Downloads/TokenFleet-install/mount/TokenFleet.app"
spctl --assess --type execute --verbose=2 \
  "$HOME/Downloads/TokenFleet-install/mount/TokenFleet.app"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$HOME/Downloads/TokenFleet-install/mount/TokenFleet.app/Contents/Info.plist"
codesign -dvv "$HOME/Downloads/TokenFleet-install/mount/TokenFleet.app" 2>&1 \
  | grep '^TeamIdentifier='
/usr/libexec/PlistBuddy -c 'Print TokenFleetCommunityServerURL' \
  "$HOME/Downloads/TokenFleet-install/mount/TokenFleet.app/Contents/Info.plist"
```

输出的 Bundle ID、Team ID 和固定社群地址必须分别等于管理员提供的值。首次安装再执行：

```bash
test ! -e '/Applications/TokenFleet.app'
ditto "$HOME/Downloads/TokenFleet-install/mount/TokenFleet.app" \
  '/Applications/TokenFleet.app'
hdiutil detach "$HOME/Downloads/TokenFleet-install/mount"
open '/Applications/TokenFleet.app'
```

若 `test` 失败，说明电脑上已有 TokenFleet，不要直接覆盖；请使用 App 内更新，或联系管理员。

## 3. 登记这台 Mac

1. 管理员只填昵称创建参赛者，或选择已有参赛者，为这台 Mac 生成专属接入链接。
2. 成员打开链接，阅读上传/公开字段后主动复制一次性码。
3. 打开 TokenFleet → 设置 → 社群榜同步；App 已固定服务器，只粘贴码并确认。
4. 确认后会立即上传当前可验证的历史日聚合，并持续后台同步。
5. 第二台 Mac 必须为同一参赛者重新生成一个码，不能复制第一台电脑的配置或凭据。

## 4. Windows 10/11 安装与登记

重要：Windows 客户端目前是实验性源码候选。跨平台自动化已通过，但真实 Windows
10/11 上的 DPAPI、计划任务、升级、卸载和真实同步 E2E 尚未验收。当前不向社群成员
承诺 Windows 正式可用；本节仅供后续真机验收和技术预览。

从经过复核的源码发布包进入仓库根目录，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clients\windows\install.ps1 `
  -CommunityServer https://token.ipwriter.com
tokenfleet connect
```

`https://token.ipwriter.com` 仅作为客户端安装参数，不是网页入口，请勿在浏览器打开裸域名；成员网页只使用 `/install`、`/rank` 或完整批次邀请链接。

安装时固定社群地址，升级必须保持一致，`connect` 不接受 `--server` 并会隐藏一次性码输入。连接后，Windows 当前用户 DPAPI 保护设备 secret，计划任务自动同步；`tokenfleet open-rank` 可打开公榜。Windows 采集 Codex / Claude Code，并在 ZCode 独立用量库存在时只读 `model_usage` 完成行；支持安全连接、自动同步和上榜，但暂不采集 CC Switch，也不是 macOS 完整桌面明细界面的复刻。

## 5. 何时可以卸载 TokenStep

至少满足以下条件：正式包已签名和公证；社群同步、多设备、费用和自动更新均通过；50 人邀请测试已连续运行至少 14 天且无 P0/P1；成员仍需使用的第三方服务状态正常。之后先在 TokenStep 设置中关闭开机启动并退出，再把 `TokenStep.app` 移到废纸篓；灰度期保留其 App Support 数据，方便回滚。
