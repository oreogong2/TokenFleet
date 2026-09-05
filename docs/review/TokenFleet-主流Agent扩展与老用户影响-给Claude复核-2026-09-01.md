# TokenFleet 主流 Agent 扩展：Claude 增量复核报告

日期：2026-09-01（Asia/Singapore）
工作目录：`<PROJECT_ROOT>`
分支：`codex/tokenfleet-platform`
基线提交：`3e40bd76198edb4d2b9a43b61a564ff2c08b8b45`
当前状态：Claude 两轮增量复核中提出的阻断项均已修；最新本地完整门禁通过；尚未提交、打包、安装或连接生产 TeamSync，等待 Claude 快速终审。

## 1. 结论先行

Claude 首轮指出的账本双计、误删历史和榜单漏同步问题均已按要求修复；第二轮确认这些修复真实落地后，又发现的 3 个 P1 与 3 个会整份炸同步的边界也已闭环：

- WorkBuddy 恢复稳定模型优先级 `requestModelId → requestModelName → model`，缺失时回到 `unknown`，不再产生不稳定的 `auto` naturalKey。
- CodeBuddy 只接收 assistant 记录。
- dsh 不再同时计算同名明文和 zstd 副本，并增加 session／事件序号去重。
- Copilot session store 只覆盖相同会话且处于数据库覆盖时间窗的 CLI OTel，不再删光较早历史。
- Antigravity 的 Gemini `thoughtsTokenCount` 进入 output 总量，同时保留为 reasoning 子集，TeamSync 不再跳过整天桶。
- dsh 在混合明文／压缩-only 且没有解码器时显示 `partial_missing_decoder`，不再把少算伪装为 `ok`。
- Copilot OTel 缺 conversation/session ID 时，只在 DB 已覆盖的同一天压制 CLI trace fallback；其他日期和明确的其他会话继续保留。
- Cursor 导入条数已缓存到 AppState；模型自然键统一按 Unicode scalar 截断、截断后 trim，并在聚合入口重新清洗旧缓存。

对老用户的答案没有变化：旧客户端可以继续使用，不强制升级；想统计新增来源的用户需要升级客户端。服务端的 `tool`、`model` 都是自由字符串，本轮没有服务端字段或 migration，也没有修改 `server/`。

产品授权语义已经由维护者改为最终口径：macOS 与 Windows 的实验总开关默认开启，并继续自动覆盖未来加入该开关的来源；升级后对老用户也统一开启，新版本中的显式关闭会永久尊重。升级后可能补计最多 180 天历史，必须通过更新说明显著告知，不能静默发布。Windows 的 ZCode 默认采集且不进开关；Cursor 仍是手动 CSV 且使用正常历史窗口，Copilot OTel 仍需用户自行开启 exporter，结果可能标为 Copilot CLI 或 Copilot Chat。

## 2. 首轮问题闭环

