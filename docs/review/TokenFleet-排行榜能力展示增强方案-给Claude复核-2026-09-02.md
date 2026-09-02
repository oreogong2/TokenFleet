# TokenFleet 排行榜能力展示增强方案（给 Claude 复核）

日期：2026-09-02（Asia/Singapore）

状态：Claude 已同意产品口径，并以 2 个 P0、5 个 P1 有条件通过；第一轮修订后的陌生实施者复核又发现 1 个口径 P0、4 个 P1，经两轮增量修订后已复核通过，可进入实现。尚未修改网页、服务端或客户端代码

发布基线：`v0.1.0-beta.11`

目标：把 beta.11 已经具备的主流工具与模型识别能力如实展示出来，同时继续区分“产品支持能力”和“社群当前已有数据”。

## 1. 结论先行

本次建议做一个**排行榜能力展示增强**。实现范围是 `web/` 加一个新的轻量只读接口 `GET /api/v1/public/capabilities`，不改采集器、不改上传协议、不改账本、不改 Mac／Windows 客户端，也不要求用户重新安装或升级。

核心改动有五类：

1. 排行榜始终展示完整的已支持工具目录，而不是只展示本期已经收到数据的工具；每个工具标明“本期有数据／本期暂无数据／需要主动配置”等真实状态。
2. 模型不建立虚假的有限白名单，而是明确展示“自动识别、无模型白名单”；模型目录固定读取“当前公开账本中仍实际留存的历史识别目录”，不随“今天／7 天”等页面日期筛选缩小。它是受公开状态和留存清理约束的当前快照，不是永久、单调递增的“曾经出现全集”。本期是否有数据只作为状态标记。
3. 新增能力接口，返回完整工具／模型标签、真实总数和 `partial` 状态，解决现有排行榜接口 100 项静默上限且无总数的问题。
4. 成员详情移除前端契约层 64 项和渲染层 10 项两道限制；默认直接展示服务端已经返回的全部分项。若服务端只返回部分项目，页面必须显示“已展示前 M／共 N”，不得谎称全部展示。
5. 能力请求在一个页面会话内只读取一次；完整更新静态资源版本链，并同步补齐演示模式和既有测试。

服务端和网页需要一起部署，但 `clients/windows`、`TokenStepSwift` 和本地设置均不动。新增接口是纯读取、纯新增，老客户端不会调用它，也不会受它影响。

产品验收不是“接口数据技术上没丢”，而是一个第一次打开排行榜的人能在第一屏或一次展开内明确看到：TokenFleet 已覆盖约 20 个主要工具标签，并已在当前公开账本中真实识别大量模型，而不是误以为只支持今天出现的 4 个工具标签、16 个模型。

上线需要形成一个如实描述“公开能力接口＋排行榜 UI”的新 commit，并一起部署服务端和静态网页；不修改 `v0.1.0-beta.11` 标签、不发布新的客户端版本，现有用户刷新排行榜即可看到。

## 2. 当前问题与实证

### 2.1 用户看到的“全部”不是产品支持清单

当前公开榜的 `available_tools` 和 `available_models` 来自所选日期范围内，全社群已经接受的 `completeness="exact"` 真实账本桶。它们是“本期已出现标签”，不是 TokenFleet 的“完整支持能力”。

2026-09-02 Claude 直连生产 IP 绕过本机代理后的只读实证：

- 默认“今天”范围：全社群出现 4 个工具、16 个模型、21 名公开成员；
- “全部时间”范围：全社群出现 9 个工具、90 个模型、40 名公开成员；
- `period=all` 冷请求 0.21 秒，`period=today` 冷请求 0.31 秒；全历史读取当前并不比今天更慢；
- beta.11 的 180 天历史回补仍在继续，上述数量是当时实测值，不是固定产品常量。

因此当前页面虽然技术口径没错，却会让普通用户误解为 TokenFleet 只支持 4～9 个工具，掩盖 beta.11 已经接入约 20 个主流工具标签、模型动态识别的能力。

### 2.2 “全部工具／全部模型”文案有歧义

当前筛选器写“全部工具（N）／全部模型（N）”，实际意思是“不限制本期已出现的工具／模型”。这不只是文案歧义，而是展示范围本身不符合产品目标：用户理应从“全部工具／全部模型”看到完整能力，而不是看到一个被今天数据缩小后的子集。

### 2.3 成员详情人为截断到前 10 项

当前有两道独立限制：

