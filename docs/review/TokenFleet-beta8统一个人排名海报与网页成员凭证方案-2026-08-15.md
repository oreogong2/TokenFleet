# TokenFleet beta.8 统一个人排名海报与网页成员凭证方案

日期：2026-08-15（Asia/Singapore）
状态：**设计已由 Claude 有条件放行；实现和本地门禁已完成，待固定最终 SHA 的独立代码复核。本文件不是部署授权。**

## 1. 已确认的产品规则

### 公开访客

- 可以匿名打开公开榜 `/rank`、筛选榜单、打开已公开成员的 `/rank/p/<public_id>` 页面，以及从页面进入“安装与参与”。
- 只能查看管理员已公开的聚合信息；不会获得邀请码、设备码、成员后台权限、设备信息或工作内容。
- **不显示、也不能调用任何生成海报的入口。** 不再有“今日榜单”“当前榜单”“参与人数”这类泛排行榜海报。

### 已接入社群的成员

- 可以在 Swift App 的“社群榜”生成自己的排名海报。
- App 打开网页总榜时，网页只对该已验证成员显示“分享我的排名”。
- App 打开的本人公开资料页也可显示同一入口；手工打开别人的公开资料页不能分享。
- 三处入口都必须生成**同一类个人海报**：左侧仅昵称和 Token，右侧为 `#排名 / 总人数`，下方为 Top 10、二维码和 slogan。不能存在第二种泛榜海报。

### 海报二维码

- 二维码只编码**公开的本人资料页**（相同日期口径、统一的全部工具／全部模型 Token 榜），不携带成员凭证、邀请码、设备码或设备 secret。
- 非成员扫码后看到该公开资料页，可返回公开榜和“安装与参与”；扫码不自动加入社群。

## 2. 起草现场与必须修正的问题（历史）

截至本方案起草时，正式仓库当前工作树为干净的 `ed2fb8a`，只有未跟踪工具缓存 `.playwright-cli/`。这个提交只处理了浏览器旧 CSS 缓存导致 Canvas 海报预览错位的问题，**没有实现本方案**。

当前 Web 仍存在两条与上述规则冲突的旧路径：

1. `web/community-app.js` 的总榜渲染仍有 `share-leaderboard`／“分享排行榜”，会生成“当前榜单 + 参与人数”的泛榜海报。
2. 已公开成员资料页的 `share` 按钮只依据 `public_id` 展示；任何匿名访客手工打开该页都可以为该成员生成海报。

Swift App 的“分享排名”已经是本人海报，但 App 打开外部总榜时只打开普通公开 URL，网页没有可靠方式知道访问者是谁。不能用 URL 参数、localStorage、Cookie 或二维码传递设备 secret 来补这个能力。

## 3. 最终安全协议

### 3.1 仅 App 能签发的短时一次性分享凭证

新增设备签名接口：

`POST /api/v1/devices/me/community-share-grants`

- 请求体为空 JSON；无 query string，沿用现有 `X-Device-ID`、`X-Timestamp`、`X-Nonce`、`X-Signature` HMAC 验证和 nonce 防重放。
- 仅允许：设备和成员均启用、属于配置的公开社群、成员已开启公开资料、当前确有可分享的公开排名；这些条件在签发与兑换时都强制复核。
- 以 CSPRNG 生成**至少 32 随机字节**、base64url 编码的不透明 grant；`grant_hash` 唯一冲突时必须重新生成。响应只返回 grant、过期时间和本人 `public_id`，并设 `Cache-Control: no-store`。原始 grant 只返回这一次，服务端只保存 SHA-256 哈希。
- grant 有效期固定为 **120 秒**，只允许兑换一次；同一设备再次签发时作废该设备尚未使用的旧 grant。不同设备仍可分别为同一既有成员签发，不创建成员、设备或邀请码。创建 grant 不上传用量、不改变成员／设备／排名。

为保证真正一次性，新增 `community_share_grants` 表和 Alembic migration，而不是用可重放的签名 URL：

| 字段 | 用途 |
| --- | --- |
| `id` | 内部 UUID |
| `org_id`、`user_id`、`device_id` | 绑定原成员与签发设备 |
| `grant_hash`（唯一） | 只存哈希，禁止存原码 |
| `expires_at`、`consumed_at`、`created_at` | 短时、一次性和审计边界 |

