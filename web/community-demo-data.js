const NAMES = [
  "演示·蓝鲸",
  "演示·云帆",
  "演示·星河",
  "演示·青岚",
  "演示·这是一个专门验证窄屏截断且不对应任何真实成员的超长虚构昵称",
  "演示·木棉",
  "演示·极光",
  "演示·七星",
  "演示·远山",
  "演示·晴空",
  "演示·轻舟",
  "演示·银河",
];

const DEMO_COMBINATIONS = [
  { tool: "Codex", model: "gpt-5.6-sol" },
  { tool: "Claude Code", model: "claude-opus-4.1" },
  { tool: "Codex", model: "gpt-5.2-codex" },
  { tool: "Claude Code", model: "claude-sonnet-4" },
  { tool: "CC Switch", model: "kimi-k2" },
  { tool: "CC Switch", model: "deepseek-v3" },
];
const TOOLS = [...new Set(DEMO_COMBINATIONS.map(({ tool }) => tool))];
const MODELS = [...new Set(DEMO_COMBINATIONS.map(({ model }) => model))];
// This exists solely for the local, clearly labelled demo.  Production never
// accepts a front-end value as proof of membership; it redeems a one-time
// server-issued grant.
export const DEMO_COMMUNITY_SHARE_GRANT = "demo_community_share_grant_0123456789_abcdefghijklmnop";

function pause(milliseconds) {
  return milliseconds > 0
    ? new Promise((resolve) => setTimeout(resolve, milliseconds))
    : Promise.resolve();
}

function totalsFor(index, { unpriced = false } = {}) {
  const factor = BigInt(15 - index);
  const input = factor * 7340000n;
  const output = factor * 1830000n;
  const cacheRead = factor * 21540000n;
  const cacheWrite = factor * 2410000n;
  const total = input + output + cacheRead + cacheWrite;
  return {
    input_tokens: input.toString(),
    output_tokens: output.toString(),
    cache_read_tokens: cacheRead.toString(),
    cache_write_tokens: cacheWrite.toString(),
    norm_tokens: (input + output).toString(),
    total_tokens: total.toString(),
    estimated_cost_microunits: unpriced ? null : (factor * 284512n).toString(),
    cost_currency: unpriced ? null : "USD",
    unpriced,
    mixed_currency: false,
  };
}

const records = NAMES.map((nickname, index) => {
  const combination = DEMO_COMBINATIONS[index % DEMO_COMBINATIONS.length];
  return {
    public_id: `demo-${index + 1}`,
    nickname,
    rank: index + 1,
    totals: totalsFor(index, { unpriced: index === 3 }),
    tool: combination.tool,
    model: combination.model,
  };
});

const outsideRecord = {
  public_id: "outside-100",
  nickname: "演示·远航",
  rank: 137,
  totals: totalsFor(13),
  tool: "CC Switch",
  model: "kimi-k2",
};

function metricValue(record, metric) {
  if (metric === "norm") return record.totals.norm_tokens;
  if (metric === "cost") return record.totals.estimated_cost_microunits;
  return record.totals.total_tokens;
}

function publicEntry(record, metric) {
  const value = metricValue(record, metric);
  const primaryTokens = (BigInt(record.totals.total_tokens) * 4n / 5n).toString();
  return {
    rank: metric === "cost" && value === null ? null : record.rank,
    public_id: record.public_id,
    nickname: record.nickname,
    metric_value: value,
    primary_tool: record.tool,
    primary_tool_tokens: primaryTokens,
    tool_count: 2,
    primary_model: record.model,
    primary_model_tokens: primaryTokens,
    model_count: 2,
    totals: { ...record.totals },
  };
}

