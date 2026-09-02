import { createCommunityApiClient } from "./community-api.js?v=beta11-capability-ledger-1";
import {
  PUBLIC_METRICS,
  PUBLIC_PERIODS,
  communityHref,
  formatPublicCost,
  isHttpsPublicUrl,
  normalizePublicCapabilities,
  normalizePublicLeaderboard,
  normalizePublicMemberDetail,
  publicMetricValue,
  sanitizePublicFilters,
} from "./community-contract.js?v=beta11-capability-ledger-1";
import {
  SUPPORTED_TOOL_CATALOG,
  communityCapabilitiesState,
  loadCommunityCapabilities,
} from "./community-capabilities.js?v=beta11-capability-ledger-1";
import { createCommunityDemoApi } from "./community-demo-data.js?v=beta11-capability-ledger-1";
import { buildCommunityPosterModel, createCommunityPosterArtifact } from "./community-poster.js?v=beta8-canvas-preview-copy";
import { formatTokenCount, toTokenBigInt, tokenRatio } from "./server-adapter.js";

const COMMUNITY_SHARE_GRANT = /^[A-Za-z0-9_-]{43,128}$/;
const COMMUNITY_PUBLIC_ID = /^[A-Za-z0-9_-]{1,128}$/;

// This is intentionally module-memory only.  A valid bridge may survive SPA
// hash navigation so a member can move from the board to their own profile,
// but it disappears on refresh, a new tab, or pagehide.  Do not persist it in
// browser storage or cookies: the App must mint a fresh,
// one-time bridge for every browser page.
let communityShareViewerPublicId = "";

function clearCommunityShareViewer() {
  communityShareViewerPublicId = "";
}

if (typeof globalThis.addEventListener === "function") {
  globalThis.addEventListener("pagehide", clearCommunityShareViewer, { capture: true });
}

/**
 * Consume a bridge value from a #/rank fragment without letting it reach
 * analytics, browser history, the referrer, or UI state.  Invalid values are
 * scrubbed too, but never submitted to the server.
 */
