# TokenFleet beta.15 成员升级说明

Mac 和 Windows 请在原设备原位升级一次。本次补上换机后的历史上传日期限制，并修复 Codex 每轮设置引起的重复整文件扫描及引用式分叉规则；网页更新不会自动升级本机客户端。

## 原位升级

保留原昵称、状态、凭据与日志，不卸载、不清数据、不复制另一台机器的连接文件，不重复领取新成员码。进入原源码目录，从正式 GitHub Release 复制完整 commit SHA，替换占位符后逐条执行；Git 和安装步骤成功后再进行下一步。

Mac：

```bash
git fetch --no-tags origin refs/tags/v0.1.0-beta.15
git rev-parse "FETCH_HEAD^{commit}"
# 与正式 Release 公布的完整 commit SHA 核对一致
git checkout --detach <reviewed-commit-sha>
test "$(git rev-parse HEAD)" = "<reviewed-commit-sha>"
bash script/install_from_source.sh --enable-community-sync --community-server https://token.ipwriter.com
```

先退出 TokenFleet。由 AI 在无交互终端代跑时可加 `--yes`；钥匙串弹窗由本人授权，保持原机器的签名身份。升级后打开原 App，确认 beta.15，点“立即刷新”，核对社群同步的最近成功时间。

Windows：

```powershell
git fetch --no-tags origin refs/tags/v0.1.0-beta.15
if ($LASTEXITCODE -ne 0) { throw "获取版本失败" }
git rev-parse "FETCH_HEAD^{commit}"
# 与正式 Release 公布的完整 commit SHA 核对一致
git checkout --detach <reviewed-commit-sha>
if ($LASTEXITCODE -ne 0) { throw "检出版本失败" }
if ((git rev-parse HEAD) -ne "<reviewed-commit-sha>") { throw "版本核验失败" }
powershell -NoProfile -ExecutionPolicy Bypass -File .\clients\windows\install.ps1 -CommunityServer https://token.ipwriter.com
if ($LASTEXITCODE -ne 0) { throw "安装失败" }
```

关闭本机页面和手动同步后重跑安装器，打开新终端检查版本，再手动同步并回读状态：

```powershell
& "$env:LOCALAPPDATA\TokenFleet\bin\tokenfleet.cmd" --version
& "$env:LOCALAPPDATA\TokenFleet\bin\tokenfleet.cmd" sync
if ($LASTEXITCODE -ne 0) { throw "同步失败，请查看状态" }
& "$env:LOCALAPPDATA\TokenFleet\bin\tokenfleet.cmd" status --json
```

## 添加第二台设备

在已经连接的 beta.15 Mac 设置页或 Windows 本机页面点击“添加另一台设备”，主动复制单次码。新设备按正常步骤安装，Mac 在社群同步页粘贴，Windows 运行 `tokenfleet connect` 后通过隐藏输入粘贴。15 分钟内使用，仅用一次，归入原昵称；本人重新生成会使此前未用的自助码失效，管理员签发码不受影响。请不要把码贴给聊天机器人。

同机升级一般无需重连；检测到换机时会记录检测当天的统计日期（Asia/Shanghai），生成新的设备身份并要求重新连接。重新连接只向社群上传该日及以后的桶；这个限制在重启、再次连接和强制同步后仍保留，迁移来的更早历史只留本机展示。

限制按天生效，不拆分换机当天的桶；如果这一天也迁入了旧机用量，仍可能与旧机当天重叠。已经上传的重复历史和旧设备服务器行不会自动删除。不要靠删除状态或卸载绕过日期限制。旧设备未绑定机器时，以第一次合法升级认证绑定为准，已经混合的历史不会自动拆分。不要复制 AI 日志到第二台设备后同时统计，两个独立设备仍可能将相同历史重复计入。

## 怎么核对数字

- 先确认 beta.15 和最近成功同步时间更新，再在网页选相同日期范围；网页是全部设备合计，本机是当前机器。
- 本机费用统一按服务端官方公开价格目录估算，缓存到本机。无公开价单独显示，不当作免费。费用榜所有参与成员均有名次，按已计价金额排序，缺价显示标记；这是 API 等价估算，不是订阅账单或真实付款额。
- 修复 Codex 继承计数后部分用量可能下降；只对 Codex 0.158.0-alpha.15.1 起且存在官方自身设置边界的复制型分叉扣一次继承量；带 history_base 的引用型分叉、旧格式和不完整边界保留旧规则，不新增扣除。不恢复 unknown 型号、不改工具/来源/日期。派生缓存首次重新计算可能稍慢，原始日志保留。
- 服务端不删除归零后的旧键，旧历史不做迁移；不承诺本机与榜单的所有旧差异都自动消失。对不上时只提供平台、版本、日期范围和非敏感状态摘要，不发凭据、设备码、原始对话或完整日志。

## 故障与回退

机器绑定启用后，不支持直接降回 beta.13 或更早的未绑定客户端：旧 Windows 无法识别新版状态字段，旧签名协议也不能用于已绑定设备。遇到问题先保留状态和凭据，原位重装当前发布版本；不要删状态、卸载再注册或自行降级。确需回退时联系管理员做单独处理。
