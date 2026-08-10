# TokenFleet Mac 邀请测试版发放方案

TokenFleet `v0.1.0-beta.3` 采用“公开源码、邀请接入”的 beta 方式。公开仓库让成员可以审查和在
自己的 Mac 上构建客户端；社群服务器、管理员后台和设备登记仍由邀请码控制。公开
源码不等于任何人都能加入社群榜。

## 首批规模

首批上限为 50 人，分三批开放：

1. 第 1 批 5 人：验证不同 macOS 版本、首次安装、钥匙串和历史同步；
2. 第 2 批 15 人：验证支持文档、重复安装、升级和回滚；
3. 第 3 批 30 人：验证集中接入时的后台、排行榜和问题处理能力。

每批至少观察一个完整同步周期。上一批没有出现阻断性的数据错误、凭据错误或安装
失败，才开放下一批。小的视觉和文案问题可进入后续版本，不阻塞 beta。

## 成员需要获得的信息

管理员通过可信的社群私聊提供：

- TokenFleet 官方公开仓库地址；
- 已复核的完整 commit SHA；
- 固定社群地址 `https://token.ipwriter.com`；
- 为该成员、该设备单独创建的短期一次性设备码。

仓库地址、commit SHA 和社群地址可以公开。一次性设备码不得发到群聊、截图或命令
行中，也不能多人共用。设备码在成员开始安装、确认能在一小时内完成时再生成。

## Mac 安装

```bash
git clone <official-public-repo-url> TokenFleet
cd TokenFleet
git checkout --detach <reviewed-commit-sha>
test "$(git rev-parse HEAD)" = "<reviewed-commit-sha>"

./script/install_from_source.sh \
  --enable-community-sync \
  --community-server https://token.ipwriter.com
```

安装完成后打开 `~/Applications/TokenFleet.app`，进入“设置 → 社群榜同步”，在安全
输入框粘贴一次性设备码。安装脚本不接收邀请码，也不会把邀请码写入 shell 历史。

## 管理员发放步骤

1. 先确认成员正在使用 Apple Silicon Mac，系统为 macOS 14 或更高版本，并已安装
   Xcode Command Line Tools；
2. 在后台仅使用成员同意公开的昵称创建参赛者；
3. 为这台 Mac 生成一个设备码，默认有效期 60 分钟；
4. 私聊发送安装说明和设备码，不建立包含全部成员设备码的表格；
5. 成员连接后检查：客户端显示同步成功、公开榜出现昵称、Token 与工具/模型聚合；
6. 同一成员的第二台 Mac 必须生成新的设备码；
7. 安装失败或设备码过期时废弃旧码，排除原因后再生成新码。

## Beta 验收与暂停条件

每位成员至少确认以下四项：

- App 能正常启动并显示本地 Token；
- 接入后能完成一次历史同步和一次后续增量同步；
- 排行榜只显示已声明公开的昵称、Token、估算费用、工具、模型和日趋势；
- 没有上传 prompt、代码、项目路径、对话正文或 AI 账号身份。

出现以下任一情况时暂停下一批：

- 多人安装后无法再次启动或升级；
- 同一成员发生明显重复计量、历史丢失或错误归零；
- 设备码、设备 secret 或管理员凭据出现在日志、URL、截图或仓库；
- 服务器健康检查失败、数据库备份失败或排行榜持续不可用。

## 升级、回滚与退出

管理员发布新版本时同时公布新 commit SHA。成员在原 clone 中切换到该 SHA，再运行
同一安装命令。需要回滚或卸载时：

```bash
./script/rollback_source_install.sh
./script/uninstall_source_install.sh
```

源码安装版没有 Apple 公证信誉，也不提供静默自动更新。它适合当前邀请制 beta；当
非技术用户比例明显增加、终端安装成为主要阻力时，再评估 Developer ID 和公证 DMG。

## 公开仓库边界

公开仓库从无旧历史的清洁快照创建，不直接公开内部开发仓库。公开版本不得包含：

- 真实用量截图、个人邮箱、本机绝对路径；
- 管理员密码、数据库密码、SSH 密钥、设备 secret 或生产 `.env`；
- 内部复核报告、生产服务器 IP、部署交接单或数据库备份；
- 构建缓存、虚拟环境、测试数据库、签名私钥或 provisioning profile。

`server/.env.example` 只能保留无法直接运行生产环境的占位符。生产服务器仍使用独立
的密钥管理和部署目录，不能从公开仓库恢复真实凭据。