- `web/community-contract.js` 的 `normalizeBreakdown()` 先执行 `values.slice(0, 64)`；
- `web/community-app.js` 的 `breakdownList()` 再执行 `items.slice(0, 10)`。

服务端成员详情实际已经返回：

- `tool_distribution`／`model_distribution`：按当前口径排序后的分项；
- `tool_distribution_total`／`model_distribution_total`：真实分项总数；
- 单类分项的现有服务端上限为 100。

因此只删除渲染层的前 10 项限制仍然不够：第 65～100 项会先在契约层丢失。两道限制都必须处理，才能在现有服务端 100 项上限内诚实展示。

`web/community-contract.js` 还没有把 `tool_distribution_total`／`model_distribution_total` 带进标准化后的成员对象。实现时需要把契约层上限提高到 100，并保留这两个真实总数字段，才能区分“接口已经完整返回”和“服务端只返回前 100”。这不改变成员详情的服务端契约。

### 2.4 现有排行榜标签接口无法证明“全部”

现有 `_available_labels()` 对工具和模型统一使用 100 项上限，且排行榜响应没有标签总数。线上全历史模型已经达到 90 个；一旦超过 100，接口会静默少返回模型，网页无法知道缺失，仍可能错误标成“全部模型”。

因此不能继续用 `leaderboard?period=all` 承载完整的当前公开历史目录。新增 `/api/v1/public/capabilities` 必须同时返回列表、真实总数和 `partial`，这是正确性要求，不是性能优化。

### 2.5 “公开历史目录”不是永久累计档案

能力接口必须继续复用 `_base_public_usage_query()` 的隐私边界：只读取当前 `is_active=true`、`public_profile_enabled=true`、`display_name IS NOT NULL`、未删除且 `completeness="exact"` 的公开账本桶。该基础 SQL 不负责昵称安全校验，能力接口也不返回昵称；组织留存任务还会物理删除截止日之前的历史桶。

因此 `tools_total` / `models_total` 是可上升也可下降的当前快照：成员退出公开、被禁用，或唯一带有某标签的旧桶被留存清理后，该标签可以从目录消失。实现者不得为了满足“累计”文案而绕过公开成员过滤、保存退出成员的标签，或新增永久标签表。如未来要做永久历史档案，需要另行设计 schema、退出公开和留存政策，不属于本次。

### 2.6 旧设计的合理性与不足

旧原则是“UI 只展示有数据的 Agent，避免空状态造成误解”。它保证了筛选项点开就有结果，但忽略了另一种更强的误解：用户会把“本期没有数据”理解成“产品不支持”。

新方案不删除真实空状态，而是把空状态解释清楚：**已支持，不等于本期一定有人使用；本期没有数据，也不等于采集器失效。**

## 3. 必须区分的四个概念

| 概念 | 含义 | 页面怎么展示 |
| --- | --- | --- |
| 产品支持目录 | beta.11 已经有采集实现并正式披露的工具 | 始终完整展示，不因本期为 0 而消失 |
| 当前公开历史识别目录 | 能力接口从当前公开成员、账本中仍实际留存的 exact 桶中读取的模型快照 | 列表未截断时完整展示；该数可因退出公开或留存清理下降；部分返回时明确写“已展示 M／共 N” |
| 社群本期已出现 | 当前日期范围内至少有一个公开成员上传过真实 exact 桶 | 标记“本期有数据”，可以直接筛选排行榜 |
| 成员实际使用 | 某个成员在当前日期范围内真实上传过的工具和模型 | 只在该成员详情中展示，不推测其本机安装或配置 |

公开排行榜不能、也不应该读取访问者电脑上的安装状态。相同日期与口径下，所有人看到的社群能力目录和本期状态应一致；不同成员详情只展示各自已经公开的实际用量。

本机是否“已检测到／缺目录／需配置”，继续由 Mac 设置页和 Windows 本机页负责，不把本地诊断泄漏到公开网页。

## 4. 产品方案

### 4.1 首页新增“支持能力”总览

放置位置：社群榜 Hero 与日期／口径筛选器之间，保证用户进入排行榜第一屏就能理解能力范围。

建议主文案：

> 已支持约 20 种主流 AI 编程工具
>
> 模型自动识别，无固定白名单；工具日志中出现的新模型可以直接进入统计。

建议同时显示五个数字：

