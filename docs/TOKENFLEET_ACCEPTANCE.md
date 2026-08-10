# TokenFleet 验收矩阵

本文是发布阻断清单。未勾选不代表缺陷，代表尚未获得可复现证据。

## 当前证据（2026-08-11）

- 服务端与部署模板：本地共收集 `148` 项，`133 passed, 15 skipped`；默认 SQLite 门禁覆盖租户/RBAC、非登录参赛者、批次 claim/回滚/昵称唯一迁移、1/2/4/50 台设备、签名、防重放、设备登记限流、共享 usage 限速、自然键硬配额、幂等、质量单调覆盖、组织时区默认日期、公开混合时区提示、公开扫描硬上限、极值价格、重登记密钥轮换、价格、留存、成员禁用、DST、JWT 边界、最大 Token、128 字符模型、安全响应头、隐藏 tombstone、数据库异常参数隐藏、旧迁移和公开组织 readiness；15 条 PostgreSQL smoke 在未提供 `TEST_POSTGRES_URL` 时按设计跳过。
- PostgreSQL 17：15 条 smoke 在既有迁移/并发/限流/50 名独立参赛者容量回归上，新增 60 个并发 batch claim 恰好 50 成功、batch claim 与管理员同名并发恰好一胜、批次 RBAC 与匿名响应递归白名单。发布候选必须在 GitHub CI 的 PostgreSQL 17 服务上让 15 条全部通过；本机 Docker API 异常不作为已通过证据。
- Web 单元：`50 passed`，包含匿名公榜合同、大整数精确排序、未定价、多币种、管理员价格录入、无登录参赛者、个人/批次接入码、分享深链与二维码、演示水印、移动导航名称、异步路由竞态、退出内存清理和表单防重复提交。
- API 黑盒：同一成员 2 台设备分别上报 Codex / Claude Code，重复上报 unchanged；同一安装重新登记复用 device ID、旧密钥失效且总量不翻倍；禁用设备拒绝，机密输出 0。
- 真实 Web：创建/禁用/恢复成员、生成一次性设备邀请码、双设备明细、成本、退出清理、错误登录 `401`、成员隐藏管理员成本入口且直接路由回总览、离线和被拒凭证状态通过；预期网络失败之外 console/page error 均为 0。
- 响应式 Web：管理员 7 条路由和匿名 `/rank`、`/rank/p/{id}`、`/join`、`/join/batch` 深链均可直接刷新；批次页在 1440/820/390px 无横向滚动，fragment 立即擦除，query/path 只擦不认，claim 请求无认证头，个人码只可主动复制；蓝白榜单、键盘焦点、移动导航名称、对比度和 reduced-motion 均通过。1200×1600 分享海报二维码已由 macOS Vision 实际解码为完整 HTTPS 筛选链接。
- 开发启动：`verify_tokenfleet_dev_start.py` 从临时空状态验证迁移、内存随机 JWT secret、SPA、health/ready、`401`、登录和 `/me` 后终止进程并清理，整个过程不依赖真实 secret 或 `.env`。
- Swift：`script/verify_tokenstep_swift.sh` 通过完整源码 typecheck、测试源码检查、逻辑 harness、离线/408/425 退避恢复、force 全量重传与 requestRejected 手动恢复、401/403 不可绕过、缺失来源不自动删除、`ledger_version: 0` 成功响应、团队接口 1 MiB 响应硬限、更新/榜单/DMG 网络供应链边界、Codex/CC Switch/migration fixtures 与本地化检查。
- 分发与依赖：免费源码分发门禁在系统授权的 `/private/tmp` 隔离钥匙串中验证稳定身份复用、私钥不可导出、ad-hoc 同步关闭、原子安装/回滚/卸载，并确认登录钥匙串 search list/default 与工作区 `dist` 均不变；普通文件沙箱会使 macOS Security API 返回 `-50`，不作为产品失败。独立桌面门禁另验证 TokenFleet 身份、Team ID 固定、安全版本号、原子发布与旧包保留；临时隔离环境升级至 `pip 26.1.2` 后，`pip-audit 2.10.1 --local` 报告 `No known vulnerabilities found`，同一依赖审计已接入 CI。
- SQLite 灾备演练：在线 `.backup`、恢复到新库、`PRAGMA integrity_check=ok`、源/恢复库用量行数 `2=2`、Alembic 均为 head。
- 本机 SwiftPM 因 Swift 6.3.3 与 SDK 6.3.2 的 manifest 链接错配不可用；独立 `swiftc` 门禁使用匹配的 macOS 15.4 SDK。该环境问题不能等同于 `swift test` 已运行。

## A. 官方能力回归

