# TokenFleet 排行榜能力展示增强方案 · Claude 复核意见

日期：2026-09-02
复核对象：`docs/review/TokenFleet-排行榜能力展示增强方案-给Claude复核-2026-09-02.md`
复核方式：只读。读了 `server/app/public_projection.py`、`api.py`、`schemas.py`、`rate_limit.py`、`config.py`、`static_web.py`、`deploy/nginx/*`、`web/community-*.js`、`web/tests/*`、`server/tests/test_public_community.py`、`README.md`、`docs/AGENT_SUPPORT.md`、`CHANGELOG.md`，并对线上 `token.ipwriter.com` 做了 6 次只读 GET 实测。未改任何代码，未提交。
代码基线：worktree `codex/windows-parity` HEAD `c683478`，是 `v0.1.0-beta.11` 标签提交 `c5ad1cb` 的直接父提交（标签是 PR #16 合并提交），内容等同 beta.11。注意本 worktree 的本地 `main` 停在 `4071728`（beta.10 时代），实现时不要从本地 `main` 开分支，要从 `v0.1.0-beta.11` 或远端 main 开。

## 1. 结论

**产品口径全部同意，但"纯 web-only"这一条不通过。** 必须把范围扩大到服务端，增加一个轻量只读能力接口。原因不是性能，而是正确性：

- 性能：`period=all` 在线上实测冷请求 0.21 秒（含约 0.15 秒网络往返），服务端真实开销几十毫秒。用现有接口读全历史，成本可以接受。
- 正确性：现有 `available_models` 在服务端硬截断 100 项（`public_projection.py:586`），响应里没有总数字段，前端无法知道被截了。线上全历史模型今天已经是 **90 个**（方案里写的 81 已过时），beta.11 默认开启实验来源后的 180 天回补还在进行，几周内就会碰到 100。碰到后"累计已识别模型 N"会永远停在 ≤100 并丢掉字母序靠后的模型名，而页面仍标"全部"。这正是方案自己定的红线（"不能拿本期列表冒充全部"的同类问题）。

裁决：**方案可进入实现，但要按 §7 的修订清单先改方案，再动手；实现范围 = `web/` + 一个新增的只读接口 + 对应测试，网页与服务端一起部署。** 不改客户端、不改上传协议、不改账本、不动 beta.11 标签，这些边界都保持。

## 2. 线上实测（2026-09-02，直连 47.97.20.13 绕过本机代理）

| 请求 | 状态 | 耗时 | 响应体 |
| --- | --- | --- | --- |
| `/healthz`（网络基线） | 200 | 0.150 s | — |
| `leaderboard?period=all&limit=1`（冷） | 200 | 0.210 s | 2.9 KB |
| `leaderboard?period=all&limit=1`（热） | 200 | 0.339 s | 2.9 KB |
| `leaderboard?period=all&limit=100`（同缓存键） | 200 | 0.197 s | 24.1 KB |
| `leaderboard?period=today&limit=100`（冷） | 200 | 0.311 s | 11.8 KB |
| `leaderboard?period=90d&limit=100`（冷） | 200 | 0.398 s | 23.9 KB |

耗时波动全在网络层，`all` 并不比 `today` 慢。Cache-Control 为 `public, max-age=15, s-maxage=15`，与代码一致。

| 范围 | 工具标签 | 模型标签 | 公开成员 |
| --- | --- | --- | --- |
| 今天 | 4 | 16 | 21 |
| 全部时间 | 9 | **90** | 40 |

全部时间的 9 个工具标签：Claude Code、Claude Code via CC Switch、CodeBuddy、Codex、Grok、Hermes Agent、OpenClaw、WorkBuddy、ZCode。方案写的"6 工具 / 81 模型"已经不是现状。全部榜上单个成员最多 37 个模型、6 个工具。

## 3. 为什么 `period=all` 便宜，以及它的两个天花板

`build_public_leaderboard` 对 `all` 做的事（`public_projection.py:677-785`）：