| 级别 | 问题 | 修复后的行为 | 回归证据 |
| --- | --- | --- | --- |
| P0 | WorkBuddy 模型优先级反转、`auto` 兜底会制造永久新 naturalKey | 恢复 `requestModelId → requestModelName → providerData.model → object.model → unknown`；请求 ID 去重保持不变 | runtime harness 同时提供冲突模型字段和无模型样本，断言只出现 `hy3`／`unknown`，不出现错误模型或 `auto` |
| P1 | CodeBuddy 把 user usage 也计入 | `assistantOnly: true` | runtime harness 写入带 usage 的 user 行，断言被拒收 |
| P1 | dsh 明文与 `.jsonl.zstd` 并存双算；隐藏目录口径不一致 | 有可用解码器时同名 zstd 优先，明文跳过；无解码器时可用明文作为安全回退；跨文件再按 session／event ID 去重；压缩与明文扫描都不跳隐藏目录 | runtime harness 在隐藏目录放入数值不同的明文／压缩双胞胎，只计压缩；另测仅压缩缺解码器与明文＋压缩-only 混合状态 |
| P1 | Copilot DB 存在就删除全部 CLI OTel | session 相同且 OTel 时间落在该 session DB 最早／最晚记录之间时删除；缺 conversation/session ID 的 CLI trace fallback 仅按 DB 已覆盖日期压制；Chat、较早 CLI、明确的其他 session 均保留 | runtime harness 同时覆盖重合、同日无 ID、较早无 ID、明确其他 session 与 Chat，只跳过两个可能重合项 |
| P1 | Antigravity Gemini thinking 本地算、榜单不算 | `candidatesTokenCount + thoughtsTokenCount` 作为完整 output；reasoning 仍记录 thoughts 子集；`totalTokenCount` 与原子分量一致 | runtime harness 拒收 statusline，接收 camelCase `usageMetadata`，并实际构建 1 个 TeamSync bucket |
| P2 | Cursor 旧版纯日期导入后实际不计 | CSV 解析和采集共用 `CursorUsageTimestamp`，兼容 ISO 时间与 `yyyy-MM-dd` | runtime harness 导入 `2025-02-01` 并断言进入当天 1,500 tokens |
| P2 | Cursor BOM 导致表头失败 | 表头匹配前移除 UTF-8 BOM | runtime harness 的首列为 BOM + `Date` |
| P2 | Cursor 去重键抄两份 | 采集归档直接复用 `CursorUsageCSVRecord`，只保留一份 `deduplicationKey` | 全量编译与重复导入 runtime 断言 |
| P2 | 脏模型名让整份 TeamSync 停止 | 模型名移除控制字符和 naturalKey 分隔符、合并空白、按 Unicode scalar 截断到 128、截断后 trim、空值为 `unknown`；聚合入口再次清洗，覆盖旧 CollectorCache | runtime harness 写入 140 个组合字符与截断后空格碰撞模型，断言 scalar 上限、桶合并和 TeamSync 构建 |
| P2 | 设置卡片 `height: 930` 撑爆无外层 ScrollView 的截图 | 卡片缩到 710，来源清单使用内部纵向 ScrollView 固定可视区 | SwiftUI 全量编译／链接通过；仍需内部包人工看设置页与截图 |

### 2.1 第二轮新增问题闭环

| 级别 | 新发现 | 当前处理 | 回归证据 |
| --- | --- | --- | --- |
| P1 | dsh 混合场景吞掉 `missing_decoder` | 只要存在无明文孪生、又因缺解码器跳过的压缩文件：无可读记录为 `missing_decoder`，已有部分可读记录为 `partial_missing_decoder`；设置页与文档均可见 | runtime harness 实际同时放入一个可读明文 session 和一个压缩-only session，断言部分缺失、1 条可读记录、1 个跳过文件 |
| P1 | Copilot store 合成 ID 与 OTel ID 域不相交，无 ID 时可能同机双算 | 删除不可达的 ID 重合判据；保留明确 session 的窗口覆盖；只对无明确 session 的 CLI trace fallback 增加同日压制 | runtime harness 断言同日 fallback 被跳、旧日 fallback 保留，其他明确 session 与 Chat 不受影响 |
| P1 | 设置页每次 body 求值全量读 Cursor 归档 | `cursorImportedUsageRecordCount` 在 AppState 加载、导入、删除时更新；按钮只读内存状态 | 全量 Swift 编译／链接通过；大归档实际交互性能仍列入真机验收 |
| P2 | 客户端按字素计 128、服务端按码点计 128 | `modelKey` 与 TeamSync validate 均改用 `unicodeScalars` | runtime harness 用 `e + U+0301` 重复 140 次，生成的 model 恰为 128 scalars 且可构建同步桶 |
| P2 | 截断后尾空格可能与另一模型撞 naturalKey | scalar 截断后再次 trim，聚合到同一 model bucket | runtime harness 两个模型在截断清洗后碰撞，断言总量 27 完整合并且只产生 1 个桶 |
| P2 | 旧 CollectorCache 绕过新 modelKey 清洗 | 不做全局 cache bump；在 `aggregate` 入口统一重新执行 `modelKey`，只改变模型键、不触发全量采集重算 | 生产与测试聚合共用同一路径；完整门禁通过 |

