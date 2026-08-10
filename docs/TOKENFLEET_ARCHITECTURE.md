# TokenFleet 架构与同步协议

## 1. 组件

```text
┌──────────────────────── macOS ────────────────────────┐
│ Codex / Claude Code / CC Switch 本地日志              │
│                   │                                   │
│          TokenStep collector                          │
│          ├─ 本地 usage.json / 本地 UI                 │
│          └─ TeamSync（仅日聚合、离线队列）            │
└───────────────────┬───────────────────────────────────┘
┌────────────────────── Windows 10/11 ──────────────────┐
│ Codex / Claude Code 本地 JSONL                        │
│          └─ CLI 预览 + TeamSync + 计划任务            │
└───────────────────┬───────────────────────────────────┘
                    │ HTTPS + device HMAC
                    ▼
┌──────────────── TokenFleet Server ────────────────────┐
│ Enrollment │ Auth/RBAC │ Usage ledger │ Pricing       │
│ Org/Participant/Device │ Idempotent upsert │ Audit    │
│          Private ledger ──> Public projection          │
└──────────────┬──────────────────────┬──────────────────┘
               │ scoped private API   │ anonymous read-only API
               ▼                      ▼
          Admin dashboard       Single community rank

独立链路：官方 OpenToken ──> 生财排行榜
```

## 2. 设备注册

管理员创建一个容量 1–50 人、有效期 1–24 小时且可关闭的 InvitationBatch。原始批次
令牌只返回一次，数据库只保存 SHA-256；同一组织内昵称按 NFKC + casefold 归一化并由
数据库唯一索引兜底。成员持批次链接填写昵称并明确同意公开后，服务端在锁定批次行的
同一事务里创建非登录参赛者、个人 60 分钟单次 enrollment token，并把
`claimed_count` 加一；任一步失败整体回滚。满额、关闭、过期和无效令牌统一返回
“批次不可用”，不暴露内部状态。服务端不为参赛者伪造邮箱、密码或微信身份。

首版不接微信、会员或开放匿名注册：社群管理员只把受限批次 HTTPS 链接发给受邀
成员。`/join/batch#invite=...` 在其他模块工作前擦除 fragment，批次令牌只保留于
闭包内存；query/path 形态只擦除、不接受。claim 成功返回的个人设备码同样只保留于
闭包内存，不渲染进 DOM，成员主动点击后才写剪贴板。首版不使用可被其他 App 抢注的
自定义 URL Scheme，也不自动读取剪贴板。邀请码只负责登记一台设备，长期上传使用该
设备独立 secret；分享图和公开网页从不包含批次令牌、enrollment token 或 device secret。

官方 macOS 安装/构建把唯一 canonical HTTPS 社群 origin 写入 App 配置；Windows
安装器把同一类 origin 写入带完整性校验的安装配置。两端通用源码都不硬编码生产
域名，运行时也不允许成员在 `connect` 或设置里覆盖；升级必须保持相同 origin。
两端都拒绝空值、HTTP、userinfo、query、fragment 和 loopback。
成员只在隐藏输入中提交一次性码。连接确认文案必须说明会立即同步当前可验证的
历史日桶，并持续后台同步。`/join` 与 `/join/batch` 读取 fragment 后立即调用
`history.replaceState` 清掉地址栏/历史中的码，并在 `pagehide` 清空内存。

客户端提交：

```http
POST /api/v1/devices/enroll
Content-Type: application/json

{
  "enrollment_token": "one-time-token",
  "device_public_id": "stable-installation-uuid",
  "platform": "macos",
  "app_version": "0.2.0",
  "collector_version": "0.2.0"
}
```