1. `_enforce_scan_limit`：对公开范围（org + 公开成员 + `completeness='exact'` + 未删除）做一次 `LIMIT 250001` 的计数，超过 `PUBLIC_MAX_SCAN_ROWS=250000` 直接 503。
2. `_available_labels` × 2：对同一范围做 `DISTINCT` 再 `ORDER BY lower(label) LIMIT 100`。
3. `_member_aggregates`：一条按 (成员, 工具, 模型) 的 GROUP BY，Python 里折叠出成员、工具、模型三层聚合。

全是索引可覆盖的聚合查询，行数级别是"成员 × 设备 × 日期 × 工具 × 模型 × 来源"的日桶，目前远小于 25 万。缓存键（`api.py:283-306`）含 `ledger_version`，任何有变化的上报都会推进版本（`services.py:472`），所以 15 秒 TTL 之内也经常是冷读；但冷读本身就只有几十毫秒，无所谓。`limit` 不进缓存键，`limit=1` 与"全部"页签的 `limit=100` 共用同一条缓存，方案对这点的理解正确。

两个天花板：

- **标签 100 项截断（P0，眼前就到）**：`_available_labels` 的 `.limit(PUBLIC_DISTRIBUTION_LIMIT)`，且大小写合并发生在截断之后。响应无总数字段。现在 90/100。
- **扫描预算 25 万行（P2，运维天花板）**：一旦全历史公开 exact 桶超过 25 万，`period=all` 整体 503（"全部"页签和能力读取一起死），要靠调 `PUBLIC_MAX_SCAN_ROWS` 或以后做标签物化表。按 40 人、每人每天约 10 个桶估算还有一年以上，扩到 200 人会快很多。方案里"历史模型目录暂时读取失败"的兜底状态就是为这一天准备的，保留即可，但要在方案里写明这是已知天花板，而不是偶发故障。

## 4. 分级问题清单

### P0（不改就不能进入实现）

**P0-1 · 前端契约层还有一道 64 项截断，方案没看到。**
`web/community-contract.js:44` 的 `normalizeBreakdown()` 先 `values.slice(0, 64)`，然后 `community-app.js:220` 的 `breakdownList()` 再 `slice(0, 10)`。方案只提到去掉后者。服务端最多返回 100 项，前端却在 64 就切了，那么"成员用了哪些就展示哪些"在 65～100 项之间仍是假的；而且 `tool_distribution_total` / `model_distribution_total` 与数组长度的比较也会被这道切口污染（会显示"前 64 / 共 80"，却声称"接口返回的全部"）。
落点：`community-contract.js` 把 64 提到与服务端一致的 100（建议导出一个常量，注释写明必须等于服务端 `PUBLIC_DISTRIBUTION_LIMIT`），并在 `normalizePublicParticipant` 里带出 `toolDistributionTotal` / `modelDistributionTotal`。契约测试要加"服务端返回 100 项 + total=101 → 前端保留 100 项且 total=101"。

**P0-2 · "累计已识别模型全集"不能建在现有 `available_models` 上，需要新增轻量只读接口。**
理由见 §1、§3。这是对方案第 5 问的正式回答：不是性能不行，是 100 项静默截断 + 无总数字段，线上 90/100。最小接口设计见 §5。方案 §1、§4.1、§5.1、§5.2、§8 里所有"纯 web"的措辞要同步改掉；方案已经预留了"若需要改服务端则扩大范围并重新审核"的出口，这次直接走这个出口。

### P1（进入实现前必须写进方案与改动清单）

**P1-1 · 限流：每次挂载都发能力请求会把用户自己限死。**
nginx 对 `/api/v1/public/` 有 `limit_req rate=30r/m burst=10` 按 IP，应用层还有 30 次/60 秒按 IP 的第二道（`config.py:23-24`，键按可信代理链解析真实 IP，`api.py:150-193`）。前端每次筛选点击都是 hashchange → 重新 `mountCommunityApp` → 重新 `load()` → 重新请求排行榜。如果能力请求也跟着每次挂载发一次，用户一分钟点 15 次筛选就 429。方案把 20 个工具 + 90 个模型都做成可点，这个概率不低。
落点：能力响应放模块内存（和 `communityShareViewerPublicId` 同一种生命周期，页面会话内只取一次，刷新即失效），挂载时先用内存值渲染；失败不自动重试，只给"重新读取"按钮；当前筛选本身就是 `period=all` 且无工具/模型过滤时，不必再发能力请求。需要一条前端测试：连续 3 次筛选导航，能力请求只发 1 次。

