# TokenFleet 社群成员安装与多设备登记

状态：当前 Mac 与 Windows 均从经过复核的固定源码 tag 安装。现阶段不提供 Developer ID、公证 DMG 或 App Store 版本；上游 TokenStep 的安装包不是 TokenFleet。

## 1. 三套身份不要混在一起

- TokenFleet 的社群身份是“管理员创建的昵称参赛者 + 一次性设备接入码”，不是会员账号，也不是 Codex/Claude 账号。
- 每位成员建议使用自己独立的 Codex、Claude 账号；不建议多人共用一个 AI 供应商账号，否则费用归属和权限撤销都会变得不清楚。TokenFleet 不上传这些供应商账号身份。
- 同一参赛者可以登记多台 Mac 或 Windows 设备。每台设备使用各自的接入码登记，后台按设备分别保存，再对该参赛者求和；v1 不做跨设备去重。
- 生财 OpenToken 是另一条独立链路。需要上生财榜的成员必须使用自己的个人接入，不能共用，也不要把 OpenToken URL 或 secret 填进 TokenFleet 团队连接。

## 2. macOS：安装前向管理员拿三项公开信息

管理员通过可信的私聊渠道提供：

1. 官方源码仓库地址；
2. 已复核的版本标签和对应完整 commit SHA（实际安装以 SHA 为准）；
3. 固定社群 HTTPS 地址，例如 `https://tokenfleet.example.com`。

这些都不是设备邀请码或 device secret。一次性邀请码不要写进命令行、截图或群聊。

## 3. macOS：固定 commit 源码安装

要求 macOS 14+、Apple Silicon 和 Xcode Command Line Tools。不要使用 `curl | sh`，也不要从聊天附件运行散装脚本。

```bash
git clone <official-repo-url> TokenFleet
cd TokenFleet
git checkout --detach <reviewed-commit-sha>
test "$(git rev-parse HEAD)" = "<reviewed-commit-sha>"
./script/install_from_source.sh \
  --enable-community-sync \
  --community-server https://<community-domain>
```

脚本只接受公开的固定社群 origin，不接受或打印一次性码。它会：

- 在本机编译 TokenFleet；
- 为这台 Mac 创建或复用独立的本机自签 code-signing identity；
- 将私钥以不可导出形式保存在登录钥匙串，且只授权系统 `codesign` 使用；
- 只把这台 Mac 生成的精确证书加入当前用户的 `codeSign` 信任；不会加入系统级
  信任，也不会信任 TLS、邮件、安装包或软件更新；
- 不声明 iCloud/共享钥匙串 entitlement；
- 校验 Bundle ID、固定 origin、签名证书、designated requirement 和凭据后端；
- 原子安装到 `~/Applications/TokenFleet.app`，升级时保留上一版用于回滚。

源码自签版本没有 Apple 公证信誉，只适合成员从管理员指定并复核的完整 commit SHA 在自己机器上构建。每台 Mac 必须独立安装，不能复制另一台机器的 App 或签名 identity。

纯本地统计（不启用社群同步）：

```bash
./script/install_from_source.sh
```

升级、回滚与卸载：

```bash
git fetch --tags
git checkout --detach <new-reviewed-commit-sha>
test "$(git rev-parse HEAD)" = "<new-reviewed-commit-sha>"
./script/install_from_source.sh --enable-community-sync \
  --community-server https://<community-domain>
./script/rollback_source_install.sh
./script/uninstall_source_install.sh
```

卸载脚本把 App 移入废纸篓，默认保留本地统计、回滚包、社群凭据和本机签名 identity，避免误删。身份丢失或更换时必须重新登记设备。

## 4. macOS：一次性设备登记