- `主要支持工具标签 20`：来自随网页版本发布的固定支持目录；
- `公开账本历史出现标签 N`：来自能力接口 `tools_total`，2026-09-02 线上实测为 9；
- `公开账本历史识别模型 N`：来自能力接口 `models_total`，2026-09-02 线上实测为 90；
- `本期有数据 N`：当前响应 `available_tools` 与支持目录匹配后的数量；
- `本期有数据模型 N`：当前响应 `available_models.length`。

“当前公开账本历史识别模型”及其完整名称列表是本方案的产品硬要求，不是可选装饰。它不保证永久累计，通过新增能力接口读取：

- 调用 `GET /api/v1/public/capabilities`，使用 `tools`、`tools_total`、`models`、`models_total` 和 `partial`；
- 当前日期范围的主榜先正常渲染，历史能力请求不阻塞排名；
- 能力 loader 使用前端模块级的 `idle / loading / success / failure` 状态，分别缓存真实接口和 demo 接口；一个浏览器页面会话只请求一次；hash 筛选重新挂载时复用同一份进行中 Promise 或成功结果；
- 该 loader 不得使用 `mountCommunityApp()` 创建的 `AbortController.signal`，否则 hash 导航的 cleanup 会中断首次请求并把 rejected Promise 永久留在会话内；
- 能力请求使用独立 `AbortController` 和 10 秒 timer；timer 到期必须 `abort()` 底层 fetch，请求结束的 `finally` 必须清理 timer，禁止只用 `Promise.race` 标记超时却让旧请求在后台继续；普通重挂载不中断它，请求失败后不自动重试，只有用户点击“重新读取”才清除 `failure` 状态、创建新 controller 并发起新请求；
- 请求失败、超时或触发扫描上限时，明确显示“公开历史模型目录暂时读取失败”，不能拿本期列表冒充完整目录；
- `partial` 是整个响应的完整性标记；工具和模型列表分别使用 `tools.length < tools_total` 与 `models.length < models_total` 判断自己是否显示“已展示 M／共 N”，不得因其中一类截断就把另一类也误标为部分返回。

能力接口与排行榜共用公开读取限流：nginx 和应用层都是每 IP 每分钟 30 次。因此“页面会话只取一次”是必做项；不能在每次点击工具、模型或日期时重新请求能力接口。

### 4.2 完整工具目录

建议新增一个只供网页使用的固定目录模块，例如 `web/community-capabilities.js`，每条使用 `{ label, displayName, note }`，记录 beta.11 的 20 个主要公开数据标签及展示说明。筛选 URL 和数据匹配一律使用 `label`，用户看到的名称使用 `displayName`：

1. Codex
2. Claude Code
3. ZCode
4. Hermes Agent
5. WorkBuddy
6. CodeBuddy
7. Qoder
8. Kimi
9. OpenCode
10. Grok
11. Qwen Code
12. Cursor
13. Cline
14. Copilot CLI
15. Copilot Chat
16. Antigravity
17. Droid
18. dsh
19. Pi
20. OpenClaw

其中 `Kimi` 的展示名为 `Kimi Code`，`Grok` 的展示名为 `Grok Build`，Copilot 两条可以显示为 `GitHub Copilot CLI`／`GitHub Copilot Chat`；底层 `label` 必须保持原值，不能用展示名做精确筛选。

首页可以继续写“约 20 种主流工具”。若页面明确显示计数，则应写“20 个工具标签”；按产品合并 Copilot CLI／Chat 时是 19 个产品，不能让“标签数”和“产品数”混为一谈。

CC Switch 代理产生的 `Codex via CC Switch`、`Claude Code via CC Switch`、`Gemini via CC Switch` 等衍生标签不冒充独立产品数量；若它们已出现在真实数据中，继续追加到“本期已出现来源”，并标记为“经 CC Switch”。`Gemini via CC Switch` 只能按账本标签原样展示，不能据此宣传已独立支持 Gemini CLI。

每个主要工具卡片／标签最多显示两层状态，避免信息过载：

- `本期有数据`：当前 `available_tools` 含该精确标签；
- `本期暂无数据`：已支持，但当前日期范围没有公开 exact 桶；
- `需手动导入`：Cursor；
- `部分场景需配置`：Copilot Chat／旧版 Copilot CLI 的 OTel；
- 其他工具默认不显示“自动”字样，统一由总览说明“默认只读识别”；必要时可保留 `Beta` 标签，避免把真实样本仍在巡检写成全面正式验证。