**P1-2 · 静态资源版本链没写全，老访客会拿到新 app + 旧 contract。**
服务端只对 `text/html` 打 `Cache-Control: no-cache`（`static_web.py:39-40`），JS/CSS 没有任何 Cache-Control，浏览器按启发式缓存可以缓存小时到天。现有链条：`index.html` → `public-app.js?v=…` → `community-app.js?v=…` → `community-api.js` / `community-contract.js` / `server-adapter.js`（**无版本号**）。这次 `community-contract.js` 和 `community-api.js` 都要改，若只 bump 前两级，老访客会跑新 `community-app.js` 配旧 `community-contract.js`，直接运行时报错。
落点：`community-app.js` 内对 `community-api.js`、`community-contract.js`、新 `community-capabilities.js` 的 import 都加 `?v=`；`public-app.js` 对 `community-app.js` 的 import、`index.html` 对 `public-app.js` 与 `styles.css` 的引用一起 bump。验收里加"线上抓 HTML 与所有 JS import 的版本号一致"。

**P1-3 · 演示模式与既有测试会被打断。**
`community-demo-data.js:239-272` 的 demo API 只有 `leaderboard()` / `member()`；浏览器测试跑在演示模式下。新增能力请求后要给 demo API 补同名方法（返回固定 TOOLS/MODELS 全集），否则演示页和 `community_browser.py` 一起挂。另外 `community_browser.py:211-212` 现在断言的是 `全部工具（3）` / `全部模型（6）` 链接名，新文案上线后这两条会红，测试清单里要写"更新既有断言"，不只是"补新用例"。

**P1-4 · 固定目录必须按"数据标签"精确匹配，展示名另存。**
Mac（`TokenStepSwift`）与 Windows（`clients/windows/tokenfleet`）实际写入账本的 20 个标签我逐个核过，与方案清单一致：Codex、Claude Code、ZCode、Hermes Agent、WorkBuddy、CodeBuddy、Qoder、Kimi、OpenCode、Grok、Qwen Code、Cursor、Cline、Copilot CLI、Copilot Chat、Antigravity、Droid、dsh、Pi、OpenClaw。但 README 与 `docs/AGENT_SUPPORT.md` 对外披露的产品名是"Kimi Code""Grok Build""GitHub Copilot CLI／Chat"，与标签不同。服务端 `tool` 过滤是精确 `==`（`public_projection.py:698`），`available_tools` 返回的也是原始标签。
落点：`community-capabilities.js` 每条写 `{ label, displayName, note }`，匹配和筛选 URL 一律用 `label`，卡片文字可用 `displayName`。另外"约 20 种工具"这个数：按标签是 20，按产品是 19（Copilot CLI/Chat 同一产品）。首页文案用"约 20 种"没问题，但目录页要么写"20 个工具标签"，要么把 Copilot 两条并成一张卡片再说 19，别让用户自己数出 19 却看到 20。

**P1-5 · 方案实证数据过期，测试夹具口径要跟上。**
今天 = 4 工具 / 16 模型 / 21 人；全部 = 9 工具 / 90 模型 / 40 人。方案 §2.1、§4.1、§7.1 写的 6 / 81 全部改成"以接口实时值为准，2026-09-02 实测 9 / 90"。夹具里请直接放一个"历史标签 > 100"的用例，因为这不是假想。

### P2（建议，不阻断）

