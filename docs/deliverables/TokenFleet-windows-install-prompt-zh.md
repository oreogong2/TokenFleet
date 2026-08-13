# TokenFleet Windows 安装提示词

状态：待发布。本文固定的 Windows 客户端 commit 目前仅存在于维护者本地；只有发放人
确认该 commit 已推送至公开 GitHub 仓库后，才可以把下面的提示词交给用户执行。

固定 Windows 客户端 commit：

```text
5a8e63729afacde20bd4bc5ef28dbdfa6d043c1c
```

下面代码块中的内容可以完整交给 Windows 用户使用：

```text
请帮我在这台 Windows 电脑安装 TokenFleet Windows 客户端 0.1.1。默认把你视为云端 AI：
你可以执行不会暴露个人路径或凭据的只读环境检查、解释步骤并把命令给我，但不能在
你的命令工具中执行正式安装脚本、设备连接或正式同步，也不能读取安装、连接或同步过程
的原始输出。正式安装和设备连接必须由我本人在 Windows PowerShell 中执行。

请严格遵守下面的边界：

1. 只允许写入以下用户级位置：
   - $HOME\TokenFleet-Install 下新建的固定版本源码目录；
   - %LOCALAPPDATA%\TokenFleet 中 TokenFleet 自己的程序、配置、DPAPI 密文、状态和回滚暂存；
   - 当前用户 PATH 中 TokenFleet 自己的 bin 目录；
   - 当前用户的 `TokenFleet Community Sync` 计划任务。
   不要求管理员权限，不修改系统 PATH、系统凭据、网络设置、其他项目或其他计划任务。

2. 先做只读检查，确认系统是 Windows 10 或 Windows 11，并检查 Git、PowerShell 和
   Python 3.10 或更高版本。只告诉我是否满足要求，不要输出用户名、家目录或完整可执行
   文件路径。若 Git 或 Python 缺失，先停止并说明安装开发工具属于额外软件安装；只有取得
   我明确同意后，才可以把安装命令交给我，由我本人执行。不要自行触发 winget、商店安装、
   系统安装窗口或管理员权限请求。

3. 源码只能从公开仓库 https://github.com/oreogong2/TokenFleet.git 获取，并必须固定到：

   5a8e63729afacde20bd4bc5ef28dbdfa6d043c1c

   在提供安装命令前，先确认这个 commit 已能从公开远端获取。如果远端不存在、下载失败、
   HEAD 校验不一致或工作区不干净，立即停止，不允许退回 main、beta.7、其他 tag 或相近版本。

4. 如果 %LOCALAPPDATA%\TokenFleet 已存在，先告诉我这是一次源码升级。安装器会在用户目录
   内暂存新版本、原子替换程序，并在安装失败时自动恢复原程序；成功后保留设备 DPAPI 凭据、
   状态和固定社群地址。不要自行删除旧客户端或凭据。

5. 请把下面的固定版本下载与安装命令完整交给我，由我本人在普通 PowerShell 中执行。
   不使用“以管理员身份运行”，不使用 sudo：

   $ErrorActionPreference = "Stop"
   $InstallRoot = Join-Path $HOME "TokenFleet-Install"
   $SourceRoot = Join-Path $InstallRoot "TokenFleet-5a8e637"
   if (Test-Path -LiteralPath $SourceRoot) {
       throw "固定版本源码目录已存在；请停止并联系发放人确认，不要覆盖。"
   }
   New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
   git clone --no-checkout https://github.com/oreogong2/TokenFleet.git $SourceRoot
   if ($LASTEXITCODE -ne 0) { throw "源码下载失败。" }
   git -C $SourceRoot checkout --detach 5a8e63729afacde20bd4bc5ef28dbdfa6d043c1c
   if ($LASTEXITCODE -ne 0) { throw "固定版本不可用。" }
   $ActualCommit = (git -C $SourceRoot rev-parse HEAD).Trim()
   if ($LASTEXITCODE -ne 0 -or $ActualCommit -ne "5a8e63729afacde20bd4bc5ef28dbdfa6d043c1c") {
       throw "源码 commit 校验失败。"
   }
   $WorktreeStatus = git -C $SourceRoot status --porcelain
   if ($LASTEXITCODE -ne 0) { throw "源码状态校验失败。" }
   if ($WorktreeStatus) {
       throw "源码工作区不干净。"
   }
   $Installer = Join-Path $SourceRoot "clients\windows\install.ps1"
   powershell -NoProfile -ExecutionPolicy Bypass `
       -File $Installer `
       -CommunityServer https://token.ipwriter.com
   if ($LASTEXITCODE -ne 0) { throw "TokenFleet 安装失败。" }

6. 任一命令退出非零就停止。不要连续重试、删除目录、改用其他 commit 或放宽校验；先解释
   错误类别和下一步。不要让我直接发送原始 PowerShell 输出、完整日志、用户名、家目录、
   `%LOCALAPPDATA%` 实际路径、设备码、DPAPI 文件或任何凭据。由我先复制末尾不超过 20 行
   到文本编辑器，遮住用户名、个人路径、设备 ID 和所有凭据，再提供脱敏摘要。若我不会脱敏，
   就停止并联系发放人。

7. 安装成功后，让我关闭当前 PowerShell 并打开一个新的普通 PowerShell，先由我本人运行：

   tokenfleet preview

   该命令只读取本机 Codex 和 Claude Code 的日聚合，默认最多检查最近 366 个本地自然日。
   不要要求我发送完整预览输出；我只需要告诉你预览是否成功，或者提供脱敏错误摘要。

8. 批次邀请链接由发放人另行私发。不要让我把邀请链接或个人设备码发给你，不要读取、
   记录、回显或保存它们。让我本人打开邀请链接、登记公开昵称并领取这台设备专用的一次性码。

9. 设备连接必须由我本人在新的普通 PowerShell 中运行：

   tokenfleet connect

   只能在命令启动后的隐藏输入提示中粘贴一次性设备码；不得把设备码写在命令参数、脚本、
   环境变量、剪贴记录、聊天消息或日志中。连接完成后，我本人确认隐藏输入已经结束，并立即
   清理剪贴板。你只等待我回复“成功”或提供已经脱敏的错误摘要。

10. 客户端会尝试创建每六小时运行一次的当前用户计划任务。部分 Windows 安全策略可能
    拒绝创建该任务；这种情况下设备连接和首次正式同步仍应继续完成，并显示需要定期运行
    `tokenfleet sync` 的警告。不要要求管理员权限，不要绕过系统策略，也不要声称自动同步成功。

11. 等我确认设备码已提交、隐藏输入已结束且剪贴板已清理后，才可以继续指导我执行：

    tokenfleet status --json
    tokenfleet open-rank

    检查项目仅限：客户端版本、连接状态、固定服务器、最近同步状态、是否存在用户级计划任务，
    以及公开排行榜是否出现对应昵称和统计。不要读取 DPAPI 密文或安装原始日志。

12. 正式同步默认覆盖最近 366 个本地自然日；只上传日期、时区、工具、模型和四类 Token
    聚合，不上传 prompt、回复、代码、文件内容、项目路径或 AI 账号 ID。首次验收后可以再运行
    一次 `tokenfleet sync --json` 验证幂等性：相同数据应为 `created=0`，当天新增用量允许表现为
    `updated>0`。不要把完整输出发给你，只报告是否符合预期或提供脱敏摘要。

请先进行安全的只读检查，再一步一步指导。遇到错误不要连续重试，先解释错误和下一步。
```
