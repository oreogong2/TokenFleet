# TokenFleet 部署与运维手册

状态：SQLite 单实例试运行就绪；PostgreSQL 17 的本地真实迁移与双连接并发门禁已通过，目标生产环境仍未完成安全部署验收。

## 1. 推荐部署形态

### 1.1 5–10 人社群试运行

- 一台受控 Linux/macOS 主机；
- 单个 FastAPI 进程；
- SQLite 数据库放在加密磁盘；
- 由 Caddy/Nginx/云负载均衡终止 TLS；
- 每日自动备份，保留至少 14 天；
- 管理员、私有账本和写入端点只允许经认证访问；匿名只读 `/rank` 与
  `/api/v1/public/*` 可经 TLS/WAF 对外开放，并使用独立限流与扫描上限；
- 不把 Token 用量用于绩效评价。

### 1.2 生产部署前必须补齐

- 在目标 PostgreSQL 版本与网络环境重跑迁移、双连接并发 upsert/deadlock smoke；
- **多实例发布阻断：** 在网关或 Redis 落地并验证共享登录限流；没有共享限流
  证据时只允许单进程，禁止多 worker/多主机上线；
- 数据库、备份和派生 device signing key 的静态加密；
- 集中审计、告警和恢复演练；
- 5–10 人连续 14 天试运行，P0/P1 为 0。

## 2. 安全配置

服务端完整环境变量见 `server/README.md`。生产至少要求：

```bash
export ENVIRONMENT=production
export DATABASE_URL='postgresql+psycopg://tokenfleet:REDACTED@db/tokenfleet'
export JWT_SECRET='至少 32 字节、来自密钥管理系统的随机值'
export PUBLIC_ORG_SLUG='your-team'
export PUBLIC_RATE_LIMIT_ATTEMPTS='30'
export PUBLIC_RATE_LIMIT_WINDOW_SECONDS='60'
export PUBLIC_MAX_SCAN_ROWS='250000'
export PUBLIC_CACHE_TTL_SECONDS='15'
export PUBLIC_CACHE_MAX_ENTRIES='1024'
export TRUSTED_PROXY_CIDRS='10.0.0.0/8'
export TRUSTED_PROXY_HOPS='1'
```

- 不把 `JWT_SECRET`、数据库密码或设备 signing key 写入 Git、镜像层或工单；
- TLS 代理必须禁止明文 HTTP 回源被公网直接访问；
- 同源 Web/API 响应统一带 CSP、禁止 framing、`nosniff`、最小 referrer 与
  Permissions Policy；生产 HTTPS 响应必须带 HSTS；TLS 在代理终止时仅信任与
  `TRUSTED_PROXY_CIDRS`/`TRUSTED_PROXY_HOPS` 匹配的 `X-Forwarded-Proto`；
- 设备客户端拒绝重定向并只接受 HTTPS origin；
- Web 会话令牌仅在 `sessionStorage`，关闭标签页即清除；
- 生财 OpenToken 的个人 URL/secret 不进入 TokenFleet 客户端、服务端或日志。
- `PUBLIC_ORG_SLUG` 为空时匿名社群榜返回不存在；公开 API 不接受请求指定组织，
  只投影 active、显式公开、exact、非删除的唯一社群数据。
- 匿名成功响应按组织、日期范围、筛选和 `ledger_version` 使用短时公开缓存；默认
  15 秒、最大 300 秒。公开错误继续 `no-store`，网关不得覆盖该策略长期缓存。
- Mac 正式包另需把同源 canonical HTTPS origin 写入签名 Info.plist；成员界面不能
  覆盖服务器地址。

服务内存登录限流只覆盖当前进程，无法统计其他 worker/实例的请求。发布审批
必须记录“单进程”拓扑，或提供网关/Redis 共享限流的配置与跨实例 `429` 验证；
单元测试中的进程内 `429` 不能关闭这项生产门禁。

## 3. 初始化与启动

在 `server/` 下执行：

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt -c constraints.txt
.venv/bin/alembic upgrade head
.venv/bin/python -m app.cli create-admin \
  --org-slug your-team \
  --org-name 'Your Team' \
  --email admin@example.com
PUBLIC_ORG_SLUG='your-team' \
  .venv/bin/uvicorn app.main:app \
    --host 127.0.0.1 --port 8000 \
    --proxy-headers --forwarded-allow-ips='<LB CIDR>'
```

`<LB CIDR>` 必须替换为实际负载均衡/反向代理出口 CIDR，并与
`TRUSTED_PROXY_CIDRS` 一致；`TRUSTED_PROXY_HOPS` 必须等于从入口到应用的可信
代理跳数。未配置这两个应用参数时，TokenFleet 忽略转发头，并用直连 TCP
对端作为应用内 per-IP 登录/公开读取桶；若直连对端实际是反向代理，所有请求会
按代理地址共桶，因此生产代理部署必须配置这两个参数并保留网关限流。缺失或
畸形的可信转发链直接返回 `400`，不会绕过限流或进入全局共享桶。当前 CIDR
信任模型要求代理用 TCP 回源；Unix socket 不提供可验证的对端 IP，不作为支持的
生产拓扑。

管理员密码由终端无回显输入。Web 默认与 API 同源挂载；生产由 TLS 代理暴露。启动后检查：

```bash
curl -fsS https://tokenfleet.example.com/healthz
curl -fsS https://tokenfleet.example.com/readyz
curl -fsS 'https://tokenfleet.example.com/api/v1/public/leaderboard?period=today&metric=tokens'
```

`healthz` 只表示进程存活；`readyz` 还验证数据库已迁移并可查询。公开榜返回的
估算费用只来自管理员显式标记 `public_estimate=true` 的价格版本；旧价格默认私有。

## 4. SQLite 备份与恢复

### 4.1 在线一致性备份

不要直接复制正在写入的数据库文件。使用 SQLite backup API：

```bash
sqlite3 /srv/tokenfleet/tokenfleet.db \
  ".backup '/srv/tokenfleet/backups/tokenfleet-2026-08-09.db'"
