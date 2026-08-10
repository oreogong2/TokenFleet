import {
  compareTokenValues,
  formatMicrounitAmount,
  toTokenBigInt,
} from "./server-adapter.js";

export const PUBLIC_PERIODS = Object.freeze([
  ["today", "今天"],
  ["yesterday", "昨天"],
  ["3d", "近 3 天"],
  ["7d", "近 7 天"],
  ["30d", "近 30 天"],
  ["90d", "近 90 天"],
  ["all", "全部"],
]);

export const PUBLIC_METRICS = Object.freeze([
  ["tokens", "含缓存"],
  ["norm", "不含缓存"],
  ["cost", "估算费用"],
]);

const PERIOD_KEYS = new Set(PUBLIC_PERIODS.map(([value]) => value));
const METRIC_KEYS = new Set(PUBLIC_METRICS.map(([value]) => value));
const SAFE_PUBLIC_ID = /^[A-Za-z0-9_-]{1,128}$/;
const CURRENCY = /^[A-Z]{3}$/;

function text(value, fallback = "") {
  const normalized = String(value ?? "").replace(/[\u0000-\u001f\u007f]/g, "").trim();
  return normalized ? normalized.slice(0, 128) : fallback;
}

function token(value) {
  return toTokenBigInt(value).toString();
}

function tokenTotal(value = {}) {
  return (
    toTokenBigInt(value.input_tokens ?? value.inputTokens) +
    toTokenBigInt(value.output_tokens ?? value.outputTokens) +
    toTokenBigInt(value.cache_read_tokens ?? value.cacheReadTokens) +
    toTokenBigInt(value.cache_write_tokens ?? value.cacheWriteTokens)
  );
}

function normalizeBreakdown(values, { includeTool = false } = {}) {
  if (!Array.isArray(values)) return [];
  return values.slice(0, 64).map((item) => {
    const totals = item?.totals ?? item ?? {};
    const inputTokens = token(totals.input_tokens ?? totals.inputTokens);
    const outputTokens = token(totals.output_tokens ?? totals.outputTokens);
    const cacheReadTokens = token(totals.cache_read_tokens ?? totals.cacheReadTokens);
    const cacheWriteTokens = token(totals.cache_write_tokens ?? totals.cacheWriteTokens);
    return {
      name: text(item?.name ?? item?.model ?? item?.tool, "未识别"),
      inputTokens,
      outputTokens,
      cacheReadTokens,
      cacheWriteTokens,
      normTokens: (toTokenBigInt(inputTokens) + toTokenBigInt(outputTokens)).toString(),
      totalTokens: tokenTotal({ inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens }).toString(),
      metricValue: item?.metric_value === null || item?.metric_value === undefined
        ? null
        : token(item.metric_value),
      cost: normalizePublicCost(totals),
      ...(includeTool && item?.tool ? { tool: text(item.tool) } : {}),
    };
  });
}

function normalizeTrend(values) {
  if (!Array.isArray(values)) return [];
  return values.slice(-370).map((item) => {
    const totals = item?.totals ?? item ?? {};
    const inputTokens = token(totals.input_tokens ?? totals.inputTokens);
    const outputTokens = token(totals.output_tokens ?? totals.outputTokens);
    const cacheReadTokens = token(totals.cache_read_tokens ?? totals.cacheReadTokens);
    const cacheWriteTokens = token(totals.cache_write_tokens ?? totals.cacheWriteTokens);
    return {
      date: /^\d{4}-\d{2}-\d{2}$/.test(String(item?.date || "")) ? String(item.date) : "",
      inputTokens,
      outputTokens,
      cacheReadTokens,
      cacheWriteTokens,
      normTokens: (toTokenBigInt(inputTokens) + toTokenBigInt(outputTokens)).toString(),
      totalTokens: tokenTotal({ inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens }).toString(),
      metricValue: item?.metric_value === null || item?.metric_value === undefined
        ? null
        : token(item.metric_value),
      cost: normalizePublicCost(totals),
    };
  }).filter((item) => item.date);
}