点击任何已支持工具都可以进入该工具筛选：

- 有数据：正常显示排行榜；
- 无数据：显示专门空状态“TokenFleet 已支持该工具，但当前日期范围暂无社群成员产生可统计数据”，并提供“查看全部时间”与“返回不限工具”；
- Cursor／Copilot 的空状态额外显示对应主动操作说明，不把“未导入／未开启”误报为采集故障。

### 4.3 主要支持目录、当前公开历史目录与排行榜筛选分开

页面先明确展示两个不同性质的目录：

- `主要支持工具标签（20）`：固定支持目录的 20 个主要数据标签，不把 Copilot CLI / Chat 或 CC Switch 来源误称为 20 个独立工具产品；
- `当前公开账本历史识别模型（N）`：能力接口返回的当前快照；2026-09-02 当前为 90，后续可随回补与新使用增长，也可因成员退出公开或留存清理下降。

两个目录同时也是可点击筛选目录：

1. 工具目录合并固定支持的 20 个主要工具，以及历史真实出现但不在固定目录中的衍生／未来标签；
2. 模型目录使用能力接口的 `models`，不再使用当前日期响应来删减名称；
3. 当前日期响应只负责给每个工具／模型标记“本期有数据／本期暂无数据”；
4. 点击本期无数据的工具或模型时，正常进入空结果页，并明确说明“已支持／历史已识别，但当前日期范围暂无数据”。

排行榜本身的清空入口改成：

- `不限工具 · 本期有数据 N 种`；
- `不限模型 · 本期有数据 N 种`。

这样“主要支持”与“当前公开历史识别”都指向明确的数据范围，“不限”只表示当前排行榜没有筛选条件。固定目录或历史模型中的本期无数据项继续可选，但使用弱化样式和“本期 0”标记，不能伪造成有数据。

工具／模型目录默认让“本期有数据”排在前面，其余弱化排在后面；90 个以上模型使用名称过滤输入框，不做折叠隐藏。模型目录不预填从未在真实日志中出现的模型名。页面必须写清：

> 模型名从工具本地日志自动识别，没有固定白名单。下面展示当前公开成员、账本中仍实际留存的数据中已经真实识别过的模型；新模型首次产生公开可信数据后会自动加入，退出公开或留存清理也可能使目录减少。

### 4.4 排行榜成员行保持摘要，不塞入全部分项

排行榜主列表需要保持可扫描性，不建议把每个人的全部工具和模型直接塞进一行，也不应为了渲染 100 名成员对每人额外请求详情。

成员行继续展示：

- 主力工具＋Token；
- 主力模型＋Token；
- `共 N 个工具／N 个模型`；
- “查看全部工具、模型与趋势”的入口。

可把“共 N 个工具／N 个模型”视觉权重提高，解决用户误以为该成员只有主力一项的问题。

### 4.5 成员详情展示本人实际使用的全部分项

同时处理两道限制：

- `community-contract.js` 的 `normalizeBreakdown()` 从固定 64 改为与服务端 `PUBLIC_DISTRIBUTION_LIMIT=100` 一致的前端常量；
- `community-app.js` 的 `breakdownList()` 移除固定 `slice(0, 10)`。

页面行为：

- 工具分布展示契约层保留的全部工具；
- 模型分布展示契约层保留的全部模型；
- 默认全部渲染，不再保留“只看前 10”或默认折叠；成员实际用了哪些就直接展示哪些；
- 全部分项仍按当前指标降序排列；
- 模型较多时可以增加名称搜索，或在移动端使用正常页面滚动，但不能用折叠把第 11 项以后重新藏起来；
- 不增加 JavaScript 状态持久化要求。

必须使用接口中的 `tool_distribution_total`／`model_distribution_total`：

- `total <= 返回数组长度`：可写“共 N 项”，当前列表即完整；
- `total > 返回数组长度`：写“当前展示前 M 项／共 N 项”，禁止使用“全部”；现有契约最多返回 100 项；
- 如果产品要求无论多少都绝对全部显示，需要另开服务端分页方案，不属于本次能力展示范围。

### 4.6 模型能力的正确表达

不能预先列出“TokenFleet 能支持的全部模型”，因为模型名不是维护在白名单里，而是从每个工具的结构化 usage 日志动态进入统计。未来出现新模型，通常不需要为了模型名本身发布新版客户端。

页面应通过以下三层把能力表达得更强、更准确：