1. 管理员只填昵称创建参赛者，或选择已有参赛者，为这台 Mac 生成专属接入链接；
2. 成员打开链接，阅读上传与公开范围。页面会立即从地址栏移除短期码，不会自动连接客户端；
3. 成员主动复制一次性码，打开 TokenFleet → 设置 → 社群榜同步；
4. App 已固定唯一社群服务器，只需在安全输入框粘贴码并点“确认并开始同步”；
5. 确认后会立即上传当前仍可验证的历史日聚合，并持续后台同步；不会上传 prompt、代码或路径；
6. 接入码默认 60 分钟有效、最长 24 小时，使用一次即失效；客户端后续保存的是独立设备凭据；
7. 第二台 Mac 必须为同一参赛者重新生成一个码。不要复制第一台 Mac 的设置目录或设备凭据。

换机或重装时，管理员为同一成员重新生成邀请码。只要本机保留非敏感安装 ID，服务端会复用设备身份并轮换 secret；跨成员不能转移设备历史。

## 5. Windows 10/11：源码安装与登记

Windows 首版需要 Python 3.10 或更高版本。下载或克隆经过复核的 TokenFleet 发布版本，进入仓库根目录后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clients\windows\install.ps1 `
  -CommunityServer https://<community-domain>
```

打开新终端，为这台设备使用一个新的单次接入码：

```powershell
tokenfleet connect
```

社群 HTTPS origin 在安装时固定，后续升级必须传入相同值；`connect` 不接受 `--server`。接入码通过隐藏输入读取，不提供会进入命令历史或进程列表的 `--code` 参数。连接成功后，当前用户 DPAPI 保护 device secret，计划任务每六小时自动同步；也可运行：

```powershell
tokenfleet preview
tokenfleet status
tokenfleet sync
tokenfleet open-rank
```

Windows 首版采集 Codex 与 Claude Code 本地 JSONL，支持安全连接、自动同步和上榜；暂不采集 CC Switch，也没有与 macOS 原生 App 等同的完整桌面历史与统计界面。完整说明与卸载方式见 `clients/windows/README.md`。

## 6. 与 TokenStep 短期共存

TokenFleet 使用独立的：

- `~/Applications/TokenFleet.app`；
- 可执行文件 `TokenFleet` 和 Helper `TokenFleetHelper`；
- Bundle ID、LaunchAgent、通知名和单实例锁；
- `~/Library/Application Support/TokenFleet`；
- 源码版不启用更新 API；未来若另行发布 Developer ID 公证包，只能使用维护者控制的独立更新 API。

它不会读取或写入 `~/Library/Application Support/TokenStep`，也不会退出、覆盖或自动更新 TokenStep。因此灰度期两者可以同时运行；代价是两套菜单栏和重复的本地只读采集，会多占少量资源。

灰度期间保留原 TokenStep 只是为了对照旧个人本地看板和榜单展示；真正向生财上传数据的是独立常驻的官方 OpenToken，不能因为卸载 TokenStep 而停掉。TokenFleet 负责社群账本与榜单，三者凭据不要互相复制。

## 7. 何时卸载 TokenStep，以及如何回滚

满足以下条件后再卸载原 TokenStep：

- TokenFleet 源码安装、稳定本机签名、升级回滚和社群登记均已在本机通过；
- 每人自己的官方 OpenToken 常驻服务仍在运行，并已实测当天正常上生财榜；
- 多设备明细与费用连续试运行通过；
- 管理员明确结束灰度。

卸载时先在 TokenStep 自己的设置里关闭开机启动并退出，再把 `TokenStep.app` 移到废纸篓。灰度期不要删除它的 App Support 数据；这样回滚只需把原 App 放回 Applications 并重新启动，历史仍在。TokenFleet 的安装和卸载文档不提供删除 TokenStep 数据的命令，避免误删。

TokenFleet 自己的数据位于：

```text
~/Library/Application Support/TokenFleet
```

需要卸载 TokenFleet 时，先在设置中关闭开机启动、退出 App，再把 `TokenFleet.app` 移到废纸篓。团队端历史是否删除由管理员按留存策略处理，本机卸载不会代替服务端删除。