function normalizePublicCost(value = {}) {
  const totals = value.totals ?? value;
  const currency = String(totals.cost_currency || "").toUpperCase();
  const rawMicrounits = totals.estimated_cost_microunits;
  if (
    totals.unpriced === true ||
    totals.mixed_currency === true ||
    rawMicrounits === null ||
    rawMicrounits === undefined ||
    !CURRENCY.test(currency)
  ) {
    return {
      unpriced: true,
      mixedCurrency: totals.mixed_currency === true,
      partiallyUnpriced: false,
      amounts: [],
    };
  }
  return {
    unpriced: false,
    mixedCurrency: false,
    partiallyUnpriced: false,
    amounts: [{ currency, microunits: token(rawMicrounits) }],
  };
}

export function formatPublicCost(cost) {
  if (!cost || cost.unpriced || !cost.amounts?.length) return "未定价";
  const priced = cost.amounts
    .map((item) => formatMicrounitAmount(item.microunits, item.currency))
    .join(" · ");
  return cost.partiallyUnpriced ? `${priced} · 部分未定价` : priced;
}

export function normalizePublicParticipant(value = {}) {
  const publicId = text(value.public_id ?? value.publicId);
  if (!SAFE_PUBLIC_ID.test(publicId)) return null;
  const totals = value.totals ?? value;
  const inputTokens = token(totals.input_tokens ?? totals.inputTokens);
  const outputTokens = token(totals.output_tokens ?? totals.outputTokens);
  const cacheReadTokens = token(totals.cache_read_tokens ?? totals.cacheReadTokens);
  const cacheWriteTokens = token(totals.cache_write_tokens ?? totals.cacheWriteTokens);
  const computedTotal = tokenTotal({
    inputTokens,
    outputTokens,
    cacheReadTokens,
    cacheWriteTokens,
  });
  return {
    publicId,
    displayName: text(value.nickname ?? value.display_name ?? value.displayName, "匿名参赛者"),
    rank: value.rank === null ? null : Math.max(0, Math.trunc(Number(value.rank) || 0)) || null,
    metricValue: value.metric_value === null || value.metric_value === undefined
      ? null
      : token(value.metric_value),
    inputTokens,
    outputTokens,
    cacheReadTokens,
    cacheWriteTokens,
    totalTokens: computedTotal.toString(),
    normTokens: (toTokenBigInt(inputTokens) + toTokenBigInt(outputTokens)).toString(),
    cost: normalizePublicCost({ ...value, totals }),
    tools: normalizeBreakdown(value.tool_distribution ?? value.tools ?? value.by_tool),
    models: normalizeBreakdown(value.model_distribution ?? value.models ?? value.by_model, { includeTool: true }),
    dailyTrend: normalizeTrend(value.daily_trend ?? value.daily_series ?? value.series),
  };
}

function metricValue(person, metric) {
  if (person.metricValue !== null) return person.metricValue;
  if (metric === "norm") return person.normTokens;
  if (metric === "cost") {
    if (person.cost.unpriced || person.cost.amounts.length !== 1) return null;
    return person.cost.amounts[0].microunits;
  }
  return person.totalTokens;
}

export function sanitizePublicFilters(value = {}) {
  const period = PERIOD_KEYS.has(value.period) ? value.period : "today";
  const metric = METRIC_KEYS.has(value.metric) ? value.metric : "tokens";
  return {
    period,
    metric,
    tool: text(value.tool),
    model: text(value.model),
  };
}