服务端只在这次响应返回 `device_secret`。macOS 客户端写入 Keychain；Windows 参赛端
使用当前用户 DPAPI 加密并禁止 roaming。Windows 的 server origin 只能由安装器写入
安装目录内的非秘密完整性校验配置；`connect` 不接受 server 参数，升级也必须保持同一
origin。普通设置只能保存 device ID 和非敏感状态，不能出现明文 secret。`device_public_id` 在一次客户端安装的生命周期内
保持稳定，即使用户“清除连接”也不删除。同一组织、同一成员用新的 enrollment token
重新登记该 ID 时，服务端复用原 `device_id` 和用量自然键、重新启用设备并轮换
secret；旧 secret 立即失效。该 ID 若已属于另一成员则返回 409，不能转移历史。

Windows 首版采用同一 TeamSync v1 协议，但只采集 Codex / Claude Code 本地 JSONL，
通过当前用户计划任务自动同步；它不采集 CC Switch，也不提供与 macOS 原生 App
等同的完整桌面历史和统计界面。

## 3. HMAC 请求

上报端点：

```http
POST /api/v1/usage/daily
X-Device-ID: <uuid>
X-Timestamp: <unix-seconds>
X-Nonce: <random-uuid>
X-Signature: <lowercase-hex-hmac-sha256>
Content-Type: application/json
```

Canonical string（UTF-8）：

```text
<timestamp>\n
<nonce>\n
<UPPERCASE_METHOD>\n
<path-with-leading-slash>\n
<lowercase-hex-sha256-body>
```

客户端与服务端先计算：

```text
signing_key = SHA256(UTF8("TokenFleet-HMAC-v1:\n") || UTF8(device_secret))
```

签名是 `HMAC-SHA256(signing_key, canonical)`。服务端不保存注册响应里的原始 `device_secret`，只保存 `signing_key`。注意：派生 key 本身足以生成请求签名，数据库和备份仍必须加密并执行最小权限；后续协议可升级为 Ed25519，把服务端凭证降为不可伪造请求的公钥。

服务端要求：

- 时间偏差不超过 300 秒；
- `(device_id, nonce)` 在时间窗内未使用；
- 常量时间比较签名；
- 设备和成员均为启用状态；
- body hash 与原始请求字节一致。

## 4. 日桶上报

请求：

```json
{
  "schema_version": 1,
  "collector_version": "0.2.0",
  "generated_at": "2026-08-09T01:30:00Z",
  "buckets": [
    {
      "date": "2026-08-09",
      "timezone": "Asia/Shanghai",
      "tool": "Codex",
      "model": "gpt-5",
      "source": "local",
      "input_tokens": 120,
      "output_tokens": 80,
      "cache_read_tokens": 1000,
      "cache_write_tokens": 50,
      "completeness": "exact"
    }
  ]
}
```

协议中的 `input_tokens` 是未命中缓存的输入。TokenStep 采集内核的原始 `inputTokens` 包含缓存读写，所以客户端映射必须使用 `max(0, rawInput - cacheRead - cacheWrite)`；映射后四字段合计才与 TokenStep `totalTokens` 守恒。无法满足守恒的 fallback/旧桶不得伪造精确分项，且不参与费用估算。

`deleted` 是向后兼容的可选布尔字段，缺失时等同 `false`，tombstone 沿用原自然键、四类 Token 全为 `0`，并使用 `completeness: "exact"`、`deleted: true`。服务端保留该协议与持久化能力，但 macOS 客户端 v1 **不自动生成 tombstone**：本地 snapshot 只证明“本轮看见了什么”，无法可靠证明 Claude/Codex/CC Switch 某一采集源的同日覆盖健康。即使同日仍有其他 exact 桶，缺失 key 也可能只是数据源暂时不可用；普通同步和 force 都不得据此删除服务端历史。

未来只有在协议增加可验证的权威覆盖/删除证明后，客户端自动删除才可另行启用。届时服务端继续保证 `created + updated + unchanged == buckets.count`：首次持久化删除版本（包括活动行已不存在但还没有 marker）计入 `updated` 并推进 ledger，已有同版或更新 marker 才计入 `unchanged`。同一版本 active/tombstone 冲突时 tombstone 优先；只有严格新于 marker 的 exact active 才允许显式复活。这样较旧的离线 upsert 不能复活已删除数据。