- **P2-1 · CC Switch 衍生标签的口径**：同意"不计入 20 个主要工具，但继续进入真实筛选并标'经 CC Switch'"。补一句：账本里还存在 `Gemini via CC Switch`（`UsageCollector.swift:5812`），而 20 个目录里没有独立的 Gemini 工具，展示时按标签原样显示，不能因为它出现就把"Gemini CLI"说成已支持。
- **P2-2 · "本期有数据 N 种"数什么**：方案说"`available_tools` 与支持目录匹配后的数量"，那么衍生标签算不算？建议：总览数字数"目录内命中数"，衍生标签单列"另有 N 个经 CC Switch 来源"，避免 9 个标签被解释成 9 个工具。
- **P2-3 · 90+ 个模型链接塞进筛选导航**：现在 `filterGroup` 是把所有选项平铺成 `<a>`，移动端会很长。方案已提到搜索，建议目录区默认按"本期有数据"在前、其余灰化在后，并加名称过滤输入框，不做折叠隐藏（符合方案原则）。
- **P2-4 · 空状态点击的缓存占用**：点无数据工具会为每个 (period, metric, tool, model) 组合生成一条缓存（上限 1024 条，LRU）。20 工具 × 7 日期 × 3 口径 = 420 条，模型组合会更多，会有 LRU 抖动但单次构建只有几十毫秒，可接受。URL 语义与排名语义不受影响（服务端发现列表本来就独立于 tool/model 过滤，`public_projection.py:704-719` 注释写明）。
- **P2-5 · Mac App 内嵌榜不在本次范围**：`TeamSyncProtocol.swift:508-509` 的 Mac 客户端也读 `available_tools/models`，但它只认 `period == "today"`，仍是老口径。方案说不改客户端，我同意；只需在方案里注明 App 内榜与网页目录在"全部工具"的语义上会短期不一致。新增接口不影响它，Swift 的 Codable 也会忽略未知字段。
- **P2-6 · 扫描预算天花板**：见 §3 第二条，写进方案的"已知边界"。

## 5. 轻量只读接口的最小设计（供实现，非最终契约）

目标：一个与日期、口径、筛选都无关的能力读取，只返回标签与总数，服从同一套扫描预算、缓存和限流。

- 路由：`GET /api/v1/public/capabilities`，无参数。
- 响应（新增 `PublicCapabilitiesResponse(StrictModel)`）：
  - `tools: list[str]`、`tools_total: int`
  - `models: list[str]`（已做大小写合并）、`models_total: int`（按 `lower(model)` 去重计数）
  - `partial: bool`（任一列表长度 < 对应 total 时为 true）
  - `timezone: str`、`end_date: date`
- 实现：复用 `_base_public_usage_query(period=all 边界)` → `_enforce_scan_limit(max_scan_rows)` → `_available_labels(...)`，但标签上限用新常量 `PUBLIC_CAPABILITY_LABEL_LIMIT`（建议 1000，反正被扫描预算兜着），总数用 `COUNT(DISTINCT tool)` / `COUNT(DISTINCT lower(model))` 各一条。
- 缓存：走现有 `PublicProjectionCache`，键 `("capabilities", org.id, ledger_version, end_date)`；把 `PublicProjectionResponse` 联合类型加上新类型，否则 `cache.get` 的 isinstance 检查会当作未命中。TTL 用同一个 15 秒即可，不必另开配置。
- 限流与头：复用 `_consume_public_read_limit` 与 `_public_cache_control`；503 扫描超限时同样 `no-store`。
- 测试（`server/tests/test_public_community.py` 新增）：① 字段与排序、大小写合并；② 制造超过上限的标签，断言 `partial=true` 且 total 正确；③ `public_max_scan_rows=1` 时 503 + `cache-control: no-store`；④ 与排行榜共用限流桶。
- 前端：`community-api.js` 增 `capabilities()`；`community-contract.js` 增 `normalizePublicCapabilities()`（`text()` 清洗 + 去重）；页面文案"累计已识别模型 N"用 `models_total`，列表显示 `models`，`partial` 时写"已展示前 M / 共 N"。接口 404（老服务端）或任何失败一律进"暂时读取失败"状态，绝不回落到本期列表。
- 回滚：接口是纯新增，回退服务端 commit 后网页自然进入失败状态，不影响排行榜。