- [x] Codex JSONL 增量、重置、fork、重复事件测试通过。
- [x] Codex SQLite fallback 测试通过。
- [x] Claude Code message/response/request 去重测试通过。
- [x] CC Switch 仅接收 2xx、proxy、token > 0，且跨来源去重测试通过。
- [ ] 今日圆环、多圈目标、菜单栏和 Token Island 正常。
- [ ] 历史、活动墙、统计、模型、工具和成本正常。
- [ ] 主题、语言、刷新、开机启动、更新检查正常。
- [ ] 截图、每日卡与节奏卡正常。
- [ ] Codex / Claude Code 额度开关与失败态正常。

## B. 历史明细

- [x] 同一天 Codex + Claude Code 同时出现，不再只显示“主力工具”。
- [x] 每个工具可展开模型和四类原子 Token。
- [x] 精确工具×模型合计等于当天总计。
- [x] TokenStep 含缓存的原始 input 会转换为未缓存 input，四类字段无双算且合计守恒。
- [x] 分项不完整的 fallback 不伪造 exact、不估价，并显示/记录遗漏。
- [x] 旧 JSON 可读，且显示“旧数据仅有汇总”；无法还原交叉明细的旧日计入同步遗漏。
- [x] schema 新旧往返编码无丢失。

## C. 多租户与权限

- [x] 组织 A 的 admin/member 无法读取或修改组织 B。
- [x] member 无法读取其他成员。
- [x] device credential 无任何读权限。
- [x] 一次性 enrollment token 不能重复使用，过期后拒绝。
- [x] 禁用用户/设备立即拒绝新上报。
- [x] 社群参赛者只需昵称，邮箱与密码成对为空，不能登录管理员后台。
- [x] 管理员创建的批次最多 50 人、最长 24 小时且可关闭；令牌只存哈希，成员明确同意公开后原子创建参赛者、60 分钟设备码和容量计数。
- [x] 同组织昵称经 NFKC/casefold 后由数据库唯一索引失败关闭；batch claim 与管理员手工同名并发最多一方成功。
- [x] 匿名公榜固定投影唯一配置社群，不能由请求选择其他组织。

## D. 设备签名与同步

- [x] 正确 HMAC 被接受。
- [x] body、path、method、timestamp、nonce 任一改变均拒绝。
- [x] 过期 timestamp 和 nonce 重放均拒绝。
- [x] 未知字段、负 Token、超上限、非法时区和重复自然键拒绝。
- [x] 相同桶重复上报 unchanged，变化后 updated，不重复累加。
- [x] 清除连接并重新登记保留安装 ID，服务端复用设备账本且轮换密钥，历史不重复。
- [x] 离线不影响本地客户端，退避期不请求，恢复后补传且本地 snapshot 不变。
- [x] 手动 force 忽略本地 hash，完整重传当前 exact 桶；普通同步仍跳过未变化桶。
- [x] 正式客户端只接受签名 Info.plist 固定的规范化 HTTPS DNS origin；成员不能输入服务器地址，数字 IP 别名、loopback、空/非法/带凭证/path/query/fragment 的 origin 均拒绝。
- [x] 已连接客户端可从设置和菜单栏弹窗一键打开固定 `/rank`；未连接、旧 origin 不匹配或截图渲染态均不生成 URL，不携带 enrollment/device token。
- [x] 客户端 v1 不自动生成 tombstone；同日某 exact 来源暂时消失而另一来源仍存在时，普通同步和 force 都不删除、不丢 stale hash。
- [x] 早期预发布 `__deleted__` 标记不重传，force 也只发送当前 exact；key 重现时正常 upsert 覆盖标记。未来自动删除须先有权威覆盖证明。
- [x] processed 计数匹配且 `ledger_version: 0` 的留存线外响应按成功处理，不进入 terminal 状态。
- [x] 408/425 进入 transient 退避并可在 force/到期后恢复；422 等 requestRejected 不自动重试，但修复后“立即同步”可恢复。
- [x] 401/403 进入 credentials terminal；force 与“立即同步”均不能绕过，必须重新连接。
- [x] 服务端持久化隐藏 tombstone 版本并从查询/成本中排除；等时删除优先，仅严格更新的 exact 可复活，留存截止线前的 force/离线上报不落库。
- [x] macOS file-login Keychain store 已接入；固定 service/account、精确单钥匙串查询、禁止交互、严格 envelope、轮换、清除、并发与失败关闭均由 fake operator / executable fixture 覆盖，Keychain 之外没有明文 device secret。
- [x] 免费源码分发在隔离临时钥匙串验证稳定自签身份复用、不可导出、ad-hoc fail closed、安装、回滚和卸载，且不改变真实登录钥匙串 search list/default。
- [ ] 在干净 macOS 登录用户上完成真实 file-login Keychain 首次登记、重启、升级后无提示复用、锁定失败无弹窗及卸载保留人工 E2E；该外部门禁不能由隔离 fake/临时钥匙串替代。