过期／已用／已禁用／不公开时统一不给网页成员态；服务端、Swift 的 LifecycleLogger、错误横幅和任何 debug 输出不得记录 grant、含 fragment 的完整 URL 或签发响应体。

### 3.2 App 打开网页的安全交接

App 成功取得 grant 后，只在 URL fragment 中打开：

`https://<已验证社群域名>/rank#/rank?share_grant=<opaque>`

- fragment 不会随首个 HTTP 请求、Referer 或二维码发给服务器。
- 网页启动的第一件事是读取 fragment 中的 grant，使用 `history.replaceState` 立刻删除 `share_grant`，保留普通 `/rank` 和筛选条件。
- 网页随后同源 `POST /api/v1/public/community-share-grants/redeem` 兑换一次，兑换接口只返回最少的 `{ public_id }`；不创建登录态、不写 Cookie、不写 localStorage/sessionStorage，也不添加 CORS 头。
- 兑换成功后的 `public_id` 只保存在页面模块级 JavaScript 内存：它跨 `#/rank` 与本人 `#/rank/p/<id>` 的内部 hash 路由保留，但 `pagehide`、刷新、回退到新文档或新开普通标签页即消失。不得用 sessionStorage 解决路由切换后丢态的问题。
- 兑换接口有独立的 IP 限流、每设备签发限流与 `Cache-Control: no-store`。消费必须以同一事务的原子 `UPDATE ... SET consumed_at = now WHERE grant_hash = ? AND consumed_at IS NULL AND expires_at > now AND <设备/成员/公开状态/排名仍有效> RETURNING ...` 完成；SQLite 与 PostgreSQL 并发时只能有一个赢家。

这条 bridge 只授予“在本标签页为**本人**生成已经公开的聚合排名海报”的能力；不授予后台、上传、改资料或查看任何非公开信息的权限。

### 3.3 网页界面规则

| 页面与访问方式 | 分享入口 | 能生成的内容 |
| --- | --- | --- |
| 匿名 `/rank` | 无 | 无 |
| 匿名 `/rank/p/<他人或本人 public_id>` | 无 | 无 |
| App + 有效 grant 打开的 `/rank` | “分享我的排名” | 仅 grant 所属成员的个人海报 |
| App + 有效 grant 打开的本人资料页 | “分享我的排名” | 同一张个人海报 |
| App 原生社群页 | “复制排名海报／保存排名海报 PNG” | 同一张个人海报 |

实现时删除 `share-leaderboard`、泛榜 `leaderboard` hero 分支及“可分享当前筛选口径的公开排行榜”文案。`buildCommunityPosterModel` 必须要求 `focus` 为已认证的本人；没有本人上下文即拒绝生成，而不是回退为泛榜。

公开资料页仍然可被任何人浏览；按钮显示条件必须是 `viewerPublicID === route.publicId`，而不是“页面上存在 public_id”。总榜按钮也只能使用已兑换的 `viewerPublicID`，并重新读取该 ID 的公开资料来画海报，不能由 DOM 的任意排行榜行指定对象。

无论从哪一处生成，二维码都使用普通、无 grant 的 `#/rank/p/<viewerPublicID>?period=<period>&metric=tokens` URL。工具／模型微筛选不进入海报，避免 Top 10 只剩极少条目；网页海报与 Swift 海报需锁定相同字段顺序、单位、`#rank / total` 规则、Top 10 和底部文案；图形实现可不同，但不得再出现泛榜格式。

## 4. 实施范围和失败行为

### 需要改动

- FastAPI：schema、设备签名签发接口、无登录兑换接口、grant 数据模型／Alembic migration、按 `expires_at` 索引的惰性或定时清理、限流和服务端测试。
- Swift：设备签名客户端、只接受可信 HTTPS 固定 origin 的 URL 拼装、`openCommunityLeaderboard` 与设置入口的异步开页流程、pending 态与中性失败提示；截图环境一律不签发／不开外部网页。日志和用户提示不得包含 grant、fragment URL 或签发响应体。
- Web：fragment 清理与兑换、跨 hash 路由但不跨刷新／新标签的模块级内存成员态、删除泛榜分享入口／模型分支、个人页 owner guard、统一海报和浏览器 E2E。
- 文档：更新安装／隐私／帮助／验收报告，明确“公开可看”与“成员才可分享”的区别，并显著说明：普通浏览器手工打开自己的公开页不会出现分享按钮，须从 App 打开；注明这是一项带 migration 的后续生产兼容部署。