如果坚决不想开新路由，退而求其次是在排行榜响应里加 `available_tools_total` / `available_models_total` 并把标签上限抬到 1000。这也要改服务端，还会改动被前端契约测试"冻结"的响应形状，并让每个日期范围的响应都背上完整列表，所以我不推荐。

## 6. 对方案 9 个问题的逐条回答

1. **支持目录与本期列表是否分开**：概念表（方案 §3）分得清楚。文案上再堵一处：任何出现"已检测到 / 未检测到 / 需配置"字样的地方都要加限定词"本机客户端里"，公开页只用"本期有数据 / 本期暂无数据 / 需手动导入 / 部分场景需配置"。
2. **20 个标签是否与实际采集一致**：一致（P1-4 已逐个核对）。Kimi / Grok / Hermes Agent / Copilot CLI / Copilot Chat 的数据标签就是这些，不要改标签；展示名与披露文档对齐即可。
3. **CC Switch 衍生标签边界**：合理，见 P2-1 / P2-2。
4. **模型表达方式**：同意"自动识别、无固定白名单 + 全历史真实识别全集 + 本期状态"。前提是全集来自新接口并带总数，否则 90→100 之后就是伪白名单。
5. **额外 `period=all&limit=1` 请求的成本**：扫描成本几十毫秒、与"全部"页签共用缓存、不会放大服务端压力；真正的风险是每次挂载都发导致的按 IP 限流（P1-1）和 100 项截断（P0-2）。结论：不要用这条请求承载"全集"，改用 §5 的接口，且页面会话内只取一次。
6. **去掉 slice(0,10) + 用 `*_distribution_total`**：方向对，但还差契约层的 64（P0-1）。补上之后，在服务端 100 项上限内是诚实的；超过 100 显示"前 100 / 共 N"也是诚实的。
7. **20 工具全部可点是否污染 URL / 排名 / 缓存**：不污染，见 P2-4。
8. **是否同意 web-only**：不同意，改为"web + 一个新增只读接口"，客户端与 tag 边界不变。
9. **测试清单能否抓住突变**：能抓住方案列出的五类，但要补四条：契约层 64 截断（P0-1）、能力请求只发一次（P1-1）、静态资源版本链一致（P1-2）、既有 `全部工具（3）` 断言更新与 demo API 补齐（P1-3）；服务端新增 §5 的四条。

## 7. 进入实现的条件（修订清单）

1. 方案 §1 / §4.1 / §5.1 / §5.2 / §8：把"纯 web"改为"web + `/api/v1/public/capabilities` 新增只读接口"，写明需要服务端与网页一起部署、客户端与 tag 不动。
2. §2.3 与 §4.5：把 `community-contract.js` 的 `slice(0, 64)` 列入改动，说明前端上限须与服务端 100 一致。
3. §4.1：能力请求改为页面会话内一次、模块内存缓存、失败不重试；数字来源改为接口的 `models_total` / `tools_total`。
4. §5.1：列出完整静态资源版本链（HTML → public-app → community-app → api / contract / capabilities）。
5. §5.1 / §7：补 demo API 方法、既有浏览器断言更新、以及本文 §6 第 9 条的新增用例。
6. §2.1 / §7.1：实证数字更新为 2026-09-02 的 9 / 90 / 40 与 4 / 16 / 21，并注明数据仍在因 180 天回补而增长。
7. §6：加入"扫描预算 25 万行是已知运维天花板"一句。

以上 7 条改完，我这边给"可进入实现"。实现完成后的验证口径：`cd web && npm test`、`python3 web/tests/community_browser.py`（或仓库既有跑法）、`cd server && pytest tests/test_public_community.py`、静态检查；部署后用直连 IP 抽查 `capabilities` 与 `leaderboard?period=all` 各一次，并抓 HTML 里全部 `?v=` 版本号核对。