## 3. 必须照实披露的既有行为变化

这三类不能再写成笼统的“UI 与采集增强”：

1. **ZCode**：数据库必需列从完整新 schema 放宽到旧版可提供的核心列。过去因 `schema_mismatch` 记 0 的老版本，升级后可能自动补计最多 180 天。
2. **Hermes**：同样放宽旧版 session schema，缺失模型时使用稳定的 `unknown`。过去记 0 的用户可能只升级、不改设置就出现历史补计。
3. **WorkBuddy**：新增请求去重，恢复稳定模型键，并调整 cache／explicit total 的判定。升级后总量、cache 比例或模型分布可能校正；这是采集口径修复，不是服务端重算错误。

隐藏目录的描述也已纠正：既有 `jsonlFiles` 保持 `.skipsHiddenFiles`，没有改变原有来源的通用扫描行为。本轮为 Antigravity、Droid、dsh 与 OTel 增加平行的 `usageLogFiles`；只有这条新路径会进入隐藏目录。dsh 的压缩扫描器现在与它使用同一口径。

## 4. 当前实验来源范围

当前工作树相对基线包含的不只是首轮报告中的六项，而是完整的一批实验来源：

- ZCode、Hermes、WorkBuddy；
- CodeBuddy、Qoder；
- Kimi Code、OpenCode、Grok Build、Qwen Code；
- Cursor Usage CSV、Cline；
- GitHub Copilot 当前 CLI session store、Copilot Chat／旧 CLI OTel；
- Antigravity、Droid、dsh；
- Pi、OpenClaw。

Cursor 是例外：个人账号数据只来自用户主动导入的官方 Usage CSV，不自动扫描浏览器下载目录。其余来源只读取本地结构化 usage、时间、模型和稳定 ID，不把 prompt、回复或代码正文写入 TokenFleet 快照。

模型层没有白名单。来源实际写出的 OpenAI、Claude、Gemini、Qwen、DeepSeek、MiniMax、GLM、Grok 等模型名，经 naturalKey 安全清洗后进入统计。

## 5. 老用户影响与升级要求

| 用户场景 | 结果 | 是否需要升级 |
| --- | --- | --- |
| 继续使用旧客户端和原有来源 | 原采集与同步继续工作 | 否 |
| 想统计本轮新增来源 | 旧客户端没有采集器 | 是，升级 Mac 或 Windows 客户端 |
| 升级 Mac 旧配置（无 configured 标记） | 不论旧字段为 false 或缺失，一律按新默认开启；旧 true 保持开启 | 会发生，无再授权弹窗 |
| 升级 Windows 旧配置 | 从未配置则按新默认开启；v1 文件只来自用户显式操作，因此保留原值 | 视既有选择而定 |
| 在新版本中显式关闭实验总开关 | 保持关闭，新目录不扫描；以后升级永久尊重 | 否，不翻转新选择 |
| 升级且命中 ZCode／Hermes 旧 schema | 以前的 0 可能变成历史用量 | 会发生，需更新说明告知 |
| 新旧客户端同时在线 | 按设备 naturalKey 独立覆盖，协议兼容 | 可以并存 |
| 生产服务端 | 无 schema／migration 变化 | 不要求随客户端升级 |

不需要重置本地 `usage.json`、设置、设备 secret 或 Keychain，也不需要重新入群。Mac 无 configured 标记的旧 true 迁为 true／configured，旧 false 或缺失统一迁为 true／unconfigured；用户在新版本中任何一次显式操作都会写入 configured=true，此后永久尊重。Windows v1 设置文件只在用户操作实验开关时落盘，因此继续无损保留其原值。