### 明确失败边界

- grant 过期、已使用、网络失败或服务器拒绝：页面仍可匿名浏览，但**不显示分享入口**；不伪造本人身份、不降级生成泛榜海报。
- 成员关闭公开资料、设备／成员被禁用、没有排名：App 不签发 grant；已签发但尚未兑换的 grant 在原子兑换条件中再次检查并拒绝。
- 两个设备同时打开：各自可签发独立 grant，但每个 grant 只能兑换一次；它们都绑定同一 `user_id/public_id`，不创建重复成员。
- 用户复制／转发 bridge URL：获得的人也只能在 120 秒内兑换一次并生成该成员**已公开**的海报；不会获得设备码或其他账户能力。fragment 在页面加载后即被清掉。该有限公开风险已在设计复核中确认可接受。

## 5. 验收与发布门槛

### 自动化

1. Server SQLite + PostgreSQL：无签名 401、无效签名 401、CSPRNG grant 长度／编码、唯一冲突重试、原码不入库、非公开／禁用 403、签发后关闭公开资料再兑换 403、签发后停用设备再兑换 403、过期拒绝、重复兑换拒绝、并发只有一次成功、响应／日志不回显、migration upgrade/downgrade 和按 `expires_at` 清理。
2. Swift：签名请求路径／方法／无 query、grant 不含 device secret、只允许固定 HTTPS origin、截图模式禁止、日志／错误提示不含 fragment 或签发响应、pending 态与失败正常打开匿名榜且不称“已验证”、旧服务器 404 降级。
3. Web 单测和真实浏览器：匿名总榜／资料页无按钮；有效 grant 立刻从地址栏和 history 清除；模块内存态可跨榜单与本人资料页、刷新必丢失；根页和本人资料页均生成同一 `1200 × 1600` 个人海报；按钮不能指定别人；QR 解析为无 grant 的公开本人页；加载失败仍禁用复制／保存；旧泛榜文案与 `leaderboard` 海报分支不存在。
4. 回归：既有单批 50、多批 100／200、1／2／4 设备、补码、beta.7→beta.8 原地升级、公开榜、费用、隐私和现有 Web／Swift／Windows／universal 门禁全部重跑。

### 部署

此方案引入一张可追加的 grant 表，因此不能把现有“无 migration 的 beta.8 服务升级”当作本次证据。生产动作必须单独执行：

1. 固定最终 SHA；独立只读复核；新 CI 全绿。
2. 先创建并校验 PostgreSQL 归档备份，再在隔离发布目录执行 Alembic upgrade head。
3. 先验证旧 App 仍能同步、匿名榜可读、无凭据接口仍拒绝；再用已接入真实成员实测 App→网页 grant、匿名无入口、个人海报和 QR。
4. 保留上一发布目录并支持代码软链回退；**数据库 migration 不执行 downgrade／覆盖恢复**，除非先在副本演练并得到明确授权。迁移本身也会在已有 grant 记录时拒绝 downgrade，避免静默丢失审计记录。
5. 不合并 PR、不建 beta.8 tag、不发布 DMG 或在线更新，除非另有授权。

## 6. 对刚才 Claude 复核结论的处理说明

奥哥转述的 Claude 只读报告结论是：当时核对对象 P0/P1 为 0，已有生产服务契约、原地升级、多设备／批次、1200×1600 海报载入门禁和四项 CI 有证据；P2 包括 `.playwright-cli/` 未跟踪、少量文档历史措辞和报告 SHA 表述。这些结论作为**历史证据**保留，但不替代本方案之后的新精确 SHA 复核。

本次逐项处理结果：

