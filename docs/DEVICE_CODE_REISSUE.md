# 给已有成员补发设备码

补发只适用于本人确认过的原昵称。新码 24 小时有效、只能用一次；生成新码会使该成员仍未使用且未过期的旧码失效。不会创建成员、占用批次名额、改动设备或历史用量。已使用码的记录保留。

## 管理员本地工具

配置必须放在仓库外的 `$HOME/.config/tokenfleet/member-reissue/`，目录权限 0700，文件权限 0600：

- `credential`：单独的 `members:reissue-only` 凭据。
- `metadata.json`：可信 HTTPS 服务的 `origin`、`scope`、凭据 ID 和到期时间；不放设备码。

在管理员 Mac 执行 `python3 script/reissue_member_code.py '本人确认的原昵称'`。设备码直接进入剪贴板，终端只显示“已复制，24 小时内有效”。不要把码发给 AI、放入参数或日志。安装指南请向社群管理员获取。

工具不自动重试请求。如果网络或剪贴板异常，应先核查再重新补发；重新生成会使上一张未用码失效。

## 专用凭据边界

管理员通过 `POST /api/v1/enrollment-management/credentials` 签发，默认及最长有效期 90 天；通过 `DELETE /api/v1/enrollment-management/credentials/{id}` 吊销。凭据只在签发时返回一次，服务端仅保存摘要。

专用凭据只允许 `POST /api/v1/enrollment-management/reissue`，请求仅含 `display_name`。要求同一社群内的有效普通成员、精确匹配昵称。不能查询成员、创建成员、修改数据或价格、签发其他凭据。管理员被禁用或降权时，凭据立即失去权限。

不要用完整管理员登录凭据运行日常补发。到期后需管理员签发替代专用凭据并吊销旧凭据。
