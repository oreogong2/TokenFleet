# TokenFleet beta.8 采集器可行性与隐私边界

核对日期：2026-08-13。本文只把可验证的本地数值字段视为 Token 证据，不用文本长度估算，也不把“安装过某个工具”写成“已支持”。

## 统一隐私边界

TokenFleet 只允许读取日期、工具、模型、输入、输出、缓存读、缓存写、来源自带费用和不含业务含义的请求去重 ID。不得读取、解析、上传或展示对话正文、prompt、回复、代码、工具参数、工具结果、文件内容、项目目录、工作区路径、账号令牌或 API 密钥。

如果 usage 数字和正文混在同一份会话文件中，不能因为“代码只取 usage 字段”就把它认定为安全来源；除非上游另有独立统计文件或经过用户明确开启的无正文遥测输出，否则保持不支持。

## beta.8 可行性矩阵

| 工具 | 本机核对结果 | 可验证字段/来源 | beta.8 状态 | 原因与边界 |
| --- | --- | --- | --- | --- |
| Kimi Code CLI | 当前测试机未安装，未发现可复核样本 | 上游 `StatusUpdate.token_usage` 提供 `input_other`、`output`、`input_cache_read`、`input_cache_creation`，但常见 `wire.jsonl` 同时承载会话事件 | 原生采集不启用 | 不能扫描混有对话和工具事件的会话文件。只有 CC Switch `proxy_request_logs` 出现成功且 Token 大于 0 的真实代理行时，才以 `Kimi via CC Switch (experimental)` 独立计入。 |
| DeepSeek | 当前测试机未安装；未确认统一的官方桌面/CLI 本地 usage 账本 | DeepSeek 是模型/服务名，第三方 CLI 的落盘格式不构成统一产品合同 | 原生采集不启用 | 不按模型名猜来源，不读取第三方客户端会话正文。只有 CC Switch 的真实代理 usage 行会显示为 `DeepSeek via CC Switch (experimental)`。 |
| Cursor | 当前测试机未安装，未发现可复核样本 | 未确认 Cursor 提供独立、稳定、无正文的本地 Token 明细文件 | 原生采集不启用 | 不读取编辑器会话库、项目索引或认证存储，也不调用需要提取账号令牌的非公开接口。CC Switch 真实代理行只能作为 `Cursor via CC Switch (experimental)` 独立来源。 |
| Gemini CLI | 当前测试机没有 Gemini CLI；仅有另一款工具的 `.gemini` 目录，不能混认 | 官方 OpenTelemetry 指标 `gemini_cli.token.usage`，维度含 `model` 与 `type=input/output/thought/cache/tool` | 候选，beta.8 不默认计入 | 官方遥测默认关闭；只有用户自行启用本地 outfile、关闭 prompt 记录并关闭 traces，且取得真实无正文样本后才可开发原生解析器。现有 CC Switch 成功代理行仍可作为 `Gemini via CC Switch` 独立来源。 |
| WorkBuddy | 本机发现的项目 JSONL 将 usage 与 message、工具参数／结果等事件放在同类文件 | 没有发现独立、稳定的 usage-only 数据库、文件或公开导出合同 | 不支持；发现目录也不打开 | 解析整行后再丢弃正文仍然违反隐私边界。需要产品侧提供 usage-only 数据源，或经过明确配置且不含正文的本地导出后再开发。 |

## 已落地的可验证路径

beta.8 保留 CC Switch SQLite 只读采集，并继续使用严格条件：HTTP 2xx、`data_source = proxy`、四类 Token 合计大于 0。查询只选择请求时间、`app_type`、模型、四类 Token、来源费用和请求去重 ID；不选择请求体、响应体、prompt、代码或路径字段。

CC Switch 与原生记录只有在请求／响应 ID 唯一吻合时才去重。会话 ID 只表示同一段会话，不是单次请求身份；即使会话、时间、模型和 Token 向量都相似，也不会被猜测删除。这些记录继续计入，并在本地来源诊断中记录 `possible_overlap_records`，便于排查潜在重复而不牺牲真实并发请求。

Kimi、DeepSeek、Cursor 的 CC Switch 名称明确带有 `experimental`，不会伪装成原生支持；没有真实行时界面不会出现它们。Gemini 的代理来源同样不等于 Gemini CLI 原生日志支持。

## 原生采集器进入正式支持的门槛

1. 至少取得 2–3 台真实机器的同版本样本，并只记录字段结构和脱敏数字。
2. usage 必须位于独立统计文件、独立数据库表或用户明确配置的无正文遥测中。
3. 能证明按请求或事件去重，能区分输入、输出、缓存读、缓存写；总数口径可复算。
4. 采集器使用只读访问，默认关闭或在首次启用时清晰告知数据边界。
5. 添加“含诱饵正文但绝不进入统计/上传”的隐私测试、重复事件测试、损坏文件测试和大文件性能测试。
6. 设置页与文档必须区分“原生”“经代理”“候选”，没有数据不得展示空品牌卡冒充支持。

## 参考真源

- Gemini CLI 官方 OpenTelemetry 文档：<https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/telemetry.md>
- Kimi Code CLI 官方仓库与命令文档：<https://github.com/MoonshotAI/kimi-code>
- Kimi CLI 关于 ACP usage 尚未透传的公开问题：<https://github.com/MoonshotAI/kimi-cli/issues/2394>
