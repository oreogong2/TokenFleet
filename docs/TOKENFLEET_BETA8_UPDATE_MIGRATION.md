# TokenFleet beta.8 更新迁移方案

状态：代码侧通道规则已实现；真实更新源、Apple Developer Team ID、Developer ID 签名、公证和 beta.7 用户迁移尚未执行。没有完成这些外部条件前，不得声称 beta.8 能自动推送。

## 已知现状

- beta.7 源码安装包的 `TokenFleetUpdateAPIURL` 与 `TokenFleetDeveloperTeamID` 为空，因此客户端无法检查任何远端版本。
- GitHub 的 `releases/latest` 不返回 prerelease；旧更新逻辑也会忽略 `prerelease: true`。
- 远端无法给已安装的 beta.7 补写 Info.plist，也不能安全绕过签名信任。beta.7 用户必然需要一次人工迁移。

## beta.8 安全通道

- beta/RC 安装只接受语义版本更高的 beta、RC 或稳定版；稳定安装拒绝 prerelease。
- 更新清单必须来自 App 内写死的 HTTPS 地址，且不能指向上游项目。
- 下载只接受 HTTPS，限制清单与 DMG 大小、重定向次数，并校验声明大小。
- 安装前验证 Gatekeeper、公证、Bundle ID 和写死的 10 位 Apple Team ID；不满足即停止并保留当前 App。
- 更新源应返回单个、经过发布审批的 GitHub Release 兼容 JSON。若使用 GitHub API，beta 通道不能使用 `/releases/latest`，应由受控端点明确投影已经批准的 prerelease。

## beta.7 用户的一次性迁移

1. beta.8 PR/CI 通过后，使用专属 Developer ID 构建 universal DMG，并完成 Apple 公证与 stapling。
2. 在隔离测试机验证从 beta.7 源码版覆盖安装：保留 `~/Library/Application Support/TokenFleet`、Keychain 凭据、开机启动设置和历史数据；不触碰其他 App 或服务。
3. 管理员向小范围成员发送 DMG 页面、SHA-256 和签名核验说明。成员手动拖入 Applications；旧 App 在替换前保留可恢复备份。
4. 启动后设置页必须显示“已配置可信更新源”，并用只读测试清单验证能发现更高的 prerelease；不立即安装。
5. 灰度通过后再扩大迁移。beta.7 不会自行弹出 beta.8 提醒，不能把人工通知描述成自动推送。

## 回滚

- 保留上一版已签名、公证 DMG 与 SHA-256；回滚由管理员手工安装，先在测试机验证。
- 更新器只前进，不通过篡改更新清单执行远程降级。
- 回滚不删除本地数据和 Keychain，不修改社群服务，不操作其他 ECS/网站。
- 生产更新源切换、成员通知与实际发布前，必须再次用中文说明影响范围和回滚步骤，并等待奥哥单独确认。

## 发布硬门槛

- 获得真实 Apple Team ID、Developer ID 证书与公证凭据。
- 确定独立 HTTPS 更新域名/端点，并验证 TLS、缓存和故障回退。
- 签名包 universal（arm64 + x86_64），App/Helper Team ID 一致。
- prerelease/stable 通道、恶意清单、重定向、超大文件、错误 Team ID、断网与回滚矩阵全部通过。
- beta.7 → beta.8 的真实设备迁移验收通过；否则 beta.8 只能继续标记为源码测试版，不得对外说有自动更新。
