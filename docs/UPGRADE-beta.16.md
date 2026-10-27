# TokenFleet beta.16 成员升级说明

本次补齐 macOS Kimi Work 的本地用量采集。需要统计 Kimi Work 的 Mac 用户可升级；无此需求的 Mac 用户及 Windows 用户可继续使用 beta.15，无需重装、重新登记或手动同步。源码版不会自动升级，服务端无需配套部署。

## 本次变化与统计边界

- Kimi 来源保留独立 CLI 的 `~/.kimi-code/sessions/**/wire.jsonl`，并扫描 Kimi Work 根目录 `~/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home` 下的 `sessions/**/wire.jsonl`。新增目录也参与自动刷新检测。
- 沿用“实验 Agent 来源”开关。已开启时，升级后按现有统计窗口最多补计 180 天；显式关闭时保持关闭。新增 Kimi 用量可能提高本机及社群汇总。
- 只累计 `step.end` 的精确用量，忽略同一流程的 `usage.record`，相同实际文件只读一次，重复事件按 UUID 去重。没有 UUID 的记录仍按文件及行定位；不同文件的无 UUID 副本无法保证去重，请不要复制日志或建立额外统计副本。
- 两个运行时分别使用各自的模型默认值，仍显示为同一 Kimi 来源。无公开价格的型号继续标为未计价，不把订阅额度或对话字数当作 token 数。
- Mac 采集器为 `0.2.5`；Windows 采集器仍为 `0.2.0-windows.6`，本次没有增加 Windows Kimi Work 路径支持。其他采集器、上传协议、设备身份及换机日期限制保持原有行为。
- 适配的是上述已反馈路径及用量格式，仍属实验支持。其他 Kimi 产品、版本、自定义目录或远端运行时不保证被扫描；用户真实日志的完整性须在升级后核对。

## Mac 原位升级

先退出 TokenFleet，保留原源码目录、昵称、状态、凭据与日志。不卸载、不清数据、不创建新昵称，也不要将另一台机器的 App 或连接文件复制过来。

进入原源码目录，从正式 GitHub Release 复制完整 commit SHA，替换下面占位符。每一步成功并核对后再执行下一步：

```bash
git fetch --no-tags origin refs/tags/v0.1.0-beta.16
git rev-parse "FETCH_HEAD^{commit}"
# 与正式 Release 公布的完整 commit SHA 核对一致
git checkout --detach <reviewed-commit-sha>
test "$(git rev-parse HEAD)" = "<reviewed-commit-sha>"
bash script/install_from_source.sh --enable-community-sync --community-server https://token.ipwriter.com
```

纯本地统计的用户沿用原本的本地安装方式；自建社群沿用原固定地址。AI 在无交互终端代跑时可加 `--yes`，系统钥匙串弹窗仍由本人授权，保持原机器的签名身份。安装失败时先保留现状，不清理连接或日志。

## 升级后核对

1. 确认 App 显示 beta.16，原昵称及社群连接仍在。
2. 需要采集 Kimi 时，确认“设置 → 统计与采集”的实验来源开关已开启，点“立即刷新”，查看 Kimi 来源的文件数、记录数与状态。
3. 在相同日期范围内，对比本机有效 `step.end` 用量汇总。原始日志总行数不等于请求数；重复事件、无效用量及统计窗口外记录不会全部计入。
4. 已连接社群的用户查看最近成功同步时间。网页合计全部设备，本机只统计当前设备；换机检测日期之前的迁移历史继续只留本机，不借本次补计重新上传。

首次补计可能比平时刷新稍慢。不要为了追求总量一致复制日志或重复建号；反馈只需提供平台、版本、日期范围、来源状态和脱敏用量字段，不发送凭据、设备码、对话正文或完整日志。

## 故障处理

保留状态、凭据和原始日志，先原位重装当前已发布版本；需要暂停新增实验采集时，可关闭实验来源总开关（会同时关闭其他实验来源）。不支持直接降回 beta.14 或更早版本；这些旧版不能保留 beta.15 起的换机上传日期限制。确需回退时由管理员单独核对，源码回退不会自动删除已上传的历史日桶。