1. 固定主张：`模型自动识别，无固定白名单`；
2. 动态证据：使用能力接口的 `models_total` 展示 `当前公开账本历史识别 N 种`，并另列 `本期有数据 N 种`；
3. 真实列表：展示能力接口返回的当前公开历史模型名称，允许搜索，并用状态区分本期是否有数据；当 `models.length < models_total` 时显示“已展示 M／共 N”，不预造不存在的数据。

这比写一个很快过时的“支持模型清单”更强，也更符合 beta.11 实际实现。

## 5. 实现边界

### 5.1 预计修改文件

- `server/app/schemas.py`：新增 `PublicCapabilitiesResponse`；
- `server/app/public_projection.py`：构建历史工具／模型标签、真实总数和 `partial`，并让现有公开缓存接受该响应类型；
- `server/app/api.py`：新增 `GET /api/v1/public/capabilities`，复用公开限流、扫描预算和 Cache-Control；
- `server/tests/test_public_community.py`：增加能力接口的排序、大小写合并、部分返回、扫描上限和共用限流测试；
- `web/community-app.js`：能力总览、完整工具筛选、空状态、成员详情完整展示；
- `web/community-capabilities.js`：固定支持目录、展示标签与主动配置说明，以及不绑定 mount AbortSignal 的会话级能力 loader；
- `web/community-contract.js`：标准化能力响应；把详情分布的 64 项上限提高到与服务端一致的 100，并保留真实总数；
- `web/styles.css`：能力卡片、状态样式、长列表与移动端布局；
- `web/community-api.js`：增加 `capabilities()`；
- `web/community-demo-data.js`：增加同名演示接口，返回固定的演示工具／模型目录；
- `web/index.html`、`web/admin/index.html`、`web/public-app.js`、`web/app.js`、`web/community-app.js`、`web/community-api.js` 的相关 import query：完整更新静态资源版本链；
- `web/tests/*.mjs`、`web/tests/community_browser.py`：补新用例并更新既有“全部工具（3）／全部模型（6）”断言。

静态资源版本链必须完整覆盖两个入口。下列是需要在本次使用同一新版本 token 的精确直接依赖边，不得用简写链条遗漏兄弟 import：

- `index.html → public-app.js`、`index.html → styles.css`；
- `admin/index.html → app.js`、`admin/index.html → styles.css`；
- `public-app.js → community-app.js`、`public-app.js → community-contract.js`；
- `app.js → community-app.js`、`app.js → community-contract.js`；
- `community-app.js → community-api.js / community-contract.js / community-capabilities.js / community-demo-data.js`；
- `community-api.js → community-contract.js`。

本次未改动的 `join-secret.js`、`server-adapter.js`、`community-poster.js` 等不因“链条完整”而机械改版本；但只要实际 diff 修改了新的直接依赖，必须同步加入版本图和测试。

只更新前两级不算完成，因为 JS／CSS 没有显式 Cache-Control，老访客可能拿到新 app 配旧 contract；演示模式也可能拿到新 app 配旧 demo API。

### 5.2 轻量只读接口最小契约

- 路由：`GET /api/v1/public/capabilities`，无参数；
- 响应：
  - `tools: list[str]`、`tools_total: int`；
  - `models: list[str]`、与其逐项对齐的 `model_keys: list[str]`、`models_total: int`，模型按当前数据库大小写规则去重；
  - `partial: bool`，它是响应整体标记，任一列表长度小于对应总数时为 `true`；页面仍必须按两组长度与总数分别判断工具和模型的完整性；
  - `timezone: str`、`end_date: date`；
