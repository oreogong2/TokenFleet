# TokenFleet beta.13 成员升级说明

本版修复同步失败后的恢复、坏记录连带漏报和金额显示。Mac、Windows 都需要主动升级源码版，网页更新不会自动升级本机客户端。

请在原设备、原源码目录中升级，不要卸载、清除状态、复制另一台机器的 App 或重新领取设备码。昵称、原设备 ID、凭据和历史会保留。多设备身份和统一价格目录仍在后续批次处理；本版费用仍是 API 标准价估算，不是实际账单。

## Mac

先退出 TokenFleet。进入原源码目录，从正式 GitHub Release 复制管理员公布的完整 commit SHA，替换下方占位符后执行：

```bash
git fetch origin --tags
git checkout --detach <reviewed-commit-sha>
test "$(git rev-parse HEAD)" = "<reviewed-commit-sha>"
./script/install_from_source.sh --enable-community-sync \
  --community-server https://token.ipwriter.com
```

由 AI 在无交互终端代跑时，安装器可加 `--yes`；系统钥匙串授权弹窗仍需本人处理。不要改用其他机器的签名身份。

重新打开 `~/Applications/TokenFleet.app`，确认设置页版本为 beta.13，点“立即刷新”，再查看社群同步状态。旧版遗留的停止状态会在升级后尝试恢复；若明确提示凭据失效，联系管理员确认后再重新登记。

## Windows

关闭 TokenFleet 本机页面及正在运行的手动同步。进入原源码目录，从正式 GitHub Release 复制完整 commit SHA，替换占位符后执行：

```powershell
git fetch origin --tags
git checkout --detach <reviewed-commit-sha>
if ((git rev-parse HEAD) -ne "<reviewed-commit-sha>") { throw "版本核验失败" }
powershell -NoProfile -ExecutionPolicy Bypass -File .\clients\windows\install.ps1 `
  -CommunityServer https://token.ipwriter.com
```

必须重跑安装器，才能注册本版电池运行、错过补跑和登录触发的计划任务；只拉取代码不会更新已安装运行时。不要先执行 uninstall。安装后打开新终端：

```powershell
tokenfleet status
tokenfleet sync
tokenfleet status
tokenfleet open-rank
```

确认最近成功时间更新，上传没有失败；不完整或被隔离的桶会单独提示，不会显示为上传成功。任务每六小时运行，登录或错过任务时也会触发；一次手动同步成功不代表后续自动任务已经验收。

## 升级后怎么核对

- 查看客户端版本、最近成功同步时间和异常摘要；无需重新填写一次性设备码。
- 等一次成功上传后，在网页选择相同日期查看用量。服务器是成员全部设备的合计，本机是单台设备；不完整数据也会使二者不同。
- 本轮修复漏报后，部分成员榜单总量可能上升；若仍有差异，请提供系统、版本、日期范围和非敏感状态摘要。不要发送凭据、设备码、原始对话或带昵称与用量的整份日志。
- 费用榜仍用旧排法，价格覆盖不足的成员暂不参与费用排名。统一价格、官方新型号价格和历史价格重算会在第二批完成后另行通知。

Mac 回滚可运行 `./script/rollback_source_install.sh`。Windows 若需回退，请检出此前管理员确认的版本 SHA 后重跑同一安装器，保留相同社群地址；不要通过清数据恢复。
