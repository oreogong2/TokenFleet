# TokenFleet beta.8 生产兼容部署与实测报告

日期：2026-08-15（Asia/Singapore）
状态：**已完成 TokenFleet 专用生产服务的 beta.8 契约升级；未合并 PR、未创建 tag/Release、未切换公开下载或在线自动更新。**

## 1. 授权与范围

奥哥在收到影响和回滚说明后，明确授权“先备份，再升级 TokenFleet 线上服务器到 beta.8；出问题立即回滚”。本次仅作用于 TokenFleet 专用生产服务：不操作其他 ECS、其他网站、DNS、Nginx、证书、安全组或公开更新源。

部署源码固定为 `dc6cb96ee786f7ecc17cbab5afddc7f385cefa85`。该提交相对已通过四项 CI 的运行时提交 `ace51c1e9c1ebc6d89c0e4cc693ec15ebbee4837` 只增加文档；`server/`、`web/` 与 `deploy/` tree 一致。生产机重新从 GitHub 校验分支精确指向该 SHA 后才开始构建。

## 2. 数据保护与回滚

- 升级前创建 PostgreSQL custom-format 归档 `tokenfleet-20260815T131323Z.dump`；其 SHA-256 为 `3af84bdb51b0d534025707fe174e4599ad9e0975b9f55c6297e7758a5aeb99f1`。
- `sha256sum --check` 与 `pg_restore --list` 均通过；既有每日备份保留，未执行 prune 或删除。
- beta.8 不包含数据库 migration；生产 PostgreSQL 容器与数据卷保持原样。
- 正式切换前在新发布目录构建镜像；`current` 软链仅在构建、环境校验和备份校验通过后原子切换。
- 首次实际尝试因部署验证脚本的引号错误误判失败，自动切回 beta.7；回滚后 `current` 恢复 beta.7、App 健康、数据库容器 ID 不变。该失败没有删除或恢复数据库，随后修正为不依赖该引号的字段校验后重试成功。
- beta.7 发布目录仍保留。若后续发现运行问题，可将 `current` 原子切回 beta.7 并以旧 Compose 配置重建 App；除非数据损坏确认且先在副本演练，否则不得对生产库执行 downgrade 或恢复覆盖。

## 3. 生产验收结果

最终生产 `current` 指向 `v0.1.0-beta.8-dc6cb96`。

- `healthz` 与 `readyz` 经公网 HTTPS 返回成功。
- 公开榜返回 beta.8 字段：`primary_tool`、`primary_tool_tokens`、`tool_count`、`primary_model`、`primary_model_tokens`、`model_count`。
- 无凭据请求签名个人排名路由返回 `401` 而非旧版的 `404`，证明路由存在且仍受设备鉴权保护。
- 数据库容器保持原 ID 与 healthy 状态；升级前后组织 1、用户 10、设备 6、每日用量 1259、邀请批次 1、注册码 12，未出现成员、设备或批次复制/丢失。
- 奥哥本机的已升级 beta.8 App 正常重启后，今日页显示社群排名 `#1 / 6`；社群页显示“今天第 1 / 6 名”、主力工具 Codex、主力模型 gpt-5.6-sol、连续活跃 45 天；“分享排名”由禁用恢复为可用，菜单实际提供“复制排名海报 / 保存排名海报 PNG”。本次验收只展开菜单，未复制或保存文件。

## 4. 当前边界

1. 这是 beta 服务兼容升级，不等同稳定版。首批 50 人、连续 14 天观察与人工 Intel/Windows GUI 验收仍是后续稳定版门槛；不得因本次上线取消 beta 标识。
2. 既有成员继续按固定 commit 的源码安装／手动升级，不需要 Apple Developer 账号。尚无 Developer ID、公证、公开 DMG 或可信在线更新源；这些能力仍未发布。
3. Draft PR #4 未合并；beta.2–beta.7 tag 未改；未创建 beta.8 tag 或 GitHub Release。
4. 公开费用仍是 API 标准价等价估算，未完整计价时保持“未完整计价”，不作为账单或实际支出。

## 5. 给 Claude 的只读复核要点

请在正式仓库、Draft PR #4、公开 HTTPS 入口和本报告上只读核对：

1. `dc6cb96` 是否为分支 head，且相对 `ace51c1` 的运行时目录无差异；四项 CI 是否均为成功。
2. `docs/TOKENFLEET_BETA8_ACCEPTANCE_REPORT.md` 与本报告是否诚实区分候选期历史状态、已执行的生产服务契约升级，以及未授权的合并/公开发布。
3. 公开榜是否含 beta.8 主力工具／模型字段；无凭据个人排名请求是否仍被拒绝；不输出、猜测或要求任何设备 secret。
4. beta.2–beta.7 tag 是否保持不变；beta.8 是否仍无新 tag/Release。
5. 报告是否没有记录管理员密码、数据库密码、JWT、设备 secret、邀请码、服务器 IP 或其他服务信息。