function distribution(record, metric) {
  const first = publicEntry(record, metric).totals;
  const second = {
    ...first,
    input_tokens: (BigInt(first.input_tokens) / 4n).toString(),
    output_tokens: (BigInt(first.output_tokens) / 4n).toString(),
    cache_read_tokens: (BigInt(first.cache_read_tokens) / 4n).toString(),
    cache_write_tokens: (BigInt(first.cache_write_tokens) / 4n).toString(),
  };
  second.norm_tokens = (BigInt(second.input_tokens) + BigInt(second.output_tokens)).toString();
  second.total_tokens = (
    BigInt(second.input_tokens) + BigInt(second.output_tokens) +
    BigInt(second.cache_read_tokens) + BigInt(second.cache_write_tokens)
  ).toString();
  if (second.estimated_cost_microunits !== null) {
    second.estimated_cost_microunits = (BigInt(second.estimated_cost_microunits) / 4n).toString();
  }
  const secondMetric = metric === "norm"
    ? second.norm_tokens
    : metric === "cost"
      ? second.estimated_cost_microunits
      : second.total_tokens;
  return [
    { name: record.tool, metric_value: metricValue(record, metric), totals: first },
    { name: record.tool === "Codex" ? "Claude Code" : "Codex", metric_value: secondMetric, totals: second },
  ];
}

function trend(record) {
  return Array.from({ length: 14 }, (_, index) => {
    const date = new Date(Date.UTC(2026, 6, 27 + index)).toISOString().slice(0, 10);
    const divisor = BigInt(18 - index);
    const input = BigInt(record.totals.input_tokens) / divisor;
    const output = BigInt(record.totals.output_tokens) / divisor;
    const cacheRead = BigInt(record.totals.cache_read_tokens) / divisor;
    const cacheWrite = BigInt(record.totals.cache_write_tokens) / divisor;
    return {
      date,
      totals: {
        input_tokens: input.toString(),
        output_tokens: output.toString(),
        cache_read_tokens: cacheRead.toString(),
        cache_write_tokens: cacheWrite.toString(),
        norm_tokens: (input + output).toString(),
        total_tokens: (input + output + cacheRead + cacheWrite).toString(),
        estimated_cost_microunits: null,
        cost_currency: null,
        unpriced: true,
        mixed_currency: false,
      },
    };
  });
}

function detailFor(record, metric) {
  return {
    ...publicEntry(record, metric),
    mixed_timezones: true,
    timezone_warning: "部分数据来自不同的设备本地时区。",
    tool_distribution: distribution(record, metric),
    model_distribution: distribution({ ...record, tool: record.model }, metric),
    daily_trend: trend(record),
  };
}

function costBucket({ date = "", currency = "USD", amount = "1000000", unpriced = false } = {}) {
  return {
    ...(date ? { date } : {}),
    metric_value: unpriced ? null : amount,
    totals: {
      input_tokens: "10",
      output_tokens: "5",
      cache_read_tokens: "2",
      cache_write_tokens: "1",
      norm_tokens: "15",
      total_tokens: "18",
      estimated_cost_microunits: unpriced ? null : amount,
      cost_currency: unpriced ? null : currency,
      unpriced,
      mixed_currency: false,
    },
  };
}

function mixedCostDetail({ currencies = ["USD", null, "USD"] } = {}) {
  const mixedCurrency = new Set(currencies.filter(Boolean)).size > 1;
  const hasUnpriced = currencies.some((currency) => !currency);
  const daily = currencies.map((currency, index) => costBucket({
    date: `2026-08-0${index + 1}`,
    currency: currency || "USD",
    amount: String((index + 1) * 1_000_000),
    unpriced: !currency,
  }));
  const distributions = currencies.slice(0, 2).map((currency, index) => ({
    name: index === 0 ? "Codex" : "Claude Code",
    ...costBucket({
      currency: currency || "USD",
      amount: String((index + 1) * 1_000_000),
      unpriced: !currency,
    }),
  }));
  return {
    public_id: mixedCurrency ? "mixed-currency" : "mixed-cost",
    nickname: mixedCurrency ? "混合币种示例" : "部分未定价示例",
    rank: null,
    metric_value: null,
    totals: {
      input_tokens: "30",
      output_tokens: "15",
      cache_read_tokens: "6",
      cache_write_tokens: "3",
      norm_tokens: "45",
      total_tokens: "54",
      estimated_cost_microunits: null,
      cost_currency: null,
      unpriced: hasUnpriced,
      mixed_currency: mixedCurrency,
    },
    tool_distribution: distributions,
    model_distribution: distributions.map((item, index) => ({
      ...item,
      name: index === 0 ? "gpt-5.2-codex" : "claude-opus-4.1",
      tool: index === 0 ? "Codex" : "Claude Code",
    })),
    daily_trend: daily,
  };
}