服务端还在 ingest 时按组织 `default_timezone` 的本地日历今天计算
`cutoff = today - retention_days`。`date < cutoff` 的 active 或 tombstone 都计入
`unchanged` 但不写库，`date == cutoff` 仍可处理；因此外部 purge 物理移除旧行和
旧 marker 后，客户端 force/离线重传也不能绕过留存策略把历史复活。

客户端不会新建或重传删除标记。早期预发布状态若已有 `__deleted__`，缺失时原样保留且 force 也不发送；相同 key 后续重新出现时，只发送普通 exact upsert，并在成功后以内容 hash 覆盖旧标记。

约束：

- Pydantic/Swift decoder 对未知字段失败；
- 数值为 `0...9_000_000_000_000_000`；
- tool/model 去首尾空白后长度 `1...128`；
- tool/model/source 禁止 Unicode 控制、格式、代理项和行分隔字符；
- tombstone 必须四类 Token 全为 `0`；
- 每次最多 2,000 桶；
- 日期不能早于 5 年前或晚于接收日 2 天；
- 时区必须是已知 IANA 标识；
- 同一个请求内的自然键不能重复。

官方 TokenFleet 客户端只构造上述聚合字段，服务端也没有 prompt、回复、代码、
路径、项目或会话正文的 schema 字段。未知字段拒绝可以验证协议形状，但无法
证明恶意或自行修改的已登记客户端没有把敏感内容编码进允许的文本标签；因此
enrollment、设备签名密钥、禁用和异常标签监控仍是系统信任边界。

自然键：

```text
(org_id, user_id, device_id, date, timezone, tool, model, source)
```

`completeness` 是桶的覆盖字段，不进入自然键；这样同一个桶从 `fallback_estimate` 升级为 `exact` 时会替换旧值，而不会并存双算。同一自然键再次上报执行覆盖式 upsert。响应返回 `created`、`updated`、`unchanged` 和非负服务端账本版本；客户端必须验证 processed 三项之和等于本次桶数。`ledger_version == 0` 是合法成功，例如请求中的桶全部落在留存线外、计入 `unchanged` 但服务端账本尚无持久化变更。

客户端持久化 hash 时使用 U+001F 分隔 `date/timezone/tool/model/source`，所有新组件都禁止包含该分隔符。v1 不解析缺失 key 来推断删除；任何已持久化但本轮缺失的自然键（包括旧状态中不透明的 key）都原样保留。

## 5. 查询作用域

- admin：社群总览、全员、全设备、价格、保留策略；
- participant：没有 Web 登录态；只通过设备 HMAC 写入本人设备用量，并读取公开榜；
- legacy member：既有可登录成员仅作向后兼容，只能访问自己的汇总和设备；
- 设备密钥：只能写本设备用量和读取最小同步状态，不能读取团队数据。

所有私有数据库查询先施加 `org_id`，再施加角色作用域。不能依赖前端隐藏字段
实现隔离。参赛者记录仍复用租户 User 表，但 email/password 必须成对为空，且没有
session；管理员账号继续要求唯一邮箱与密码哈希。
新增邮箱/密码登录账号只允许 `admin`；既有可登录 legacy member 继续兼容读取与
登录，但不能再通过用户创建接口扩张。

### 5.1 单一社群公开投影

公开榜不是把私有 dashboard API 去掉鉴权，而是一层字段白名单严格更小的只读投影：