shasum -a 256 /srv/tokenfleet/backups/tokenfleet-2026-08-09.db
```

备份目录需要独立权限、加密和异机副本。不要把校验和当作加密。

### 4.2 恢复演练

先恢复到新路径，不覆盖现有数据库：

```bash
sqlite3 /srv/tokenfleet/restore/tokenfleet.db \
  ".restore '/srv/tokenfleet/backups/tokenfleet-2026-08-09.db'"
sqlite3 /srv/tokenfleet/restore/tokenfleet.db 'PRAGMA integrity_check;'
DATABASE_URL='sqlite:////srv/tokenfleet/restore/tokenfleet.db' \
  .venv/bin/alembic current
```

只有 `integrity_check` 返回 `ok`、迁移版本正确且抽样查询一致后，才在维护窗口切换 `DATABASE_URL`。

## 5. PostgreSQL 备份与恢复

以下是标准操作模板，当前仓库尚未在真实 PostgreSQL 上完成恢复演练，因此不能作为已验证证据：

```bash
pg_dump --format=custom --file=tokenfleet.dump "$DATABASE_URL"
createdb tokenfleet_restore_check
pg_restore --no-owner --dbname=tokenfleet_restore_check tokenfleet.dump
```

恢复后执行 `alembic current`、`readyz`、租户隔离查询和双设备 upsert smoke。

## 6. 升级与回滚

升级顺序：

1. 冻结发布 commit 和依赖 `constraints.txt`；
2. 做一致性备份并记录 SHA-256；
3. 在副本数据库执行 `alembic upgrade head` 和测试；
4. 维护窗口停止旧进程；
5. 迁移生产库并启动新进程；
6. 检查 `healthz`、`readyz`、登录、两设备幂等上报和 Web 总览；
7. 观察错误率和未定价行。

回滚优先回退应用代码。只有迁移明确可逆且已在副本演练时才执行 `alembic downgrade`；任何可能丢数据的迁移都必须恢复备份，不能冒险逆向修改生产库。

## 7. 留存与删除

组织的 `retention_days` 只是策略值，实际删除由外部调度：

```bash
# 预览，不删除
.venv/bin/python -m app.cli purge-retention

# 在审批/审计后执行
.venv/bin/python -m app.cli purge-retention --apply
```

保留每次命令的 JSON 输出。成员禁用只阻止登录和新上报，不删除历史；设备禁用同理。

服务端写入路径也执行同一条排他截止线：按组织 `default_timezone` 的本地今天
计算 cutoff，`date < cutoff` 的 active/tombstone 都返回 processed `unchanged`
且不落库，边界日仍接受。purge 会物理移除截止线前的活动行和隐藏 tombstone
marker；即使客户端随后 force 重传旧 exact 桶，也不会复活已过留存期的数据。

## 8. 凭据与人员变更

- 参赛者退出：先关闭公开或禁用参赛者，再禁用名下设备；公开页立即消失，私有历史保留到组织留存期；
- 新参赛者不创建邮箱、密码或微信身份；管理员只填昵称，生成默认 60 分钟、
  最长 24 小时的一次性接入码。第二台设备为同一参赛者重新生成新码；
- 设备丢失：禁用该设备；同一安装重新登记会复用设备身份、轮换独立 secret，历史不会复制成第二台设备；
- device secret 不提供找回，怀疑泄露时禁用并重新登记；不要清除客户端的非敏感安装 ID，否则应按新设备处理；
- 轮换 `JWT_SECRET` 会使全部 Web 会话失效，应安排维护通知；
- 不通过日志、截图或聊天发送 enrollment token/device secret。

## 9. 监控与告警

至少监控：

- `readyz` 非 200；
- 登录 429/401 激增；
- 用量上报 401/403/409/422/5xx；
- nonce 重放与时钟偏差；
- 数据库空间和备份新鲜度；
- 私有管理端 `unpriced_rows` 增长；匿名响应只暴露未定价布尔状态；
- 匿名公榜 429、扫描上限 `503` +
  `public_projection_scan_limit_exceeded` 和异常 tool/model 标签；
- 客户端 `last_successful_sync_at` 长时间不更新。

应用日志不得记录 Authorization、签名、设备 secret、上报正文或生财凭据。
官方客户端只发送聚合 schema；服务端拒绝显式内容字段和控制/格式字符，但无法
从语义上证明恶意已登记客户端未将敏感信息编码到合法标签。发现异常标签时按
凭据泄露处理：禁用设备、轮换登记凭据并保留脱敏审计证据。

## 10. 事故处理

- 社群服务故障：客户端继续本地统计并退避重试；生财官方 OpenToken 链路不受影响；
- 误配置价格：新增正确的生效版本，不直接改写已冻结历史价格；
- 客户端解析异常尖峰：先隔离异常设备/桶，不把数据用于绩效；保留原始本机日志以便用户自行重算，不上传日志正文；
- 数据泄露怀疑：禁用受影响成员/设备、轮换 JWT、隔离数据库与备份、保留审计证据并按适用制度与法规通知。