export function createCommunityDemoApi({ empty = false, locationRef = globalThis.location } = {}) {
  const scenario = new URLSearchParams(String(locationRef?.search || "").replace(/^\?/, "")).get("scenario") || "";
  const delay = async (kind) => {
    const slow = scenario === "slow-public" ||
      (kind === "member" && ["slow-profile", "slow-share"].includes(scenario));
    if (slow) await pause(300);
  };
  return {
    async capabilities() {
      await delay("capabilities");
      return {
        tools: TOOLS,
        tools_total: TOOLS.length,
        models: MODELS,
        model_keys: MODELS.map((model) => model.toLowerCase()),
        models_total: MODELS.length,
        partial: false,
        timezone: "Asia/Shanghai",
        end_date: "2026-08-09",
      };
    },
    async leaderboard(filters = {}) {
      await delay("leaderboard");
      if (empty) return {
        period: filters.period || "today",
        metric: filters.metric || "tokens",
        total_entries: 0,
        available_tools: [...TOOLS],
        available_models: [...MODELS],
        available_model_keys: MODELS.map((model) => model.toLowerCase()),
        mixed_timezones: true,
        timezone_warning: "部分数据来自不同的设备本地时区。",
        entries: [],
      };
      const metric = filters.metric || "tokens";
      const filtered = records.filter((record) =>
        (!filters.tool || record.tool === filters.tool) &&
        (!filters.model || record.model === filters.model),
      );
      let nextRank = 0;
      return {
        period: filters.period || "today",
        metric,
        generated_at: "2026-08-09T12:00:00Z",
        available_tools: [...TOOLS],
        available_models: [...MODELS],
        available_model_keys: MODELS.map((model) => model.toLowerCase()),
        mixed_timezones: true,
        timezone_warning: "部分数据来自不同的设备本地时区。",
        total_entries: filtered.length,
        entries: filtered.map((record) => {
          const entry = publicEntry(record, metric);
          return { ...entry, rank: entry.metric_value === null ? null : ++nextRank };
        }),
      };
    },
    async member(publicId, filters = {}) {
      await delay("member");
      if (publicId === "mixed-cost") return mixedCostDetail();
      if (publicId === "mixed-currency") return mixedCostDetail({ currencies: ["USD", "CNY"] });
      const record = [...records, outsideRecord].find((item) => item.public_id === publicId);
      if (!record) {
        const error = new Error("这个公开资料不存在或已关闭");
        error.status = 404;
        throw error;
      }
      return detailFor(record, filters.metric || "tokens");
    },
    async claimInvitationBatch(payload = {}) {
      return {
        nickname: String(payload.display_name || "演示成员").trim(),
        enrollment_token: "demo_batch_once_7Yp4_K2m9_A8q6_H3v5_N1s7",
        expires_at: "2026-08-10T13:00:00Z",
      };
    },
    async redeemCommunityShareGrant(grant) {
      if (String(grant || "") !== DEMO_COMMUNITY_SHARE_GRANT) {
        const error = new Error("分享凭证已失效，请返回 App 重新打开排行榜");
        error.status = 403;
        throw error;
      }
      return { public_id: "demo-1" };
    },
  };
}