- 数据范围：复用 `_base_public_usage_query(start_date=None)` 与 `_enforce_scan_limit()`，因此只包含当前公开、活跃成员在账本中仍实际留存的未删除 exact 桶；不绕过公开过滤，不新增永久目录表；
- 标签归一化与上限顺序：先在已通过 25 万行扫描守卫的公开范围中取得全部原始 distinct label，再归一化、确定性排序，最后应用 `PUBLIC_CAPABILITY_LABEL_LIMIT=1000`；禁止先 `LIMIT 1000` 再去重；
- 工具保持原始标签精确去重，在 Python 中按 `(label.lower(), label)` 确定性排序；
- 模型必须与现有公开排行榜 `_model_matches()` 的可点击筛选口径对齐：在当前数据库中同时取原始标签与 `lower(model)` canonical key，按该 key 分组，同组选字符串排序最小的原始标签作展示值，最后按 `(canonical_key, display_label)` 排序；
- 实现时发现既有 `_model_matches()` 曾在左侧使用数据库 `lower(model)`、右侧使用 Python `model.lower()`，两端对非 ASCII 的规则可能不一致；本次将比较改为两侧都由当前数据库执行 `lower()`，确保能力目录里的每个展示值点击后都严格命中同一个数据库 identity，ASCII 行为不变；
- 增量代码复核进一步发现，本期状态若仍在浏览器用 JavaScript 小写规则推导，SQLite 下会把数据库视为两个 identity 的 `ÄModel`／`ämodel` 错标成同时有数据。因此既有排行榜响应只新增一个与 `available_models` 逐项对齐的 `available_model_keys` 字段；能力接口与排行榜都把数据库 `lower()` 的结果原样交给网页，网页只按 key 精确判断本期状态，小写转换仅用于搜索。该字段为只读、加法兼容，不改变现有字段语义或客户端请求；
- `tools_total` / `models_total` 都是归一化后、应用 1000 项上限之前的当前真实总数；对每组列表都必须满足 `len(values) == min(total, PUBLIC_CAPABILITY_LABEL_LIMIT)`；
- 前端 `normalizePublicCapabilities()` 只做安全文本校验、数值与长度校验，保留服务端的展示值和顺序；不再使用 `localeCompare`、JavaScript `toLowerCase()` 或另一套去重逻辑二次改写契约；
- 缓存键：`("capabilities", org.id, ledger_version, end_date)`，复用现有 `PublicProjectionCache` 和 15 秒 TTL；
- 响应类型：把新 `PublicCapabilitiesResponse` 加入 `PublicProjectionResponse` 联合类型以完善静态类型契约；能力路由读缓存时必须显式调用 `cache.get(key, PublicCapabilitiesResponse)`，使现有运行时 `isinstance` 检查按新响应类型命中；
- 限流：复用 `_consume_public_read_limit`，与其他 `/api/v1/public/` 读取共用每 IP 每分钟 30 次预算；
- 响应头：成功复用公开 Cache-Control；扫描预算超限的 503 继续 `no-store`；
- 回滚：接口是纯新增；回退服务端后网页显示“能力目录暂时读取失败”，排行榜本身继续可用。

### 5.3 明确不修改

- 数据库 schema、账本、Token 聚合口径和既有公开接口字段语义；唯一例外是排行榜增加只读的 `available_model_keys` 对齐数组，用于消除跨运行时大小写歧义；
- `TokenStepSwift`、Mac App、Windows 客户端；
- 实验来源默认开启语义、ZCode 特例、Cursor 导入、Copilot OTel 规则；
- `v0.1.0-beta.11` tag；
- 用户的安装、升级、设备码和社群连接状态。

Mac App 内嵌榜仍按 `today` 读取既有 `available_tools/models`，短期不会显示网页的主要支持目录与当前公开历史目录；这是已知跨界面差异，不影响采集、同步或公开网页，本次不扩大到客户端。

## 6. 数据、隐私与性能边界

1. 固定支持目录是产品能力元数据，不是用户数据。
2. 能力接口只读取既有匿名公开 exact 标签和总数，继续尊重成员活跃状态、公开开关与组织留存策略；不增加邮箱、设备、路径、会话或本机安装信息，也不持久化退出公开成员的标签。
3. 公开网页不能根据访问者电脑“有无安装某工具”做个性化；该能力只属于本机客户端。
4. 不为 100 名成员逐个加载详情；主榜仍只请求一份 leaderboard，成员详情只在点击后请求一人。
5. 能力请求页面会话内只发一次，使用独立 10 秒超时且不受 hash 重挂载 cleanup 影响；失败不自动重试，用户主动点击“重新读取”才再次请求，避免 30 次／分钟限流把自己打到 429。
6. `PUBLIC_MAX_SCAN_ROWS=250000` 是当前公开账本历史能力目录的已知运维天花板。当前估算仍有一年以上，但成员扩到 200 人后会更快接近；超限时能力接口 503，网页进入明确失败状态，后续再评估调预算或标签物化表。
7. 工具完整目录不得把候选但尚未接入的 Roo Code、Kilo Code、Windsurf、Trae 等写成“已支持”。
8. `Beta`／主动配置标签必须保留真实边界，不能把协议 fixture 通过宣传成所有真机均已验证。

## 7. 行为级验收清单