export function normalizePublicLeaderboard(payload = {}, rawFilters = {}) {
  const filters = sanitizePublicFilters({
    period: payload.period ?? rawFilters.period,
    metric: payload.metric ?? rawFilters.metric,
    tool: rawFilters.tool,
    model: rawFilters.model,
  });
  const source = Array.isArray(payload) ? payload :
    payload.entries ?? payload.participants ?? payload.items ?? payload.leaderboard ?? [];
  const participants = (Array.isArray(source) ? source : [])
    .filter((item) => item?.public_profile_enabled !== false && item?.is_active !== false)
    .map(normalizePublicParticipant)
    .filter(Boolean)
    .sort((left, right) => {
      if (left.rank !== null && right.rank !== null && left.rank !== right.rank) {
        return left.rank - right.rank;
      }
      if (left.rank !== null && right.rank === null) return -1;
      if (right.rank !== null && left.rank === null) return 1;
      const leftMetric = metricValue(left, filters.metric);
      const rightMetric = metricValue(right, filters.metric);
      if (leftMetric === null && rightMetric !== null) return 1;
      if (rightMetric === null && leftMetric !== null) return -1;
      const compared = compareTokenValues(rightMetric, leftMetric);
      return compared || left.displayName.localeCompare(right.displayName, "zh-CN");
    });

  const availableTools = [...new Set([
    ...(Array.isArray(payload.available_tools) ? payload.available_tools.map((item) => text(item)) : []),
    ...participants.flatMap((person) => person.tools.map((item) => item.name)),
  ].filter(Boolean))].sort((left, right) => left.localeCompare(right, "zh-CN"));
  const availableModels = [...new Set([
    ...(Array.isArray(payload.available_models) ? payload.available_models.map((item) => text(item)) : []),
    ...participants.flatMap((person) => person.models.map((item) => item.name)),
  ].filter(Boolean))].sort((left, right) => left.localeCompare(right, "zh-CN"));

  return {
    period: filters.period,
    metric: filters.metric,
    tool: filters.tool,
    model: filters.model,
    participants,
    totalEntries: Math.max(
      participants.length,
      Math.max(0, Math.trunc(Number(payload.total_entries ?? payload.totalEntries) || 0)),
    ),
    availableTools,
    availableModels,
    generatedAt: text(payload.generated_at),
    mixedTimezones: payload.mixed_timezones === true,
    timezoneWarning: text(payload.timezone_warning),
  };
}

export function normalizePublicMemberDetail(payload = {}) {
  const value = payload.participant ?? payload.member ?? payload;
  const participant = normalizePublicParticipant(value);
  if (!participant) return null;
  return {
    ...participant,
    mixedTimezones: payload.mixed_timezones === true,
    timezoneWarning: text(payload.timezone_warning),
  };
}

export function publicMetricValue(person, metric) {
  return metricValue(person, sanitizePublicFilters({ metric }).metric);
}

export function parseCommunityRoute(locationRef = globalThis.location) {
  if (!locationRef) return null;
  const pathname = String(locationRef.pathname || "/").replace(/\/+$/, "") || "/";
  const rawHash = String(locationRef.hash || "");
  const hashRoute = rawHash.startsWith("#/") ? rawHash.slice(1) : "";
  const candidate = hashRoute || pathname;
  const [routePath, query = ""] = candidate.split("?");
  const params = new URLSearchParams(query || String(locationRef.search || "").replace(/^\?/, ""));

  if (["/rank", "/community"].includes(routePath) || ["rank", "community"].includes(params.get("view"))) {
    return { kind: "leaderboard", filters: sanitizePublicFilters(Object.fromEntries(params)) };
  }
  const profile = routePath.match(/^\/(?:rank|community)\/p\/([A-Za-z0-9_-]{1,128})$/);
  if (profile) {
    return {
      kind: "profile",
      publicId: profile[1],
      filters: sanitizePublicFilters(Object.fromEntries(params)),
    };
  }
  if (routePath === "/join" || params.get("view") === "join") return { kind: "join" };
  return null;
}

export function communityHref({ kind = "leaderboard", publicId = "", filters = {} } = {}) {
  const safeFilters = sanitizePublicFilters(filters);
  const query = new URLSearchParams();
  if (safeFilters.period !== "today") query.set("period", safeFilters.period);
  if (safeFilters.metric !== "tokens") query.set("metric", safeFilters.metric);
  if (safeFilters.tool) query.set("tool", safeFilters.tool);
  if (safeFilters.model) query.set("model", safeFilters.model);
  const path = kind === "profile" && SAFE_PUBLIC_ID.test(publicId)
    ? `/rank/p/${publicId}`
    : "/rank";
  const suffix = query.toString() ? `?${query}` : "";
  return `${path}${suffix}`;
}

export function isHttpsPublicUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password;
  } catch {
    return false;
  }
}