## 6. 更新说明的强制告知内容

`CHANGELOG.md` 已增加 Unreleased 说明，明确包含以下四点：

1. 升级后会自动扫描的新增产品目录清单；
2. 升级后实验统计默认开启（包括 Mac 老用户），新版本中的显式关闭永久尊重；
3. 自动补计最多 180 天历史，排行榜和个人总量可能因此上涨；
4. Windows ZCode 不进开关，Cursor 手动导入与 Copilot OTel exporter 前置保持不变。

同时单独披露 ZCode／Hermes 的旧 schema 回填，以及 WorkBuddy 的去重、模型键和 cache 口径变化。发版前仍需维护者对最终用户文案做措辞把关。

## 7. 服务端与 10 万行／设备配额

代码确认：服务端 `tool` 和 `model` 是受长度与字符约束的自由字符串；本轮不需要 migration，且当前 diff 没有 `server/` 变更。

容量粗算按验收要求使用最保守的“每工具每天只有一个模型桶”基线：

- `180 天 × 19 个工具名 = 3,420 行／设备`；
- 占 `USAGE_MAX_ROWS_PER_DEVICE = 100,000` 的 3.42%；
- 要单靠这 180 天达到 10 万行，平均需要每天约 556 个 tool×model 桶，等价于 19 个工具每天各约 29.2 个不同模型桶。

因此一模型／工具／天的常规使用离上限较远，但 3,420 只是下界，不是上界。服务端 naturalKey 行永久保留，隐藏 tombstone 也计配额；多模型、模型名频繁变化和长期历史会继续累积。放量前应在 staging 记录真实每设备桶数分布，并对高分位用户设置告警。

## 8. 验证证据与边界

最终执行：

```bash
bash script/verify_tokenstep_swift.sh
git diff --check
```

结果：`TokenFleet Swift verification passed`，`git diff --check` 无输出。

本轮新增并实际执行的 `TokenStepLogicHarness` 场景包括：

- 有真实 usage fixture 时关闭实验总开关，WorkBuddy／CodeBuddy 状态为 disabled 且总量为 0；
- WorkBuddy 冲突模型字段优先级、无模型 `unknown`、请求去重；
- CodeBuddy user usage 拒收；
- Antigravity statusline 拒收、Gemini camelCase thinking、TeamSync bucket 可构建；
- dsh 隐藏目录、明文／zstd 双胞胎、压缩优先、完全缺解码器，以及“部分明文可读＋压缩-only 不可读”的 `partial_missing_decoder`；
- Copilot DB 重合窗口、同日无 session ID fallback 删除，以及较早无 ID／明确其他 session／Chat 历史保留；
- Cursor BOM、纯日期、重复导入、组合字符 scalar 上限、截断后空格碰撞合并和 TeamSync bucket 构建。

验证脚本会对 XCTest 源码做编译检查，但当前 CommandLineTools 没有真实 XCTest runtime，因此没有执行 XCTest binary；脚本也明确输出 `XCTest type-check skipped: active CommandLineTools has no XCTest module`。上述关键路径之所以可以称为“跑过”，依据是独立可执行的 logic harness，不是 XCTest 文件存在或编译通过。

这仍然只是协议 fixture 证据，不能写成“真实产品版本全部正式验证”。

## 9. 建议放量方式：直接利用现有已安装用户

维护者补充后，放量判断修正如下：TokenFleet 已经发给现有用户，很多老用户的电脑本来就安装并实际使用了这些 Agent，没有必要再单独招募 8–15 台“真机”。现有安装用户就是最有代表性的样本池，更新可以直接提供给他们。