- 服务端只读取部署时显式配置的唯一公开组织；配置为空时公开端点返回不存在；
- 请求不接受 `org_id`、`org_slug`、`user_id` 或 `device_id` 作为公开查询参数；
- 只有 `User.is_active == true && public_profile_enabled == true` 的成员进入投影；
- `public_id` 是独立随机稳定标识，公开响应不返回内部用户、组织或设备 ID；
- 聚合只使用未删除且 `completeness == exact` 的日桶；
- `tokens` 是四类 Token 合计，`norm` 是 `input + output`，`cost` 是有冻结价格的
  估算费用；只有管理员显式标为 `public_estimate` 的价格版本可以进入公开投影，
  既有私有/协议价默认不公开；只返回未定价状态，不按零计，也不暴露底层行数；
- 可筛选时间范围、工具、模型与三种统计口径，不支持城市；
- 公开成员页只返回日趋势、工具、模型、四类 Token、估算费用和连续活跃等可从
  日桶诚实派生的字段，不返回逐小时、会话、消息、设备或内部同步状态；
- 关闭公开或禁用成员后，公开详情立即按不存在处理；私有账本历史不删除。

公开榜的读取限流、响应体上限和缓存只能作用于同一份白名单响应。缓存 key 必须包含
配置组织、日期范围、口径、工具、模型与公开账本版本，不能让 A 组织的结果被 B 组织
复用。

### 5.2 分享海报

Web 端从公开 API 已返回的数据在浏览器本地绘制 PNG，不调用带登录态的服务端截图：

- 只画公开昵称、名次、Token、估算费用、筛选口径、Top 10 和本人公开位置；
- 二维码/链接只能指向 canonical HTTPS 公开榜，无 token、secret、userinfo、内部 ID
  或认证 query；
- 昵称、工具与模型先经过长度/Unicode 控制字符验证并按纯文本绘制；
- 图片生成失败不得影响榜单浏览，也不得退化为调用第三方截图或二维码服务。

### v1 时区限制

v1 传输的是客户端账务日桶，因此范围查询按 `date` 过滤，并原样保留 `timezone`。当前上游 TokenStep 0.1.48 的账务日固定为 `Asia/Shanghai`，本轮为兼容历史不静默改成系统时区。组织时区用于默认日期和展示；当结果含多个时区时，服务端返回时区警告，界面提示“按各客户端原账务日汇总”。v1 不支持把日桶无损转换到另一个时区。需要系统时区记账或跨时区重归日时，必须设计版本化迁移，并升级为带 `bucket_start_utc` 的 v2 小时桶。

## 6. 断网与重试

- 本地快照仍是个人 UI 真源；团队服务不可用时不影响本地刷新。
- 成功上报后保存每个自然键的内容 hash。
- 未变化桶不重复上传；变化桶覆盖更新。
- 用户手动强制同步时忽略内容 hash，完整重传当前全部 exact 桶，用于修复服务端恢复或丢行；不完整/旧 marginal 仍不得伪造上传。
- v1 对任何本轮缺失 key 都不生成 tombstone；同日其他 exact 来源仍存在、空/部分 snapshot、整天消失以及 force 均不构成删除证明。
- 只有不完整/旧 marginal 日计入同步遗漏；本地已有的 stale hash/旧删除标记保留但不上传，key 重新出现时正常 exact upsert。
- 失败采用带抖动的指数退避，最大 6 小时。
- 408/425/409/429/5xx/网络错误属于 transient，继续退避；force 可显式绕过等待时间，普通自动同步仍须等到 `nextAttemptAt`。
- 其他 4xx 与客户端响应校验失败进入 `requestRejected` terminal，避免毒批次无限自动重试；用户修复数据/升级后可点“立即同步”执行一次 force 恢复。
- 401/403 单独进入 credentials terminal，force 和 UI 都不得绕过，必须清除并重新连接。
- 队列只保存最小聚合，不保存原始日志。

## 7. 版本与迁移

- 本地 `usage.json` 的新增字段必须 optional/default decode，旧版本可读。
- 服务端 API 路径和 payload 都带版本。
- 数据库 schema 使用线性迁移，迁移前必须备份。
- 价格采用不可变版本；历史桶引用计算时使用的价格版本。