| Claude 结论／发现 | 当前处理 |
| --- | --- |
| `.playwright-cli/` 仅为未跟踪工具缓存，不应进入提交 | 保留为本地缓存；实现提交时明确 `git add` 指定文件，后续补 `.gitignore` 或清理方案，绝不 `add -A`。 |
| Canvas 海报预览可能因旧 CSS 缓存错位／破图 | `ed2fb8a` 已增加样式版本号和布局浏览器断言；但这次会删除泛榜海报，不以该修复当作统一个人海报验收。 |
| 已有 App／服务端兼容、多设备、批次和升级证据 | 不改这些业务路径；新 grant 只绑定既有 `user_id`、既有设备签名，新增测试必须证明不新增成员／设备、不触碰 usage。 |
| 当前泛榜分享在技术上能生成文件 | 产品规则已否决：删除。能生成不等于应保留。 |
| 生产服务已部署旧 beta.8 契约 | 本方案需要新的 FastAPI 接口和 migration；在最终代码／CI／独立复核和新的备份前，**不部署**。 |
| 当前报告与分支 SHA 可能已被后续文档／修复提交推进 | 本文件只记录方案起草现场；最终报告必须重新读取 branch、PR、remote、CI 和 tags，不沿用旧 SHA。 |

## 7. 请 Claude 重点复核的问题

1. 一次性 opaque grant + 哈希入库 + fragment 立即清理，是否足以满足“网页不暴露设备 secret、匿名不能分享”的安全边界？120 秒 TTL 与兑换时强制状态复核是否恰当？
2. 是否同意 grant 仅代表已公开的本人 `public_id`，不创建 Cookie／登录态，不包含任何私有数据？
3. 是否同意所有泛榜海报路径完全删除，根榜和个人资料页只在 `viewerPublicID === targetPublicID` 时显示分享？
4. Alembic 新表的约束、索引、事务／并发兑换、过期清理和回退边界是否完整；是否存在无需 migration 的更安全等价方案？
5. Swift 对 URL fragment 的构造、截图禁用、失败降级和固定 HTTPS origin 是否会泄露 grant 或产生假按钮？
6. 请只对最终精确 SHA 验收，分别验证匿名、已接入成员、已禁用成员、过期／重放 grant、不同成员资料页和 QR 扫码结果。

## 8. 审核通过后的执行顺序

1. 先按本方案实现 server / Swift / Web 和 migration，不改 beta.2–beta.7 tag 或历史。
2. 全量测试、实际浏览器 E2E、实际 App 点击、独立只读复核。
3. 推送等待新 CI；将最终 SHA、测试证据、数据影响和回滚路径发给奥哥与 Claude 复核。
4. 仅在奥哥基于最终差异再次确认后，执行带备份的生产部署；否则保持当前线上版本。

## 9. Claude 设计复核结论与纳入结果

2026-08-15 的独立只读设计复核结论为 **Go（有条件）**：架构方向正确、无 P0，但必须先完成下列四项 P1 才能开工。它们已纳入本文件第 3～5 节：

1. CSPRNG 至少 32 字节、base64url、哈希唯一冲突重试和测试断言。
2. 兑换时对设备／成员／公开状态／排名的强制复核，并在同一原子消费条件中执行。
3. App 侧日志、错误横幅和 debug 输出同样不得泄露 grant、fragment URL 或签发响应。
4. viewer 身份只放模块级内存，以跨 SPA hash 路由；刷新和新标签页丢失，禁止用 sessionStorage 补救。

复核的 P2 也已采用：120 秒 TTL、同设备新 grant 作废旧未用 grant、原子 UPDATE 消费、旧服务 404 降级、`expires_at` 索引与清理、默认同源无 CORS，以及在帮助文案说明“手工打开公开页没有分享按钮”。

因此本文件是本次实现的**设计基线**。当前工作树已实现：CSPRNG 32 字节 opaque grant、120 秒 TTL、哈希入库、同设备重签作废旧未用 grant、原子兑换与状态复核、Swift 签名签发／fragment 开页和失败降级、Web 内存 viewer 态及泛榜海报删除。服务端全量、Web 单测、真实浏览器 E2E 和 Swift 完整门禁已在未提交工作树通过；仍必须先固定最终 SHA，再由 Claude 做独立验收。设计或本地测试 Go 都不等于代码／部署 Go。