## E. 多设备统计

- [x] 同一成员 1、2、4 台设备均完整求和。
- [x] 不同成员和设备筛选正确。
- [x] 禁用一台设备不删除历史，但停止新增。
- [x] 设备最后同步、版本和健康状态正确。
- [x] 界面明确标注“设备用量合计”，不声称跨设备去重。

## F. 成本和时间

- [x] input/output/cache read/cache write 分价正确。
- [x] 改价格不会静默改写已冻结的历史口径。
- [x] API 估算、实际 API 费用、固定订阅费分栏显示。
- [x] Asia/Shanghai、Asia/Singapore、UTC 日桶均按各设备本地日期准确筛选并保留来源时区。
- [x] 混合时区结果返回并显示提示，不声称已跨时区重归日。
- [x] DST 日期范围不丢失日桶；UTC 小时级重组明确属于 v2，不由日桶反推。

## G. Web

- [x] 登录、退出、401、403、离线和过期凭证状态正确。
- [x] 总览、成员、设备、历史、模型工具、成本、设置可访问。
- [x] 空数据、单成员、多成员、超大数和长模型名不破版。
- [x] 手机、窄屏和桌面布局可用。
- [x] 键盘导航、焦点、对比度和 reduced-motion 可用。
- [x] 演示模式有醒目标记，真实模式绝不回退假数据。
- [x] 匿名 `/rank`、公开个人页和筛选可用；只返回昵称、排名、四类 Token、工具/模型、日趋势和显式公开标准价估算。
- [x] 匿名响应不含邮箱、组织 slug、内部用户/设备 ID、设备详情、IP、小时、会话、消息或城市。
- [x] `/join#code=...` 在其他模块工作前清除 fragment；同一标签页第二个 code 会安全替换前一个，原始码不进入 DOM、storage、日志、请求、浏览历史或 query，页面离开后清空内存；从接入页进入 `/rank` 后刷新仍留在公榜。
- [x] `/join/batch#invite=...` 仅接受 fragment；query/path 形态只擦不认。批次令牌只进入匿名 claim body，个人码只在闭包内存和用户主动复制的剪贴板中存在。
- [x] 工具/模型来自服务端已观测值下拉；混合时区只显示通用口径警告，不公开具体设备时区。
- [x] 分享图只在浏览器本地生成，包含 Top 10、榜外本人、筛选口径和同源 HTTPS QR；演示海报带不可去除水印。
- [x] public→admin、admin→public、public→public、退出、分享和一次性码等慢响应均受全局导航代数保护，不会用旧响应覆盖新页面或泄露弹窗。
- [x] 未定价日期/分项和混合币种不进入数值折线或比例条，不被画成 0，也不隐含汇率换算。

## H. Windows 10/11 参赛端

- [x] 跨平台单元检查覆盖 Codex 增量/fork、Claude Code 去重、精确分项拒绝、context-window sentinel、安装时固定 HTTPS origin、配置损坏/升级换 origin/凭据 origin 不匹配时失败关闭、HMAC 金向量、服务端记账响应、分片、连接前凭据探测、严格非敏感状态、安静计划任务和无命令行接入码，共 26 项通过。
- [x] 首版范围明确为 Codex / Claude Code 采集、DPAPI 安全连接、手动/计划任务自动同步、状态/预览和打开公榜；不采集 CC Switch，也不声称具有 macOS 同级完整桌面明细。
- [x] CLI 不提供 `--code` 参数，接入码使用隐藏输入；不同设备各自登记并使用独立凭据。
- [ ] 在真实 Windows 10/11 完成安装、DPAPI round-trip、计划任务、双设备上榜、重登记轮换和卸载 E2E。

## I. 运维

- [x] 一条命令启动开发环境。
- [x] SQLite 备份恢复及 PostgreSQL 初始化、迁移、回滚/再升级、schema 漂移和 MVCC 并发已演练。
- [x] 健康与就绪检查可区分进程存活和数据库可用。
- [x] readiness 只验证数据库与最新迁移列；公开社群缺失或歧义由匿名路由独立返回 404，不把可选公榜配置误报为数据库未就绪。
- [x] 日志不包含 secret、Authorization、签名或上报正文。
- [x] 速率限制、请求大小、持久行配额和过滤前公开扫描硬上限生效。
- [ ] 50 人邀请测试完成，并连续运行至少 14 天，P0/P1 为 0。
