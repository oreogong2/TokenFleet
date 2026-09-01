# TokenFleet 实验来源默认开启公告草稿

状态：beta.11 已审公告，待 GitHub prerelease 发布后发送。

TokenFleet beta.11 会在 macOS 与 Windows 默认开启实验 Agent 来源。升级后对老用户也统一开启，并自动只读扫描已披露的新增工具固定目录，最多补计 180 天历史；个人总量和排行榜普遍上涨属于正常历史补计，不是重复统计。

你可以随时在 macOS“设置 → 统计与采集”或 Windows 本机统计页／`tokenfleet experimental disable` 关闭；新版本中的显式关闭会永久尊重。Windows 的 ZCode 继续在检测到用量库时默认采集，不受实验总开关控制。

两项主动行为保持不变：

- Cursor 个人账号仍只读取你主动选择并导入的官方 Usage CSV，不扫描下载目录或登录态；手动导入使用客户端正常历史窗口，不受自动实验来源的 180 天上限影响。
- Copilot OTel 仍需你自行开启 file exporter；没有 exporter 文件就不会产生这部分统计，采集结果会按实际来源显示为 Copilot CLI 或 Copilot Chat。

TokenFleet 只提取时间、工具、模型、Token 分量、成本和稳定去重 ID，不上传 prompt、回复、代码、项目路径或第三方凭据。新增来源的固定路径和具体边界会与隐私说明、支持策略一并发布。

默认开启后会按原计划进行 7 天真实样本巡检。发现口径错误会立即修复，能由相同 naturalKey 覆盖的记录会随下一次同步自愈；凡是“修复后不再发送旧桶”而无法自动消除的残留，会逐项列清单并走管理员通道清理。