- 价值不只是“模型名更多”。模型通常由云端 Agent 调用，TokenFleet 真正读取的是本地日志里实际出现的模型 ID；更关键的是现有用户覆盖了不同产品版本、账号类型、IDE／安装路径、功能开关和日志 schema。
- 更新后可以立即利用真实日志验证 Copilot DB+OTel 同机、dsh 明文／zstd／cache、Antigravity thinking／tool usage、WorkBuddy、CodeBuddy／Qoder，以及 Cursor 大归档。
- 不需要新建一批测试用户，也不需要限制谁能下载；更新说明仍必须完整披露自动扫描、最多 180 天补计和排行榜上涨。
- 征集反馈只收 usage 字段、来源状态、字段名和脱敏 ID，不收 prompt、回复或代码正文。

默认开启版本发布后，现有用户会直接形成完整真实样本并同步新增来源。按既定计划连续巡检 7 天：发现口径错误立即修复，让相同 naturalKey 的桶由后续同步覆盖自愈；凡是修复后不再发送旧桶、无法自动消除的不可自愈残留，必须逐项列出 naturalKey 清单并走管理员通道清理，不能把不可逆账本当作无需处理的观察噪声。

## 10. 提交与发布门

1. **Claude 快速终审**：第二轮新增项已修，本报告交 Claude 只读确认，通过后形成提交。
2. **现有用户更新**：终审后直接向已有安装用户提供更新，不再另招一批真机；验证设置页、截图、真实日志结构、历史回填、内存和本地总量。
3. **生产榜放量**：新来源 TeamSync 最好与客户端可安装分开，待现有用户真实样本确认后再开放；若选择同版直接同步，需明确接受错误 naturalKey 可能永久残留的风险。

真实样本仍是发布风险：CodeBuddy、Qoder、Antigravity、Droid、dsh 等产品版本可能存在字段差异。dsh 还需观察大 session 整文件解压的内存峰值。Copilot OTel 只读取产品或用户已经开启的 exporter，不应宣传为所有 Copilot 用户自动有数据。

## 11. 给 Claude 的快速终审任务

请在 `<PROJECT_ROOT>` 对分支 `codex/tokenfleet-platform` 的未提交工作树做独立只读增量复核。不要修改文件、提交、安装 App、读取真实对话正文、访问真实 Keychain、开启 OTel、上传数据或连接生产 TeamSync。

优先审查：

- `TokenStepSwift/Sources/TokenStepSwift/Services/UsageCollector.swift`
- `TokenStepSwift/Sources/TokenStepSwift/Services/CursorUsageCSVParser.swift`
- `TokenStepSwift/Tests/TokenStepSwiftTests/UsageCollectorExperimentalAgentTests.swift`
- `script/fixtures/TokenStepLogicHarness.swift`
- `TokenStepSwift/Sources/TokenStepSwift/Views/Settings/SettingsDisplayRefreshCards.swift`
- `CHANGELOG.md`

建议重新执行：

```bash
git diff --check
bash script/verify_tokenstep_swift.sh
```

请重点回答：

1. dsh 的 `partial_missing_decoder` 是否覆盖混合场景，且不会把有明文孪生的压缩副本误报为缺失？
2. Copilot 去掉死 ID 分支后，“明确 session 的时间窗＋无 session ID 的同日 fallback 压制”是否既避免双算，又保留 Chat、其他 session 和更早历史？
3. Cursor 归档条数是否已经从 SwiftUI body 的同步读盘移出？
4. modelKey 与 TeamSync validate 的 Unicode scalar 上限、截断后 trim、旧缓存聚合再清洗是否完全闭环，是否仍可能触发 422／duplicateBucket？
5. 新增 runtime harness 是否真实执行了上述正反路径，报告措辞是否与验证能力相符？
6. 是否同意：形成提交并直接向现有安装用户提供客户端更新；新来源先本地验证、生产 TeamSync 延后一版或走 staging。若不同意，请给出 P0／P1／P2、文件行号与可复现依据。

不要把 fixture 通过写成真实产品正式支持；也不要顺手改代码。