### 7.1 支持能力展示

- 当前排行榜只返回 Codex／Claude Code 时，页面仍展示完整 20 个主要工具；
- Codex／Claude Code 标记“本期有数据”，其他工具标记“本期暂无数据”；
- 当前范围只出现 2 个模型、能力接口返回 90 个模型时，“当前公开账本历史识别模型”仍展示 90 个，只有 2 个标记“本期有数据”；
- 能力接口制造超过 100 个模型标签时，总数与列表都不会在 100 静默停止；若超过能力接口自身上限，则 `partial=true` 且页面显示“已展示 M／共 N”；
- Cursor 显示“需手动导入”，Copilot 显示真实配置提示；
- Kimi／Grok 使用底层标签匹配，页面分别展示 Kimi Code／Grok Build；
- 真实出现的 CC Switch 衍生标签不会丢失，也不计入“20 个主要工具”；
- 候选未支持工具不会混入支持目录。

### 7.2 筛选与空状态

- 点击有数据工具，URL 与 API 精确筛选保持现有语义；
- 点击无数据但已支持工具，返回专用空状态，不显示通用错误；
- 空状态明确区分“已支持但本期无人使用”与“需要 Cursor／Copilot 主动配置”；
- “主要支持工具标签／当前公开账本历史识别模型”与“不限工具／不限模型”是两个不同概念；
- 切换今天、7 天、全部时间时，当前公开历史目录不随页面日期筛选缩小，只有本期状态与数量同步刷新。

### 7.3 个人详情

- fixture 含 24 个模型时，初始渲染就能看到 24 个，不需要再点“展开”；
- fixture 返回 100 项、`model_distribution_total=101` 时，契约层必须保留全部 100 项，页面显示“前 100／共 101”，不写“全部”；
- 变异把契约层恢复为 64 或把渲染层恢复为 10 时，行为测试必须失败；
- 工具和模型排序、Token 数值、费用不可比提示保持不变；
- 移动端长列表不会撑破页面或遮挡返回入口。

### 7.4 模型能力

- 页面明确出现“自动识别、无固定白名单”；
- 当前公开历史模型目录和总数来自能力接口的 `models`／`models_total`，不是硬编码，也不随当前日期缩小；
- 能力请求失败时，排行榜仍正常显示，并明确提示读取失败，不把失败渲染成 0 或本期完整目录；
- 能力请求仍在进行时连续进行 3 次 hash 筛选导航，请求不被旧 mount cleanup 中断，同一页面会话内只请求 1 次并在完成后被新 mount 渲染；
- 能力请求超过 10 秒时底层 fetch 被真正 abort、timer 被清理并进入 `failure`，不存在继续占用限流或晚到覆写状态的幽灵请求；失败后普通导航不自动重试，用户点击“重新读取”后才使用新 controller 发出第 2 次；
- 模型名称继续按现有安全转义渲染，不引入 HTML 注入。

### 7.5 能力接口

- 字段、工具 `(label.lower(), label)` 排序与精确去重、模型按当前数据库 `lower(model)` 归一、确定性展示值和排序均符合契约；
- 增加合法非 ASCII 模型标签 fixture，证明能力目录中每个模型点击后的排行榜筛选，正好覆盖当前数据库 `lower(model)` identity 的全部桶，不会因 Python `casefold()` 更激进的合并丢数；
- 前端标准化保留服务端的标签展示值和排序，突变为 `localeCompare()` 重排或 `toLowerCase()` 二次合并时测试必须失败；
- 制造超过 100 个不同模型，并让大小写变体横跨旧 100 项和新 1000 项边界；断言先去重再限制，且 `len(models) == min(models_total, 1000)`；
- 超过 `PUBLIC_CAPABILITY_LABEL_LIMIT` 的 fixture 返回正确总数和 `partial=true`；
- 只有工具或只有模型超限时，全局 `partial=true`，但页面只对真正被截断的那组显示“已展示 M／共 N”；
- `public_max_scan_rows=1` 时返回 503 且 `cache-control: no-store`；
- 与排行榜共用公开读取限流桶；
- 同一 `org + ledger_version + end_date` 第二次请求命中 `PublicProjectionCache`，不再执行账本标签查询；成功响应携带 15 秒公开缓存头；
- 新上报、成员退出／恢复公开或被禁用、留存清理推进 `ledger_version` 后必须重新查询；当唯一带有某模型的成员退出公开时，该模型从快照消失，证明实现未绕过隐私边界；
- 接口不返回昵称、成员、设备、邮箱、路径、会话或 Token 数量。