export function takeCommunityShareGrant(locationRef = location, historyRef = history) {
  const hash = String(locationRef?.hash || "");
  if (!hash.startsWith("#/")) return "";
  const rawRoute = hash.slice(1);
  const [routePath, rawQuery = ""] = rawRoute.split("?", 2);
  if (!/^\/(?:rank|community)(?:\/p\/[A-Za-z0-9_-]{1,128})?$/.test(routePath)) return "";
  const params = new URLSearchParams(rawQuery);
  if (!params.has("share_grant")) return "";
  const candidate = String(params.get("share_grant") || "");
  params.delete("share_grant");
  const safeHash = `#${routePath}${params.size ? `?${params}` : ""}`;
  const pathname = String(locationRef?.pathname || "/");
  const search = String(locationRef?.search || "");
  historyRef?.replaceState?.(null, "", `${pathname}${search}${safeHash}`);
  return COMMUNITY_SHARE_GRANT.test(candidate) ? candidate : "";
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function localHref(spec) {
  return `#${communityHref(spec)}`;
}

export function publicShareUrl({
  route = { kind: "leaderboard" },
  filters = {},
  documentRef = document,
  locationRef = location,
  demoMode = false,
} = {}) {
  const path = communityHref({
    kind: route.kind === "profile" ? "profile" : "leaderboard",
    publicId: route.publicId,
    filters,
  });
  if (demoMode) return new URL(path, "https://demo.tokenfleet.example").href;
  const configured = documentRef
    .querySelector('meta[name="tokenfleet-public-base"]')
    ?.getAttribute("content")
    ?.trim();
  try {
    const current = new URL(locationRef.href);
    if (current.protocol !== "https:") return "";
    if (configured) {
      const declared = new URL(configured);
      if (declared.origin !== current.origin || declared.username || declared.password ||
          !["", "/"].includes(declared.pathname) || declared.search || declared.hash) return "";
    }
    const value = new URL(path, current.origin).href;
    return isHttpsPublicUrl(value) ? value : "";
  } catch {
    return "";
  }
}

function formatTokens(value, compact = true) {
  return formatTokenCount(value, { compact });
}

function metricLabel(metric) {
  return PUBLIC_METRICS.find(([key]) => key === metric)?.[1] || "含缓存";
}

function periodLabel(period) {
  return PUBLIC_PERIODS.find(([key]) => key === period)?.[1] || "今天";
}

function metricDisplay(person, metric, compact = true) {
  if (metric === "cost") return formatPublicCost(person.cost);
  return formatTokens(publicMetricValue(person, metric), compact);
}

function publicHeader({ title, description }) {
  return `<header class="community-header"><a class="community-brand" href="#/rank" aria-label="TokenFleet 社群榜首页"><span>TF</span><strong>TokenFleet</strong><small>COMMUNITY LEDGER</small></a><nav aria-label="公开页面导航"><a href="#/rank">社群榜</a><a class="community-install-link" href="/install">安装与参与</a></nav></header><section class="community-hero"><span class="panel-kicker">PUBLIC / PRIVACY-SAFE</span><h1>${escapeHTML(title)}</h1><p>${escapeHTML(description)}</p></section>`;
}

function filterHref(filters, route, name, value) {
  return localHref({
    kind: route.kind === "profile" ? "profile" : "leaderboard",
    publicId: route.publicId,
    filters: sanitizePublicFilters({ ...filters, [name]: value }),
  });
}

function filterGroup(label, name, values, current, filters, route, emptyLabel = "") {
  const namedOptions = [...new Set([current, ...(Array.isArray(values) ? values : [])].filter(Boolean))]
    .map((value) => [value, value]);
  const options = emptyLabel
    ? [["", emptyLabel], ...namedOptions]
    : values;
  return `<div class="community-filter-group" role="group" aria-label="${escapeHTML(label)}"><strong>${escapeHTML(label)}</strong><div>${options.map(([value, optionLabel]) => `<a href="${filterHref(filters, route, name, value)}" ${current === value ? 'aria-current="true"' : ""}>${escapeHTML(optionLabel)}</a>`).join("")}</div></div>`;
}

function filterForm(filters, route, { tools = [], models = [] } = {}) {
  const toolLabel = tools.length ? `不限工具 · 本期有数据 ${tools.length} 种` : "不限工具";
  const modelLabel = models.length ? `不限模型 · 本期有数据 ${models.length} 种` : "不限模型";
  return `<nav class="community-filters" aria-label="排行榜筛选">${filterGroup("日期", "period", PUBLIC_PERIODS, filters.period, filters, route)}${filterGroup("口径", "metric", PUBLIC_METRICS, filters.metric, filters, route)}${filterGroup("工具", "tool", tools, filters.tool, filters, route, toolLabel)}${filterGroup("模型", "model", models, filters.model, filters, route, modelLabel)}</nav>`;
}

function searchIdentity(value) {
  return String(value || "").toLocaleLowerCase("en-US");
}

function capabilityStateView(key) {
  const state = communityCapabilitiesState(key);
  return {
    status: state.status,
    data: state.value ? normalizePublicCapabilities(state.value) : null,
  };
}

export function capabilityDirectory({ capabilityState, leaderboard, filters, route }) {
  const data = capabilityState.data;
  const currentTools = new Set(leaderboard.availableTools);
  const currentModelKeys = new Set(leaderboard.availableModelKeys);
  const supportedLabels = new Set(SUPPORTED_TOOL_CATALOG.map(({ label }) => label));
  const discoveredTools = [
    ...(data?.tools || []),
    ...leaderboard.availableTools,
  ].filter((label, index, values) =>
    !supportedLabels.has(label) && values.indexOf(label) === index
  );
  const tools = [
    ...SUPPORTED_TOOL_CATALOG,
    ...discoveredTools.map((label) => ({
      label,
      displayName: label,
      note: label.includes(" via CC Switch") ? "经 CC Switch" : "公开账本历史出现来源",
      derived: true,
    })),
  ];
  const toolCards = tools.map((tool) => {
    const active = currentTools.has(tool.label);
    return `<a class="community-capability-tool ${active ? "has-data" : "no-data"} ${tool.derived ? "is-derived" : ""}" href="${filterHref(filters, route, "tool", tool.label)}" ${filters.tool === tool.label ? 'aria-current="true"' : ""}><span>${escapeHTML(tool.displayName)}</span><small>${active ? "本期有数据" : "本期暂无数据"}</small><em>${escapeHTML(tool.note)}</em></a>`;
  }).join("");
  const models = data?.models || [];
  const modelItems = models.map((model, index) => {
    const active = currentModelKeys.has(data.modelKeys[index]);
    return `<a class="community-capability-model ${active ? "has-data" : "no-data"}" data-capability-model data-search-value="${escapeHTML(searchIdentity(model))}" href="${filterHref(filters, route, "model", model)}" ${filters.model === model ? 'aria-current="true"' : ""}><span>${escapeHTML(model)}</span><small>${active ? "本期有数据" : "本期 0"}</small></a>`;
  }).join("");
  const toolsCount = data ? String(data.toolsTotal) : "—";
  const modelsCount = data ? String(data.modelsTotal) : "—";
  const loading = ["idle", "loading"].includes(capabilityState.status);
  const modelStatus = loading
    ? '<div class="community-capability-state" role="status"><span></span><p>正在读取公开历史模型目录…</p></div>'
    : capabilityState.status === "failure"
      ? '<div class="community-capability-state is-error" role="alert"><strong>历史模型目录暂时读不到</strong><p>排行榜仍可正常使用；不会拿本期列表冒充完整目录。</p><button class="secondary-button small" type="button" data-community-action="retry-capabilities">重新读取</button></div>'
      : `<div class="community-capability-models" data-capability-models>${modelItems || '<div class="community-capability-state"><p>当前公开账本暂未识别到模型。</p></div>'}</div>`;
  const toolsCompleteness = data && !data.toolsComplete
    ? `<small>当前展示 ${data.tools.length}／共 ${data.toolsTotal} 个历史标签</small>`
    : "";
  const modelsCompleteness = data && !data.modelsComplete
    ? `<small data-capability-model-count>当前展示 ${data.models.length}／共 ${data.modelsTotal} 个模型</small>`
    : `<small data-capability-model-count>${data ? `当前公开历史目录 ${data.models.length} 个模型` : "目录读取中"}</small>`;
  return `<section class="community-capabilities" aria-labelledby="community-capabilities-title"><header><div><span class="panel-kicker">CAPABILITY LEDGER / BETA.11</span><h2 id="community-capabilities-title">主流工具接入，模型自动识别</h2><p>工具是产品支持目录；模型来自当前公开账本中仍实际留存的历史快照，不是固定白名单。</p></div><dl><div><dt>主要工具标签</dt><dd>${SUPPORTED_TOOL_CATALOG.length}</dd></div><div><dt>历史出现标签</dt><dd>${toolsCount}</dd></div><div><dt>历史识别模型</dt><dd>${modelsCount}</dd></div><div><dt>本期模型</dt><dd>${leaderboard.availableModels.length}</dd></div></dl></header><div class="community-capability-section"><div class="community-capability-section-head"><div><strong>主要支持工具标签</strong><small>Cursor 需手动导入；Copilot 部分场景需开启 OTel</small></div>${toolsCompleteness}</div><div class="community-capability-tools">${toolCards}</div></div><div class="community-capability-section"><div class="community-capability-section-head"><div><strong>当前公开账本历史识别模型</strong>${modelsCompleteness}</div>${data?.models.length ? '<label class="community-capability-search"><span>搜索模型</span><input type="search" inputmode="search" autocomplete="off" placeholder="输入模型名" data-community-model-search /></label>' : ""}</div>${modelStatus}</div></section>`;
}

function totalsCells(person) {
  return `<dl class="community-token-grid"><div><dt>输入</dt><dd title="${escapeHTML(formatTokens(person.inputTokens, false))}">${escapeHTML(formatTokens(person.inputTokens))}</dd></div><div><dt>输出</dt><dd title="${escapeHTML(formatTokens(person.outputTokens, false))}">${escapeHTML(formatTokens(person.outputTokens))}</dd></div><div><dt>缓存读</dt><dd title="${escapeHTML(formatTokens(person.cacheReadTokens, false))}">${escapeHTML(formatTokens(person.cacheReadTokens))}</dd></div><div><dt>缓存写</dt><dd title="${escapeHTML(formatTokens(person.cacheWriteTokens, false))}">${escapeHTML(formatTokens(person.cacheWriteTokens))}</dd></div></dl>`;
}

function privacyNotice() {
  return `<aside class="community-privacy" aria-label="公开范围说明"><strong>公开边界</strong><p>这里只展示管理员已开启榜单的昵称、排名、四类 Token、公开标准价估算、工具/模型与日趋势。不展示邮箱、内部 ID、设备、小时、会话或消息；Token 不代表绩效。</p></aside>`;
}

function timezoneNotice(value) {
  if (value?.mixedTimezones !== true) return "";
  return `<aside class="community-timezone-notice" role="note"><strong>日趋势口径提示</strong><p>数据来自多个设备本地时区，按各设备的本地日期桶合计，未跨时区重新归日。</p></aside>`;
}

function ownRankingShareButton({ viewerPublicId, enabled }) {
  if (!COMMUNITY_PUBLIC_ID.test(String(viewerPublicId || ""))) return "";
  return `<button class="secondary-button small" type="button" data-community-action="share-own-rank" aria-label="分享我的排名" data-viewer-public-id="${escapeHTML(viewerPublicId)}" ${enabled ? "" : 'disabled title="部署 HTTPS 公开地址后可生成二维码海报"'}>分享我的排名</button>`;
}

function primaryModelSummary(person) {
  const toolCount = person.toolCount > 1 ? ` · 共 ${person.toolCount} 个工具` : "";
  const modelCount = person.modelCount > 1 ? ` · 共 ${person.modelCount} 个模型` : "";
  const hasTool = person.primaryTool && person.primaryToolTokens !== null;
  const hasModel = person.primaryModel && person.primaryModelTokens !== null;
  const toolName = hasTool ? escapeHTML(person.primaryTool) : "暂无可靠工具字段";
  const toolValue = hasTool
    ? `工具 Token ${escapeHTML(formatTokens(person.primaryToolTokens))}${escapeHTML(toolCount)}`
    : "不推测、不补造";
  const modelValue = hasModel
    ? `${escapeHTML(person.primaryModel)} · ${escapeHTML(formatTokens(person.primaryModelTokens))}${escapeHTML(modelCount)}`
    : "暂无可靠模型字段";
  return `<div class="community-model-summary"><span>主力工具</span><strong title="${toolName}">${toolName}</strong><small ${hasTool ? `title="${escapeHTML(formatTokens(person.primaryToolTokens, false))}"` : ""}>${toolValue}</small><span class="community-secondary-label">主力模型</span><em ${hasModel ? `title="${escapeHTML(formatTokens(person.primaryModelTokens, false))}"` : ""}>${modelValue}</em></div>`;
}

function leaderboardRows(data) {
  const medals = ["", "金", "银", "铜"];
  return data.participants.map((person) => `<article class="community-rank-row"><span class="community-rank ${person.rank && person.rank <= 3 ? "is-top" : ""}">${person.rank && person.rank <= 3 ? `<i aria-hidden="true">${medals[person.rank]}</i>` : ""}<b>${person.rank ? String(person.rank).padStart(2, "0") : "—"}</b></span><a class="community-person" href="${localHref({ kind: "profile", publicId: person.publicId, filters: data })}"><span><strong title="${escapeHTML(person.displayName)}">${escapeHTML(person.displayName)}</strong><small>查看全部工具、模型与趋势</small></span></a>${primaryModelSummary(person)}${totalsCells(person)}<div class="community-primary"><span>${escapeHTML(metricLabel(data.metric))}</span><strong title="${escapeHTML(metricDisplay(person, data.metric, false))}">${escapeHTML(metricDisplay(person, data.metric))}</strong><small>${escapeHTML(formatPublicCost(person.cost))}</small></div></article>`).join("");
}

function leaderboardEmptyState(data, filters, capabilityState) {
  const supported = SUPPORTED_TOOL_CATALOG.find(({ label }) => label === filters.tool);
  if (supported) {
    return `<div class="community-empty"><span>0</span><h2>${escapeHTML(supported.displayName)} 本期暂无公开数据</h2><p>TokenFleet 已支持这个工具，但当前日期范围还没有社群成员产生可统计数据。${supported.note ? ` ${escapeHTML(supported.note)}。` : ""}</p><div><a class="secondary-button small" href="${filterHref({ ...filters, period: "all" }, { kind: "leaderboard" }, "period", "all")}">查看全部时间</a><a class="secondary-button small" href="${filterHref(filters, { kind: "leaderboard" }, "tool", "")}">返回不限工具</a></div></div>`;
  }
  if (filters.model && capabilityState.data?.models.includes(filters.model)) {
    return `<div class="community-empty"><span>0</span><h2>这个模型本期暂无公开数据</h2><p>它存在于当前公开历史识别目录，但所选日期范围还没有可统计数据。</p><div><a class="secondary-button small" href="${filterHref({ ...filters, period: "all" }, { kind: "leaderboard" }, "period", "all")}">查看全部时间</a><a class="secondary-button small" href="${filterHref(filters, { kind: "leaderboard" }, "model", "")}">返回不限模型</a></div></div>`;
  }
  return `<div class="community-empty"><span>∅</span><h2>这个筛选下还没有参与者</h2><p>换一个日期、工具或模型再看看。</p></div>`;
}

function renderLeaderboard({ data, filters, canonicalUrl, capabilityState, viewerPublicId = "" }) {
  const ownShare = ownRankingShareButton({ viewerPublicId, enabled: Boolean(canonicalUrl) });
  const shareSummary = ownShare
    ? `<div class="community-summary-share"><span>我的排名</span>${ownShare}</div>`
    : "";
  return `<main id="main-content" class="community-shell">${publicHeader({ title: "让自己 AI Native 化，Learn in Public.", description: "只记录 AI 用量，不查看任何对话内容。和一群人一起，看见进步的速度。" })}${capabilityDirectory({ capabilityState, leaderboard: data, filters, route: { kind: "leaderboard" } })}${filterForm(filters, { kind: "leaderboard" }, { tools: data.availableTools, models: data.availableModels })}<section class="community-summary"><div><span>参与人数</span><strong>${data.totalEntries}</strong></div><div><span>日期</span><strong>${escapeHTML(periodLabel(data.period))}</strong></div><div><span>当前口径</span><strong>${escapeHTML(metricLabel(data.metric))}</strong></div>${shareSummary}</section><p class="community-share-hint" role="note">公开榜可自由浏览；个人排名海报仅会在已接入成员从 TokenFleet App 打开时出现。</p>${timezoneNotice(data)}<section class="community-board" aria-labelledby="leaderboard-title"><div class="community-board-head"><div><span class="panel-kicker">TOKEN USAGE / COMMUNITY</span><h2 id="leaderboard-title">Token 消耗排行榜</h2></div>${data.generatedAt ? `<small>更新于 ${escapeHTML(data.generatedAt)}</small>` : ""}</div>${data.participants.length ? leaderboardRows(data) : leaderboardEmptyState(data, filters, capabilityState)}</section>${privacyNotice()}<footer class="community-footer">TokenFleet · 看见 AI 使用进步</footer><div class="community-toast" aria-live="polite"></div></main>`;
}

function breakdownValue(item, metric) {
  if (metric === "cost") return item.cost?.unpriced ? null : item.cost?.amounts?.[0]?.microunits ?? null;
  if (item.metricValue !== null) return item.metricValue;
  return metric === "norm" ? item.normTokens : item.totalTokens;
}

function costComparisonState(items, parentCost = {}) {
  const costs = items.map((item) => item.cost);
  const hasUnpriced = parentCost?.unpriced === true || costs.some((cost) =>
    !cost || cost.unpriced || cost.amounts?.length !== 1
  );
  const currencies = new Set(costs.flatMap((cost) =>
    cost?.unpriced || cost?.amounts?.length !== 1 ? [] : [cost.amounts[0].currency]
  ));
  const mixedCurrency = parentCost?.mixedCurrency === true || currencies.size > 1;
  return { comparable: !hasUnpriced && !mixedCurrency, hasUnpriced, mixedCurrency };
}

export function breakdownList(items, metric, parentCost = {}, total = items.length) {
  if (!items.length) return `<div class="community-empty compact"><span>∅</span><p>暂无公开分项</p></div>`;
  const comparison = metric === "cost"
    ? costComparisonState(items, parentCost)
    : { comparable: true, hasUnpriced: false, mixedCurrency: false };
  const maximum = items.reduce((current, item) => {
    const value = toTokenBigInt(breakdownValue(item, metric));
    return value > current ? value : current;
  }, 1n);
  const notice = comparison.comparable ? "" : `<p class="community-cost-comparison-note" role="note">${comparison.mixedCurrency ? "含多种币种，未做汇率换算；金额不可直接比较，未绘制比例条。" : "存在未定价分项；金额不可完整比较，未绘制比例条。"}</p>`;
  const completeness = total > items.length
    ? `<p class="community-distribution-note" role="note">当前展示前 ${items.length} 项／共 ${total} 项</p>`
    : `<p class="community-distribution-note">共 ${items.length} 项</p>`;
  return `${notice}${completeness}<div class="community-distribution">${items.map((item, index) => {
    const rawValue = breakdownValue(item, metric);
    const width = rawValue === null ? 0 : Math.max(1, tokenRatio(rawValue, maximum) * 100);
    const value = metric === "cost" ? formatPublicCost(item.cost) : formatTokens(rawValue);
    const bar = comparison.comparable
      ? `<i aria-hidden="true"><b style="width:${width.toFixed(2)}%"></b></i>`
      : rawValue === null
        ? '<i class="is-unpriced" aria-label="未定价"><span>未定价</span></i>'
        : '<i class="is-not-comparable" aria-label="金额不可比"><span>不可比</span></i>';
    return `<div><span>${String(index + 1).padStart(2, "0")}</span><strong title="${escapeHTML(item.name)}">${escapeHTML(item.name)}</strong>${item.tool ? `<small>${escapeHTML(item.tool)}</small>` : ""}${bar}<em>${escapeHTML(value)}</em></div>`;
  }).join("")}</div>`;
}

function trendValue(item, metric) {
  if (item.metricValue !== null) return item.metricValue;
  if (metric === "cost") return item.cost?.unpriced ? null : item.cost?.amounts?.[0]?.microunits ?? null;
  return metric === "norm" ? item.normTokens : item.totalTokens;
}

export function publicTrend(items, metric, parentCost = {}) {
  const pointsWithValues = items.map((item) => ({ item, value: trendValue(item, metric) }));
  if (metric === "cost") {
    const comparison = costComparisonState(items, parentCost);
    if (!comparison.comparable) {
      const message = comparison.mixedCurrency
        ? "日费用包含多种币种，未做汇率换算，不绘制单一数值折线。"
        : "存在未定价日期，不把未定价伪装成 0，因此不绘制费用折线。";
      return `<div class="community-trend community-trend-unavailable" role="note"><strong>费用趋势暂不可比</strong><p>${message}</p></div>`;
    }
  }
  const priced = pointsWithValues.filter(({ value }) => value !== null);
  if (!priced.length) return `<div class="community-empty compact"><span>∅</span><p>${metric === "cost" ? "日费用尚未按公开标准价定价" : "暂无日趋势"}</p></div>`;
  const width = 820;
  const height = 230;
  const inset = 18;
  const maximum = priced.reduce((current, { value }) => {
    const parsed = toTokenBigInt(value);
    return parsed > current ? parsed : current;
  }, 1n);
  const points = pointsWithValues.map(({ item, value }, index) => {
    const x = inset + (index / Math.max(pointsWithValues.length - 1, 1)) * (width - inset * 2);
    const y = height - inset - tokenRatio(value, maximum) * (height - inset * 2);
    return { x, y, item, value };
  });
  const line = points.map(({ x, y }) => `${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const observations = points.map(({ x, y, item, value }) => {
    const displayValue = value === null ? "未定价" : metric === "cost" ? formatPublicCost(item.cost) : formatTokens(value, false);
    const tooltipX = Math.max(4, Math.min(width - 150, x - 75));
    const tooltipY = y < 54 ? y + 16 : y - 50;
    return `<g class="chart-observation" tabindex="0" role="img" aria-label="${escapeHTML(item.date)}，${escapeHTML(displayValue)}"><circle cx="${x}" cy="${y}" r="17" class="chart-hit"/><circle cx="${x}" cy="${y}" r="4" class="chart-point"/><g class="chart-tooltip" aria-hidden="true"><rect x="${tooltipX}" y="${tooltipY}" width="150" height="38" rx="6"/><text x="${tooltipX + 10}" y="${tooltipY + 15}">${escapeHTML(item.date)}</text><text x="${tooltipX + 10}" y="${tooltipY + 30}" class="chart-tooltip-value">${escapeHTML(displayValue)}</text></g></g>`;
  }).join("");
  return `<div class="community-trend"><svg viewBox="0 0 ${width} ${height}" role="img" aria-label="${items.length} 天${escapeHTML(metricLabel(metric))}趋势"><line x1="${inset}" y1="${height * .5}" x2="${width - inset}" y2="${height * .5}"/><polyline points="${line}"/>${observations}</svg><div><span>${escapeHTML(items[0]?.date || "")}</span><strong>峰值 ${escapeHTML(metric === "cost" ? "按公开标准价" : formatTokens(maximum))}</strong><span>${escapeHTML(items.at(-1)?.date || "")}</span></div></div>`;
}

function renderProfile({ person, leaderboard, filters, canonicalUrl, capabilityState, viewerPublicId = "" }) {
  const ownShare = viewerPublicId === person.publicId
    ? ownRankingShareButton({ viewerPublicId, enabled: Boolean(canonicalUrl) })
    : "";
  return `<main id="main-content" class="community-shell"><header class="community-header"><a class="community-brand" href="#/rank"><span>TF</span><strong>TokenFleet</strong><small>COMMUNITY LEDGER</small></a><nav aria-label="公开页面导航"><a href="${localHref({ filters })}">返回社群榜</a><a class="community-install-link" href="/install">安装与参与</a></nav></header><a class="community-back" href="${localHref({ filters })}">← 返回社群榜</a><section class="community-profile-hero"><span class="community-profile-rank">${person.rank ? `#${person.rank}` : "未上榜"}</span><div><span class="panel-kicker">PUBLIC MEMBER</span><h1 title="${escapeHTML(person.displayName)}">${escapeHTML(person.displayName)}</h1><p>${escapeHTML(periodLabel(filters.period))} · ${escapeHTML(metricLabel(filters.metric))}</p></div><div><strong>${escapeHTML(metricDisplay(person, filters.metric))}</strong><span>${escapeHTML(metricLabel(filters.metric))}</span></div>${ownShare}</section>${capabilityDirectory({ capabilityState, leaderboard, filters, route: { kind: "profile", publicId: person.publicId } })}${filterForm(filters, { kind: "profile", publicId: person.publicId }, { tools: leaderboard.availableTools, models: leaderboard.availableModels })}${timezoneNotice(person)}<section class="community-total-panel"><div class="community-total-title"><span class="panel-kicker">TOKEN COMPOSITION</span><h2>四类 Token 构成</h2></div>${totalsCells(person)}<dl class="community-extra-totals"><div><dt>不含缓存</dt><dd title="${escapeHTML(formatTokens(person.normTokens, false))}">${escapeHTML(formatTokens(person.normTokens))}</dd></div><div><dt>含缓存合计</dt><dd title="${escapeHTML(formatTokens(person.totalTokens, false))}">${escapeHTML(formatTokens(person.totalTokens))}</dd></div><div><dt>API 等价估算</dt><dd>${escapeHTML(formatPublicCost(person.cost))}</dd></div></dl></section><section class="community-detail-grid"><article><div class="community-board-head"><div><span class="panel-kicker">BY TOOL</span><h2>工具分布</h2></div></div>${breakdownList(person.tools, filters.metric, person.cost, person.toolDistributionTotal)}</article><article><div class="community-board-head"><div><span class="panel-kicker">BY MODEL</span><h2>模型分布</h2></div></div>${breakdownList(person.models, filters.metric, person.cost, person.modelDistributionTotal)}</article><article class="wide"><div class="community-board-head"><div><span class="panel-kicker">DAILY TREND</span><h2>日趋势</h2></div></div>${publicTrend(person.dailyTrend, filters.metric, person.cost)}</article></section>${person.rank && person.rank > 100 ? '<p class="community-rank-note">该参赛者当前在榜单接口 Top 100 之外；分享图会单独附上其公开位置。</p>' : ""}${privacyNotice()}<footer class="community-footer">TokenFleet · 只记数量，不看内容</footer><div class="community-toast" aria-live="polite"></div></main>`;
}

function renderInstall() {
  return `<main id="main-content" class="community-shell install-shell"><header class="community-header"><a class="community-brand" href="#/rank" aria-label="TokenFleet 社群榜首页"><span>TF</span><strong>TokenFleet</strong><small>COMMUNITY LEDGER</small></a><nav aria-label="公开页面导航"><a href="/rank">社群榜</a><a class="community-install-link" href="/install" aria-current="page">安装与参与</a><a href="#install-privacy">隐私说明</a></nav></header><section class="install-hero"><span class="panel-kicker">INSTALL / INVITE-ONLY BETA</span><h1>安装只是第一步，<br>领取邀请码才算加入。</h1><p>TokenFleet 当前 beta 仍采用邀请制。如果管理员已经把批次登记链接发给你，安装后在要统计的那台电脑上打开链接、登记昵称领取设备码即可；还没有链接，再扫码联系管理员领取。</p><div class="install-hero-actions"><a class="primary-button" href="#install-contact">没有链接？扫码联系管理员</a><a class="secondary-button" href="/rank">先看看社群榜</a></div><aside><strong>请记住</strong><span>只下载安装不会自动加入，也不会自动获得排行榜权限。<code>https://token.ipwriter.com</code> 只用于客户端安装参数，不是成员网页入口，请勿把裸域名当作登录页；浏览器请使用 <code>/install</code>、<code>/rank</code> 或收到的完整批次邀请链接。</span></aside></section><section class="install-steps" aria-labelledby="install-steps-title"><div class="install-section-head"><span class="panel-kicker">HOW TO JOIN</span><h2 id="install-steps-title">按这三步完成加入</h2></div><ol><li><span>01</span><div><strong>安装经过复核的固定版本</strong><p>根据管理员发送的正式 tag / commit 和安装说明操作；Mac 支持 Apple Silicon 与 Intel，Windows 使用对应说明。不使用来历不明的旧安装包。</p></div></li><li><span>02</span><div><strong>打开“社群同步”</strong><p>安装后打开 TokenFleet，在设置中找到“社群同步”。此时还没有邀请码属于正常情况，先不要重复注册昵称。</p></div></li><li><span>03</span><div><strong>打开批次链接，登记昵称领设备码</strong><p>在要统计的那台电脑上打开管理员发的批次登记链接（不要用手机），登记唯一昵称后会得到当前设备专用、短期、单次使用的设备码。还没有链接就扫码添加微信（备注“TokenFleet”）向管理员领取。</p></div></li></ol></section><section class="install-contact" id="install-contact" aria-labelledby="install-contact-title"><div class="install-qr-frame"><img src="./tokenfleet-contact-wechat-qr.jpg" alt="扫码添加微信领取邀请码二维码"></div><div class="install-contact-copy"><span class="panel-kicker">NO LINK YET / CONTACT</span><h2 id="install-contact-title">还没有批次链接？扫码联系管理员</h2><p>已经拿到管理员发的批次登记链接就不需要扫码，直接在要统计的那台电脑上打开链接即可。没有链接时添加好友并备注“TokenFleet”，收到批次登记链接后使用唯一昵称登记并立即保存设备码，再回到 TokenFleet 客户端完成连接。</p><div class="install-contact-warning"><strong>没有批次链接和设备码，安装后仍无法加入社群。</strong><span>二维码只用于联系，不包含设备码，也不会直接授予社群权限。</span></div><ul><li>添加好友时备注：TokenFleet</li><li>领取批次登记链接与专属设备码</li><li>只把设备码粘贴进正式 TokenFleet 客户端</li></ul></div></section><aside class="install-privacy" id="install-privacy"><div><span class="panel-kicker">PRIVACY BOUNDARY</span><h2>公开的是聚合用量，不是工作内容</h2></div><p>不上传提示词、回复、代码、文件、项目路径、邮箱、设备名称、序列号或硬件配置。除日期×工具×模型的 Token 聚合外，社群同步还会发送随机设备 ID、平台、App／采集器版本、时区和统计完整性等最小元数据。公开参与由管理员控制；邀请码只用于绑定当前设备，原始码不会在后台再次展示。</p></aside><footer class="community-footer">TokenFleet · 让自己 AI Native 化，Learn in Public.</footer></main>`;
}

function renderJoin({ hasCode, demoMode = false }) {
  const leaderboardHref = demoMode ? "/rank?demo=1" : "/rank";
  return `<main id="main-content" class="join-shell"><section class="join-card"><a class="community-brand dark" href="${leaderboardHref}"><span>TF</span><strong>TokenFleet</strong><small>SECURE JOIN</small></a><div class="join-status ${hasCode ? "is-ready" : "is-error"}" role="status"><span aria-hidden="true">${hasCode ? "✓" : "!"}</span><div><strong>${hasCode ? "一次性连接码已安全载入" : "链接里没有有效连接码"}</strong><p>${hasCode ? "原始连接码已从浏览器地址栏移除，页面不会显示或保存它。" : "请联系社群管理员重新生成专属接入链接；不要把连接码放在 query 参数里。"}</p></div></div><header><span class="panel-kicker">DEVICE SETUP / 3 STEPS</span><h1>把这台设备接入 TokenFleet</h1><p>客户端固定连接唯一的 TokenFleet 官方服务地址。你只需要把一次性连接码粘贴进客户端，不要填写或修改服务器地址。</p></header><ol class="join-steps"><li><span>01</span><div><strong>安装并打开 TokenFleet</strong><p>按社群管理员提供的固定源码版本说明，在 Mac 或 Windows 上安装 TokenFleet。</p></div></li><li><span>02</span><div><strong>复制一次性连接码</strong><p>连接码通常只能使用一次并有有效期；只在 TokenFleet 客户端内粘贴。</p><button class="primary-button" type="button" data-community-action="copy-join-code" ${hasCode ? "" : "disabled"}>复制连接码</button></div></li><li><span>03</span><div><strong>在客户端确认连接</strong><p>连接后，客户端会立即上传当前可验证的历史日聚合，并持续在后台同步新的日聚合。</p></div></li></ol><aside class="join-disclosure"><h2>连接前请确认公开边界</h2><p>上传到社群用量账本的是日期、时区、工具、模型和四类 Token 聚合。若管理员已为你开启社群榜，公开页会展示昵称、排名、四类 Token、公开标准价估算、工具/模型和日趋势。</p><p>不上传 prompt、回复、代码、文件或项目路径；公开页也不展示邮箱、内部 ID、设备、小时、会话或消息。</p></aside><p class="join-expiry">此页面不会自动连接、自动复制或打开自定义协议。离开页面后，内存中的连接码会立即清除。</p><a class="text-button" href="${leaderboardHref}">先看看匿名社群榜</a><div class="community-toast" aria-live="polite"></div></section></main>`;
}

function renderBatchClaim({ hasToken, demoMode = false, error = "" }) {
  const leaderboardHref = demoMode ? "/rank?demo=1" : "/rank";
  return `<main id="main-content" class="join-shell"><section class="join-card batch-claim-card"><a class="community-brand dark" href="${leaderboardHref}"><span>TF</span><strong>TokenFleet</strong><small>COMMUNITY INVITE</small></a><div class="join-status ${hasToken ? "is-ready" : "is-error"}" role="status"><span aria-hidden="true">${hasToken ? "✓" : "!"}</span><div><strong>${hasToken ? "社群邀请已安全载入" : "这个批次链接当前不可用"}</strong><p>${hasToken ? "邀请令牌已从地址栏移除，只保留在当前页面内存；关闭或刷新页面即清空。" : "它可能已满额、关闭、过期或格式不正确。请联系社群管理员获取新的批次链接。"}</p></div></div><header><span class="panel-kicker">SELF-SERVICE / 50 PER BATCH</span><h1>登记昵称，领取你的设备码</h1><p>无需账号、密码或微信登录。每个人只填写公开昵称，系统会生成只属于你的 60 分钟一次性设备码。</p><p><strong>请在要统计用量的那台电脑上打开本页再领取</strong>——设备码只能复制进当前设备的剪贴板，用手机领取将无法转移到电脑。</p></header>${error ? `<div class="inline-alert" role="alert">${escapeHTML(error)}</div>` : ""}<form class="batch-claim-form" data-community-action="claim-batch"><label>公开昵称<input name="display_name" minlength="1" maxlength="128" autocomplete="nickname" required placeholder="例如：小王"></label><label class="consent-check"><input name="public_profile_enabled" type="checkbox" value="true" required><span><strong>我同意参与公开社群榜</strong><small>公开昵称、排名、四类 Token、API 等价估算费用、工具、模型和日趋势；不公开邮箱、设备、小时、会话、prompt、回复、代码或路径。</small></span></label><button class="primary-button" type="submit" ${hasToken ? "" : "disabled"}>确认昵称并领取设备码</button></form><aside class="join-disclosure"><h2>领取后怎么做</h2><p>复制个人设备码后：Mac 打开 TokenFleet，在设置的“社群同步”中粘贴并确认；Windows 在终端运行 tokenfleet connect，按提示粘贴（输入时不显示是正常的）。连接后会立即上传当前可验证的历史日聚合，并持续在后台同步。</p><p>单批最多 50，可创建多个批次进入同一社群；批次最长 90 天，个人设备码默认 60 分钟且只能使用一次。</p></aside><p class="join-expiry">批次令牌和个人设备码都不会写入浏览器存储、DOM、日志或 URL；离开页面后立即清空。</p><a class="text-button" href="${leaderboardHref}">先看看匿名社群榜</a><div class="community-toast" aria-live="polite"></div></section></main>`;
}

function renderBatchSuccess({ nickname, demoMode = false }) {
  const leaderboardHref = demoMode ? "/rank?demo=1" : "/rank";
  return `<main id="main-content" class="join-shell"><section class="join-card batch-success-card"><a class="community-brand dark" href="${leaderboardHref}"><span>TF</span><strong>TokenFleet</strong><small>DEVICE CODE READY</small></a><div class="join-status is-ready" role="status"><span aria-hidden="true">✓</span><div><strong>${escapeHTML(nickname)}，你的设备码已经生成</strong><p>设备码不会显示在页面，只能通过下方按钮复制；关闭页面后无法找回。</p></div></div><header><span class="panel-kicker">COPY ONCE / USE WITHIN 60 MINUTES</span><h1>现在复制到 TokenFleet</h1><p>不要发送给其他人，也不要粘贴到聊天机器人、终端参数、网页地址或非官方客户端。</p></header><button class="primary-button" type="button" data-community-action="copy-batch-enrollment-code">复制个人设备码</button><ol class="join-steps"><li><span>01</span><div><strong>Mac：打开 TokenFleet 的“社群同步”</strong><p>在设置里找到“社群同步”，粘贴设备码并确认；客户端固定连接本社群服务，不需要填写服务器地址。</p></div></li><li><span>02</span><div><strong>Windows：终端运行 tokenfleet connect</strong><p>按提示粘贴设备码（输入时不显示是正常的），之后每六小时自动同步。</p></div></li><li><span>03</span><div><strong>确认上榜</strong><p>同步完成后打开社群榜，按你的公开昵称查看聚合用量。</p></div></li></ol><p class="join-expiry">若设备码过期或页面已关闭，请联系管理员重新生成；不要重复创建昵称。</p><a class="text-button" href="${leaderboardHref}">打开匿名社群榜</a><div class="community-toast" aria-live="polite"></div></section></main>`;
}

function renderLoading(root) {
  root.innerHTML = `<main id="main-content" class="community-shell"><div class="community-loading" role="status"><span>TF</span><p>正在读取匿名社群榜…</p></div></main>`;
}

function renderError(root, error) {
  const missing = error?.status === 404;
  root.innerHTML = `<main id="main-content" class="community-shell">${publicHeader({ title: missing ? "这份公开资料不存在" : "社群榜暂时读不到", description: missing ? "对方可能已关闭参与，或成员已被禁用。私有历史不会因此删除。" : "公开接口没有返回可用数据，请稍后再试。" })}<section class="community-empty error"><span>${missing ? "404" : "!"}</span><p>${escapeHTML(error?.message || "未知错误")}</p><button class="secondary-button" type="button" data-community-action="retry">重试</button></section><div class="community-toast" aria-live="polite"></div></main>`;
}

function showToast(root, message, error = false, isActive = () => true) {
  if (!isActive()) return;
  const region = root.querySelector(".community-toast");
  if (!region) return;
  const item = document.createElement("div");
  item.className = error ? "is-error" : "";
  item.textContent = message;
  region.replaceChildren(item);
  setTimeout(() => { if (isActive()) item.remove(); }, 4200);
}

function applyCommunityDemoBanner(root, demoMode, documentRef = document) {
  if (!demoMode) return;
  const banner = documentRef.createElement("aside");
  banner.className = "community-demo-banner";
  banner.setAttribute("role", "status");
  banner.textContent = "演示数据 · 不是真实排名或真实成员数据";
  (root.querySelector(".join-card") || root.querySelector("#main-content"))?.prepend(banner);
}

export function mountCommunityApp({
  root,
  route,
  demoMode = false,
  joinCode = "",
  batchInvitationToken = "",
  documentRef = document,
  locationRef = location,
  historyRef = documentRef.defaultView?.history || globalThis.history,
  isCurrent = () => true,
} = {}) {
  const controller = new AbortController();
  let disposed = false;
  let secret = String(joinCode || "");
  let batchSecret = String(batchInvitationToken || "");
  let issuedEnrollmentCode = "";
  let leaderboard = null;
  let focus = null;
  let posterObjectUrl = "";
  let posterBlob = null;
  let posterPreviewReady = false;
  let bridgeNotice = "";
  let initialShareGrantHandled = false;
  const filters = sanitizePublicFilters(route.filters || {});
  // Must happen before any rendering or public API request.  The raw bridge
  // never enters a component state, a link, a log, or a referrer.
  const initialShareGrant = takeCommunityShareGrant(locationRef, historyRef);
  const canonicalUrl = publicShareUrl({ route, filters, documentRef, locationRef, demoMode });
  const demoOptions = {
    empty: new URLSearchParams(locationRef.search).get("scenario") === "empty",
    locationRef,
  };
  const api = demoMode
    ? createCommunityDemoApi(demoOptions)
    : createCommunityApiClient({ signal: controller.signal });
  const capabilityKey = demoMode ? "demo" : "live";
  const capabilityRequest = (signal) => demoMode
    ? createCommunityDemoApi(demoOptions).capabilities()
    : createCommunityApiClient({ signal }).capabilities();
  const startCapabilities = (force = false) => loadCommunityCapabilities({
    key: capabilityKey,
    request: capabilityRequest,
    force,
  });

  const clearSecret = () => {
    secret = "";
    batchSecret = "";
    issuedEnrollmentCode = "";
  };
  const active = () => !disposed && isCurrent();
  const posterUrlApi = documentRef.defaultView?.URL || URL;
  const closePoster = () => {
    root.querySelector(".community-poster-modal")?.remove();
    if (posterObjectUrl) posterUrlApi.revokeObjectURL(posterObjectUrl);
    posterObjectUrl = "";
    posterBlob = null;
    posterPreviewReady = false;
  };
  const showPosterPreview = ({ blob, canvas }) => {
    closePoster();
    posterBlob = blob;
    posterObjectUrl = posterUrlApi.createObjectURL(blob);
    const overlay = documentRef.createElement("div");
    overlay.className = "community-poster-modal";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-labelledby", "community-poster-title");
    const previewTitle = "Token 消耗排名";
    overlay.innerHTML = `<section><header><div><span>分享预览</span><h2 id="community-poster-title">${previewTitle}</h2></div><button type="button" data-community-action="close-poster" aria-label="关闭分享预览">×</button></header><div class="community-poster-preview-frame" aria-label="${previewTitle}图片预览"></div><footer><button class="primary-button" type="button" data-community-action="copy-poster">复制图片</button><button class="secondary-button" type="button" data-community-action="save-poster">保存图片</button><button class="secondary-button" type="button" data-community-action="close-poster">关闭</button><p>可直接粘贴到聊天工具；手机端也可长按图片保存或转发</p></footer></section>`;
    const previewFrame = overlay.querySelector(".community-poster-preview-frame");
    canvas.setAttribute("role", "img");
    canvas.setAttribute("aria-label", `${previewTitle}图片预览`);
    previewFrame?.append(canvas);
    posterPreviewReady = true;
    root.append(overlay);
    overlay.querySelector('[data-community-action="close-poster"]')?.focus({ preventScroll: true });
  };
  globalThis.addEventListener?.("pagehide", clearSecret, { signal: controller.signal });
  if (active()) {
    documentRef.body.classList.add("community-mode");
    documentRef.title = route.kind === "install"
      ? "安装与参与 · TokenFleet"
      : ["join", "batch"].includes(route.kind)
        ? "安全接入 · TokenFleet"
        : "社群榜 · TokenFleet";
  }

  const redeemInitialShareGrant = async () => {
    if (!initialShareGrant || initialShareGrantHandled) return;
    initialShareGrantHandled = true;
    // A new fragment must not inherit a previous page's membership proof if
    // redemption fails or is replayed.
    clearCommunityShareViewer();
    try {
      const result = await api.redeemCommunityShareGrant(initialShareGrant);
      const publicId = String(result?.public_id || "");
      if (!COMMUNITY_PUBLIC_ID.test(publicId)) throw new Error("invalid-share-viewer");
      communityShareViewerPublicId = publicId;
    } catch {
      // Do not surface a server response that could contain sensitive
      // diagnostics.  The ordinary public board remains safe to browse.
      bridgeNotice = "本次分享凭证已失效或暂不可用；你仍可查看公开榜，请返回 App 后重新打开。";
    }
  };

  const renderCurrentCommunity = () => {
    if (!leaderboard) return;
    const capabilityState = capabilityStateView(capabilityKey);
    root.innerHTML = route.kind === "profile" && focus
      ? renderProfile({
        person: focus,
        leaderboard,
        filters,
        canonicalUrl,
        capabilityState,
        viewerPublicId: communityShareViewerPublicId,
      })
      : renderLeaderboard({
        data: leaderboard,
        filters,
        canonicalUrl,
        capabilityState,
        viewerPublicId: communityShareViewerPublicId,
      });
    applyCommunityDemoBanner(root, demoMode, documentRef);
  };

  const settleCapabilities = (promise) => {
    promise.then(
      () => { if (active()) renderCurrentCommunity(); },
      () => { if (active()) renderCurrentCommunity(); },
    );
  };

  const load = async () => {
    if (!active()) return;
    if (route.kind === "join") {
      if (!active()) return;
      root.innerHTML = renderJoin({ hasCode: Boolean(secret), demoMode });
      if (!active()) return;
      applyCommunityDemoBanner(root, demoMode, documentRef);
      root.querySelector("#main-content")?.setAttribute("tabindex", "-1");
      root.querySelector("#main-content")?.focus({ preventScroll: true });
      return;
    }
    if (route.kind === "batch") {
      if (!active()) return;
      root.innerHTML = renderBatchClaim({ hasToken: Boolean(batchSecret), demoMode });
      if (!active()) return;
      applyCommunityDemoBanner(root, demoMode, documentRef);
      root.querySelector("#main-content")?.setAttribute("tabindex", "-1");
      root.querySelector("#main-content")?.focus({ preventScroll: true });
      return;
    }
    if (route.kind === "install") {
      if (!active()) return;
      root.innerHTML = renderInstall();
      if (!active()) return;
      applyCommunityDemoBanner(root, demoMode, documentRef);
      root.querySelector("#main-content")?.setAttribute("tabindex", "-1");
      root.querySelector("#main-content")?.focus({ preventScroll: true });
      return;
    }
    await redeemInitialShareGrant();
    if (!active()) return;
    const capabilityPromise = startCapabilities();
    settleCapabilities(capabilityPromise);
    renderLoading(root);
    try {
      if (route.kind === "profile") {
        const [rawLeaderboard, rawMember] = await Promise.all([
          api.leaderboard(filters),
          api.member(route.publicId, filters),
        ]);
        if (!active()) return;
        const nextLeaderboard = normalizePublicLeaderboard(rawLeaderboard, filters);
        const nextFocus = normalizePublicMemberDetail(rawMember);
        if (!nextFocus) {
          const error = new Error("这个公开资料不存在或已关闭");
          error.status = 404;
          throw error;
        }
        if (!active()) return;
        leaderboard = nextLeaderboard;
        focus = nextFocus;
        renderCurrentCommunity();
      } else {
        const rawLeaderboard = await api.leaderboard(filters);
        if (!active()) return;
        const nextLeaderboard = normalizePublicLeaderboard(rawLeaderboard, filters);
        if (!active()) return;
        leaderboard = nextLeaderboard;
        renderCurrentCommunity();
      }
      if (!active()) return;
      if (bridgeNotice) {
        showToast(root, bridgeNotice, true, active);
        bridgeNotice = "";
      }
      root.querySelector("#main-content")?.setAttribute("tabindex", "-1");
      root.querySelector("#main-content")?.focus({ preventScroll: true });
    } catch (error) {
      if (!active()) return;
      renderError(root, error);
    }
  };

  root.addEventListener("submit", async (event) => {
    if (!active()) return;
    const batchForm = event.target.closest('[data-community-action="claim-batch"]');
    if (!batchForm) return;
    event.preventDefault();
    if (!batchSecret || batchForm.dataset.pending === "true") return;
    const values = Object.fromEntries(new FormData(batchForm));
    const controls = [...batchForm.querySelectorAll("button,input")];
    batchForm.dataset.pending = "true";
    batchForm.setAttribute("aria-busy", "true");
    controls.forEach((control) => { control.disabled = true; });
    try {
      const result = await api.claimInvitationBatch({
        invitation_token: batchSecret,
        display_name: values.display_name,
        public_profile_enabled: values.public_profile_enabled === "true",
      });
      if (!active()) return;
      const returnedCode = String(result?.enrollment_token || "");
      if (!/^[A-Za-z0-9_-]{32,256}$/.test(returnedCode)) {
        throw new Error("服务端没有返回有效的个人设备码");
      }
      batchSecret = "";
      issuedEnrollmentCode = returnedCode;
      root.innerHTML = renderBatchSuccess({
        nickname: String(result?.nickname || values.display_name || "社群成员"),
        demoMode,
      });
      applyCommunityDemoBanner(root, demoMode, documentRef);
      root.querySelector("#main-content")?.setAttribute("tabindex", "-1");
      root.querySelector("#main-content")?.focus({ preventScroll: true });
    } catch (error) {
      if (!active()) return;
      const unavailable = error?.status === 409 && error?.message === "invitation batch unavailable";
      const nicknameConflict = error?.status === 409 && error?.message === "nickname unavailable";
      if (unavailable) batchSecret = "";
      root.innerHTML = renderBatchClaim({
        hasToken: Boolean(batchSecret),
        demoMode,
        error: unavailable
          ? "这个批次链接已失效、已关闭或名额已满，请联系管理员。"
          : nicknameConflict
            ? "这个昵称已被使用，请换一个昵称再试。"
            : error?.message || "领取失败，请稍后再试。",
      });
      applyCommunityDemoBanner(root, demoMode, documentRef);
    } finally {
      if (!active()) return;
      delete batchForm.dataset.pending;
      batchForm.removeAttribute("aria-busy");
      controls.forEach((control) => { control.disabled = false; });
    }
  }, { signal: controller.signal });

  root.addEventListener("click", async (event) => {
    if (!active()) return;
    const target = event.target.closest("[data-community-action]");
    if (!target) return;
    const action = target.dataset.communityAction;
    if (action === "close-poster") {
      closePoster();
      return;
    }
    if (action === "save-poster") {
      if (!posterObjectUrl || !posterPreviewReady) {
        showToast(root, "图片预览尚未完成，请稍候或重新生成", true, active);
        return;
      }
      try {
        const link = documentRef.createElement("a");
        link.href = posterObjectUrl;
        link.download = `TokenFleet-排行榜-${new Date().toISOString().slice(0, 10)}.png`;
        link.rel = "noopener";
        link.click();
        showToast(root, "已请求浏览器下载；若未出现文件，请允许下载后重试", false, active);
      } catch {
        showToast(root, "浏览器无法发起下载，请允许下载后重新生成图片", true, active);
      }
      return;
    }
    if (action === "copy-poster") {
      if (!posterBlob || !posterPreviewReady) {
        showToast(root, "图片尚未生成，请重新打开分享预览", true, active);
        return;
      }
      try {
        const ClipboardImage = documentRef.defaultView?.ClipboardItem || globalThis.ClipboardItem;
        if (!ClipboardImage || !navigator.clipboard?.write) throw new Error("clipboard-image-unsupported");
        await navigator.clipboard.write([new ClipboardImage({ "image/png": posterBlob })]);
        if (!active()) return;
        showToast(root, "排名图片已复制，可直接粘贴到聊天工具", false, active);
      } catch {
        if (!active()) return;
        showToast(root, "当前浏览器不能直接复制图片，请使用“保存图片”", true, active);
      }
      return;
    }
    if (action === "copy-join-code") {
      if (!secret) return;
      const currentSecret = secret;
      try {
        await navigator.clipboard.writeText(currentSecret);
        if (!active()) return;
        showToast(root, "连接码已复制；请只粘贴到正式 TokenFleet 客户端", false, active);
      } catch {
        if (!active()) return;
        showToast(root, "浏览器拒绝了复制，请重新打开专属链接后再试", true, active);
      }
    }
    if (action === "copy-batch-enrollment-code") {
      if (!issuedEnrollmentCode) {
        showToast(root, "个人设备码已失效，请重新领取或请管理员补发", true, active);
        return;
      }
      const currentCode = issuedEnrollmentCode;
      try {
        await navigator.clipboard.writeText(currentCode);
        if (!active()) return;
        showToast(root, "个人设备码已复制；请只粘贴到正式 TokenFleet 客户端", false, active);
      } catch {
        if (!active()) return;
        showToast(root, "浏览器拒绝了复制，请不要刷新，稍后再试", true, active);
      }
    }
    if (action === "retry") void load();
    if (action === "retry-capabilities") {
      const retry = startCapabilities(true);
      renderCurrentCommunity();
      settleCapabilities(retry);
      return;
    }
    if (action === "share-own-rank") {
      const publicId = String(target.dataset.viewerPublicId || "");
      if (!active() || !canonicalUrl || !leaderboard || !COMMUNITY_PUBLIC_ID.test(publicId) || publicId !== communityShareViewerPublicId || target.dataset.pending === "true") return;
      target.dataset.pending = "true";
      target.disabled = true;
      target.setAttribute("aria-busy", "true");
      try {
        // A share card is deliberately a stable, full public board for the
        // selected date.  Tool/model micro-filters can leave only one or two
        // rows and made the 1200×1600 composition look broken; the QR leads to
        // the same complete date board shown in the card.
        const posterFilters = sanitizePublicFilters({ period: filters.period, metric: "tokens" });
        let posterLeaderboard = leaderboard;
        if (posterLeaderboard.metric !== "tokens" || filters.tool || filters.model) {
          posterLeaderboard = normalizePublicLeaderboard(
            await api.leaderboard(posterFilters),
            posterFilters,
          );
          if (!active()) return;
        }
        // Never allow a DOM row or profile route to decide who is shared. The
        // server-redeemed viewer identity is the sole source of the target.
        const selected = normalizePublicMemberDetail(await api.member(publicId, posterFilters));
        if (!active()) return;
        if (!selected || selected.publicId !== publicId) throw new Error("你的公开资料暂时无法生成排名海报");
        const posterUrl = publicShareUrl({
          route: { kind: "profile", publicId },
          filters: posterFilters,
          documentRef,
          locationRef,
          demoMode,
        });
        if (!posterUrl) throw new Error("部署同源 HTTPS 公开地址后才能生成二维码海报");
        const model = buildCommunityPosterModel({
          leaderboard: posterLeaderboard,
          focus: selected,
          filters: posterFilters,
          publicUrl: posterUrl,
          demo: demoMode,
        });
        const poster = await createCommunityPosterArtifact(model, { documentRef });
        if (!active()) return;
        showPosterPreview(poster);
      } catch (error) {
        if (!active()) return;
        showToast(root, error?.message || "分享图片生成失败", true, active);
      } finally {
        if (!active()) return;
        delete target.dataset.pending;
        target.disabled = false;
        target.removeAttribute("aria-busy");
      }
    }
  }, { signal: controller.signal });

  root.addEventListener("input", (event) => {
    const search = event.target.closest("[data-community-model-search]");
    if (!search) return;
    const query = searchIdentity(search.value.trim());
    root.querySelectorAll("[data-capability-model]").forEach((item) => {
      item.hidden = Boolean(query) && !String(item.dataset.searchValue || "").includes(query);
    });
  }, { signal: controller.signal });

  root.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && posterObjectUrl) closePoster();
  }, { signal: controller.signal });

  void load();
  return () => {
    if (disposed) return;
    disposed = true;
    closePoster();
    clearSecret();
    controller.abort();
    documentRef.body.classList.remove("community-mode");
  };
}
