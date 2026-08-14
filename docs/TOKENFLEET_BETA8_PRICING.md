# TokenFleet beta.8 费用估算口径

核对日期：2026-08-14；价目版本：`public-usd-2026-08-14`。

TokenFleet 显示的是公开 API 标准价的等价估算，不是 ChatGPT、Claude 或其他产品的订阅费用，也不是路由商、企业折扣、Batch、Flex、Priority、区域处理或税费后的真实账单。

## 计价规则

- 来源日志给出大于 0 的明确费用时优先使用来源费用。
- 没有来源费用时，仅对精确识别的 Codex/OpenAI 与 Claude Code/Anthropic 模型使用版本化公开价目。
- 输入、输出、缓存读、缓存写必须组成完整且可复算的 Token 明细；缺一项、总数不一致、别名不确定或模型未知时标为“未计价”。
- OpenAI 使用标准处理、标准上下文公开价。GPT-5.4 与 GPT-5.6 超过 272K 输入的请求可能适用更高费率；本地日汇总不能可靠复原单次请求上下文，因此界面只称“标准价等价估算”，不称真实费用。
- Anthropic 的 5 分钟与 1 小时缓存写价格不同。来源没有给出费用且本地字段不能区分缓存 TTL 时，只把缓存写 Token 标为未计价；同一条记录中可确定的输入、输出与缓存读仍按公开价计算，并显示覆盖率。
- 已计价覆盖率随日汇总保存并展示。部分可计价时同时显示覆盖率，0 元但没有覆盖率时显示“未计价”，不会用通用 `$1/MTok` 或 `$3/MTok` 猜测。

## 官方价目真源

- OpenAI GPT-5.6 Sol：<https://developers.openai.com/api/docs/models/gpt-5.6-sol>
- OpenAI GPT-5.6 Terra：<https://developers.openai.com/api/docs/models/gpt-5.6-terra>
- OpenAI GPT-5.6 Luna：<https://developers.openai.com/api/docs/models/gpt-5.6-luna>
- OpenAI GPT-5.4 模型页：<https://developers.openai.com/api/docs/models/gpt-5.4>
- Anthropic Pricing：<https://www.anthropic.com/pricing>
- Claude Sonnet 5 定价与生效日期：<https://www.anthropic.com/claude/sonnet>

正式发布前必须实际打开并重新核对这些官方页面，搜索摘要或缓存片段不作为价格真源。价目变化必须新建目录版本；旧快照会立即按新目录重新估算，并显示一次性迁移说明，明确 Token 消耗和原始记录没有变化、金额可能变化，不能静默改写历史估算。