### 7.6 演示、发布与缓存

- 演示 API 已增加 `capabilities()`，演示页能够独立运行；
- 既有浏览器测试中“全部工具（3）／全部模型（6）”断言已按新语义更新；
- 网页测试、浏览器行为测试、服务端公开榜与能力接口测试、静态检查全部通过；
- 公开入口、后台入口、api／contract／capabilities／demo 以及 CSS 的 query version 全部更新且一致；测试按 §5.1 精确枚举每条直接依赖边，必须能抓住 `public-app.js → community-contract.js` 或 `app.js → community-contract.js` 遗漏版本号的突变；
- 部署后线上抽查桌面端／移动端、能力接口、今天／全部时间、一个有数据工具和一个无数据工具；
- Mac／Windows 已安装 beta.11 的用户不升级客户端也能看到新网页；
- 回滚服务端／网页 commit 后不触碰账本和客户端；接口不存在时网页进入能力目录失败状态，排行榜继续可用。

## 8. 建议实施顺序

1. 先让 Claude 或无前序对话的陌生实施者对本版做一次只读增量确认，得到“可进入实现”。
2. 实现前从 `v0.1.0-beta.11` 或 `origin/main` 的 `c5ad1cb` 开新分支；本 worktree 的本地 `main` 停在 beta.10，禁止从本地 `main` 开分支。
3. 先实现能力接口和服务端契约测试，再实现网页能力目录、详情完整展示和会话级请求复用。
4. 补演示 API、更新既有断言和完整静态资源版本链。
5. 重跑：`cd web && npm test`、仓库既有浏览器测试命令、`cd server && pytest tests/test_public_community.py`、静态检查。
6. 实现完成后交 Claude 做增量代码复核；通过后形成一个如实命名的服务端＋网页 commit。
7. 一起部署服务端与网页，保持 beta.11 客户端和 tag 不动。
8. 部署后直连生产 IP 抽查 `capabilities` 与 `leaderboard?period=all`，核对 HTML 和全部 JS import 的版本号，再纳入既有 7 天巡检。

## 9. 给 Claude 的增量确认清单

请只读确认本版主方案是否已经完整吸收 Claude 首轮复核和陌生实施者二轮复核意见，暂时不要修改代码或形成提交：

1. 范围已从 web-only 改为 `web/ + GET /api/v1/public/capabilities`，服务端与网页一起部署，客户端与 beta.11 tag 不动；
2. 成员详情同时处理契约层 64 项和渲染层 10 项限制，前端上限与服务端 100 一致；
3. “累计全集”已改为“当前公开账本中仍实际留存的历史识别快照”，总数可上升也可下降，严禁绕过 `_base_public_usage_query()` 的隐私过滤；
4. 能力 loader 为模块级状态机，不绑定 mount AbortSignal，使用独立 controller 和 10 秒 timer 真正 abort 超时 fetch 并清理 timer；请求进行中连续 hash 导航仍只发一次，失败只能由用户手动重试；
5. 标签契约已定义“先归一化与排序、后限 1000”、模型与当前数据库 `lower(model)` 筛选 identity 一致、确定性展示值、总数和列表长度不变量，并含跨边界大小写变体与非 ASCII 可点击筛选测试；
6. 静态资源版本图已精确列出所有本次改动的直接依赖边，包含易漏的 `public-app.js → community-contract.js` 和 `app.js → community-contract.js`；
7. 演示 API、既有浏览器断言、先去重后限制、进行中导航、超时手动重试和版本图突变测试均进入验收清单；
8. `PublicCapabilitiesResponse` 已要求加入联合类型并作为 `cache.get()` 的运行时类型参数，同时增加缓存命中、`ledger_version` 失效、15 秒成功缓存头和公开状态变化测试；
9. 全局 `partial` 与工具／模型两组各自的完整性判断已分开；“20”统一称为主要工具标签数，CC Switch 来源不冒充独立产品；
10. 线上实证为今天 4／16／21、全部 9／90／40，明确它们是 2026-09-02 当时快照，而非产品常量；
11. `PUBLIC_MAX_SCAN_ROWS=250000` 已写成已知运维天花板。

若以上十一项无遗漏，请明确回复“方案修订通过，可进入实现”；如仍有阻断，请给 P0／P1／P2、文件／章节和最小修订方向。
