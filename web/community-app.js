import { createCommunityApiClient } from "./community-api.js";
import {
  PUBLIC_METRICS,
  PUBLIC_PERIODS,
  communityHref,
  formatPublicCost,
  isHttpsPublicUrl,
  normalizePublicLeaderboard,
  normalizePublicMemberDetail,
  publicMetricValue,
  sanitizePublicFilters,
} from "./community-contract.js";
import { createCommunityDemoApi } from "./community-demo-data.js";
import { buildCommunityPosterModel, downloadCommunityPoster } from "./community-poster.js";
import { formatTokenCount, toTokenBigInt, tokenRatio } from "./server-adapter.js";

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
  return `<header class="community-header"><a class="community-brand" href="#/rank" aria-label="TokenFleet 社群榜首页"><span>TF</span><strong>TokenFleet</strong><small>COMMUNITY LEDGER</small></a><nav aria-label="公开页面导航"><a href="#/rank">社群榜</a><a href="/">管理员后台</a></nav></header><section class="community-hero"><span class="panel-kicker">PUBLIC / PRIVACY-SAFE</span><h1>${escapeHTML(title)}</h1><p>${escapeHTML(description)}</p></section>`;
}

function filterOptions(values, current, emptyLabel) {
  const options = [...new Set([current, ...(Array.isArray(values) ? values : [])].filter(Boolean))];
  return `<option value="">${escapeHTML(emptyLabel)}</option>${options.map((value) => `<option value="${escapeHTML(value)}" ${current === value ? "selected" : ""}>${escapeHTML(value)}</option>`).join("")}`;
}

function filterForm(filters, route, { tools = [], models = [] } = {}) {
  return `<form class="community-filters" data-community-action="filters"><label>时间<select name="period">${PUBLIC_PERIODS.map(([value, label]) => `<option value="${value}" ${filters.period === value ? "selected" : ""}>${label}</option>`).join("")}</select></label><label>口径<select name="metric">${PUBLIC_METRICS.map(([value, label]) => `<option value="${value}" ${filters.metric === value ? "selected" : ""}>${label}</option>`).join("")}</select></label><label>工具<select name="tool">${filterOptions(tools, filters.tool, "全部工具")}</select></label><label>模型<select name="model">${filterOptions(models, filters.model, "全部模型")}</select></label><input type="hidden" name="public_id" value="${escapeHTML(route.publicId || "")}"><button class="primary-button small" type="submit">应用筛选</button></form>`;
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

function shareButton({ publicId = "", displayName = "", enabled }) {
  const label = displayName ? `为 ${displayName} 生成分享图片` : "生成社群榜分享图片";
  return `<button class="secondary-button small" type="button" data-community-action="share" aria-label="${escapeHTML(label)}" ${publicId ? `data-public-id="${escapeHTML(publicId)}"` : ""} ${enabled ? "" : 'disabled title="部署 HTTPS 公开地址后可生成二维码海报"'}>生成分享图片</button>`;
}

function leaderboardRows(data, canShare) {
  return data.participants.map((person) => `<article class="community-rank-row"><span class="community-rank ${person.rank && person.rank <= 3 ? "is-top" : ""}">${person.rank ? String(person.rank).padStart(2, "0") : "—"}</span><a class="community-person" href="${localHref({ kind: "profile", publicId: person.publicId, filters: data })}"><span class="avatar">${escapeHTML(person.displayName.slice(0, 1) || "?")}</span><span><strong title="${escapeHTML(person.displayName)}">${escapeHTML(person.displayName)}</strong><small>查看公开构成与趋势</small></span></a>${totalsCells(person)}<div class="community-primary"><span>${escapeHTML(metricLabel(data.metric))}</span><strong title="${escapeHTML(metricDisplay(person, data.metric, false))}">${escapeHTML(metricDisplay(person, data.metric))}</strong><small>${escapeHTML(formatPublicCost(person.cost))}</small></div>${shareButton({ publicId: person.publicId, displayName: person.displayName, enabled: canShare })}</article>`).join("");
}

function renderLeaderboard({ data, filters, canonicalUrl }) {
  const canShare = Boolean(canonicalUrl);
  return `<main id="main-content" class="community-shell">${publicHeader({ title: "把 AI 用量放在同一把尺上", description: "匿名可访问的本地社群榜。看聚合数量与 API 等价估算，不看任何对话内容。" })}${filterForm(filters, { kind: "leaderboard" }, { tools: data.availableTools, models: data.availableModels })}<section class="community-summary"><div><span>公开参赛者</span><strong>${data.totalEntries}</strong></div><div><span>时间</span><strong>${escapeHTML(periodLabel(data.period))}</strong></div><div><span>当前口径</span><strong>${escapeHTML(metricLabel(data.metric))}</strong></div>${shareButton({ enabled: canShare })}</section>${timezoneNotice(data)}<section class="community-board" aria-labelledby="leaderboard-title"><div class="community-board-head"><div><span class="panel-kicker">ONE COMMUNITY / ONE BOARD</span><h2 id="leaderboard-title">社群排行榜</h2></div>${data.generatedAt ? `<small>更新于 ${escapeHTML(data.generatedAt)}</small>` : ""}</div>${data.participants.length ? leaderboardRows(data, canShare) : `<div class="community-empty"><span>∅</span><h2>这个筛选下还没有参赛者</h2><p>换一个时间、工具或模型再看看。</p></div>`}</section>${privacyNotice()}<footer class="community-footer">TokenFleet · 只记数量，不看内容</footer><div class="community-toast" aria-live="polite"></div></main>`;
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

export function breakdownList(items, metric, parentCost = {}) {
  if (!items.length) return `<div class="community-empty compact"><span>∅</span><p>暂无公开分项</p></div>`;
  const comparison = metric === "cost"
    ? costComparisonState(items, parentCost)
    : { comparable: true, hasUnpriced: false, mixedCurrency: false };
  const maximum = items.reduce((current, item) => {
    const value = toTokenBigInt(breakdownValue(item, metric));
    return value > current ? value : current;
  }, 1n);
  const notice = comparison.comparable ? "" : `<p class="community-cost-comparison-note" role="note">${comparison.mixedCurrency ? "含多种币种，未做汇率换算；金额不可直接比较，未绘制比例条。" : "存在未定价分项；金额不可完整比较，未绘制比例条。"}</p>`;
  return `${notice}<div class="community-distribution">${items.slice(0, 10).map((item, index) => {
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
  return `<div class="community-trend"><svg viewBox="0 0 ${width} ${height}" role="img" aria-label="${items.length} 天${escapeHTML(metricLabel(metric))}趋势"><line x1="${inset}" y1="${height * .5}" x2="${width - inset}" y2="${height * .5}"/><polyline points="${line}"/>${points.map(({ x, y, item, value }) => `<circle cx="${x}" cy="${y}" r="4"><title>${escapeHTML(item.date)}：${escapeHTML(value === null ? "未定价" : metric === "cost" ? formatPublicCost(item.cost) : formatTokens(value, false))}</title></circle>`).join("")}</svg><div><span>${escapeHTML(items[0]?.date || "")}</span><strong>峰值 ${escapeHTML(metric === "cost" ? "按公开标准价" : formatTokens(maximum))}</strong><span>${escapeHTML(items.at(-1)?.date || "")}</span></div></div>`;
}

function renderProfile({ person, leaderboard, filters, canonicalUrl }) {
  const canShare = Boolean(canonicalUrl);
  return `<main id="main-content" class="community-shell"><header class="community-header"><a class="community-brand" href="#/rank"><span>TF</span><strong>TokenFleet</strong><small>COMMUNITY LEDGER</small></a><nav aria-label="公开页面导航"><a href="${localHref({ filters })}">返回社群榜</a><a href="/">管理员后台</a></nav></header><a class="community-back" href="${localHref({ filters })}">← 返回社群榜</a><section class="community-profile-hero"><span class="community-profile-rank">${person.rank ? `#${person.rank}` : "未上榜"}</span><div><span class="panel-kicker">PUBLIC MEMBER</span><h1 title="${escapeHTML(person.displayName)}">${escapeHTML(person.displayName)}</h1><p>${escapeHTML(periodLabel(filters.period))} · ${escapeHTML(metricLabel(filters.metric))}</p></div><div><strong>${escapeHTML(metricDisplay(person, filters.metric))}</strong><span>${escapeHTML(metricLabel(filters.metric))}</span></div>${shareButton({ publicId: person.publicId, displayName: person.displayName, enabled: canShare })}</section>${filterForm(filters, { kind: "profile", publicId: person.publicId }, { tools: leaderboard.availableTools, models: leaderboard.availableModels })}${timezoneNotice(person)}<section class="community-total-panel"><div class="community-total-title"><span class="panel-kicker">TOKEN COMPOSITION</span><h2>四类 Token 构成</h2></div>${totalsCells(person)}<dl class="community-extra-totals"><div><dt>不含缓存</dt><dd title="${escapeHTML(formatTokens(person.normTokens, false))}">${escapeHTML(formatTokens(person.normTokens))}</dd></div><div><dt>含缓存合计</dt><dd title="${escapeHTML(formatTokens(person.totalTokens, false))}">${escapeHTML(formatTokens(person.totalTokens))}</dd></div><div><dt>API 等价估算</dt><dd>${escapeHTML(formatPublicCost(person.cost))}</dd></div></dl></section><section class="community-detail-grid"><article><div class="community-board-head"><div><span class="panel-kicker">BY TOOL</span><h2>工具分布</h2></div></div>${breakdownList(person.tools, filters.metric, person.cost)}</article><article><div class="community-board-head"><div><span class="panel-kicker">BY MODEL</span><h2>模型分布</h2></div></div>${breakdownList(person.models, filters.metric, person.cost)}</article><article class="wide"><div class="community-board-head"><div><span class="panel-kicker">DAILY TREND</span><h2>日趋势</h2></div></div>${publicTrend(person.dailyTrend, filters.metric, person.cost)}</article></section>${person.rank && person.rank > 100 ? '<p class="community-rank-note">该参赛者当前在榜单接口 Top 100 之外；分享图会单独附上其公开位置。</p>' : ""}${privacyNotice()}<footer class="community-footer">TokenFleet · 只记数量，不看内容</footer><div class="community-toast" aria-live="polite"></div></main>`;
}

function renderJoin({ hasCode, demoMode = false }) {
  const leaderboardHref = demoMode ? "/rank?demo=1" : "/rank";
  return `<main id="main-content" class="join-shell"><section class="join-card"><a class="community-brand dark" href="${leaderboardHref}"><span>TF</span><strong>TokenFleet</strong><small>SECURE JOIN</small></a><div class="join-status ${hasCode ? "is-ready" : "is-error"}" role="status"><span aria-hidden="true">${hasCode ? "✓" : "!"}</span><div><strong>${hasCode ? "一次性连接码已安全载入" : "链接里没有有效连接码"}</strong><p>${hasCode ? "原始连接码已从浏览器地址栏移除，页面不会显示或保存它。" : "请联系社群管理员重新生成专属接入链接；不要把连接码放在 query 参数里。"}</p></div></div><header><span class="panel-kicker">DEVICE SETUP / 3 STEPS</span><h1>把这台设备接入 TokenFleet</h1><p>客户端固定连接唯一的 TokenFleet 官方服务地址。你只需要把一次性连接码粘贴进客户端，不要填写或修改服务器地址。</p></header><ol class="join-steps"><li><span>01</span><div><strong>安装并打开 TokenFleet</strong><p>按社群管理员提供的固定源码版本说明，在 Mac 或 Windows 上安装 TokenFleet。</p></div></li><li><span>02</span><div><strong>复制一次性连接码</strong><p>连接码通常只能使用一次并有有效期；只在 TokenFleet 客户端内粘贴。</p><button class="primary-button" type="button" data-community-action="copy-join-code" ${hasCode ? "" : "disabled"}>复制连接码</button></div></li><li><span>03</span><div><strong>在客户端确认连接</strong><p>连接后，客户端会立即上传当前可验证的历史日聚合，并持续在后台同步新的日聚合。</p></div></li></ol><aside class="join-disclosure"><h2>连接前请确认公开边界</h2><p>上传到社群用量账本的是日期、时区、工具、模型和四类 Token 聚合。若管理员已为你开启社群榜，公开页会展示昵称、排名、四类 Token、公开标准价估算、工具/模型和日趋势。</p><p>不上传 prompt、回复、代码、文件或项目路径；公开页也不展示邮箱、内部 ID、设备、小时、会话或消息。</p></aside><p class="join-expiry">此页面不会自动连接、自动复制或打开自定义协议。离开页面后，内存中的连接码会立即清除。</p><a class="text-button" href="${leaderboardHref}">先看看匿名社群榜</a><div class="community-toast" aria-live="polite"></div></section></main>`;
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
  documentRef = document,
  locationRef = location,
  isCurrent = () => true,
} = {}) {
  const controller = new AbortController();
  let disposed = false;
  let secret = String(joinCode || "");
  let leaderboard = null;
  let focus = null;
  const filters = sanitizePublicFilters(route.filters || {});
  const canonicalUrl = publicShareUrl({ route, filters, documentRef, locationRef, demoMode });
  const api = demoMode
    ? createCommunityDemoApi({
      empty: new URLSearchParams(locationRef.search).get("scenario") === "empty",
      locationRef,
    })
    : createCommunityApiClient({ signal: controller.signal });

  const clearSecret = () => { secret = ""; };
  const active = () => !disposed && isCurrent();
  globalThis.addEventListener?.("pagehide", clearSecret, { signal: controller.signal });
  if (active()) {
    documentRef.body.classList.add("community-mode");
    documentRef.title = route.kind === "join" ? "安全接入 · TokenFleet" : "社群榜 · TokenFleet";
  }

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
    if (!active()) return;
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
        root.innerHTML = renderProfile({ person: focus, leaderboard, filters, canonicalUrl });
      } else {
        const rawLeaderboard = await api.leaderboard(filters);
        if (!active()) return;
        const nextLeaderboard = normalizePublicLeaderboard(rawLeaderboard, filters);
        if (!active()) return;
        leaderboard = nextLeaderboard;
        root.innerHTML = renderLeaderboard({ data: leaderboard, filters, canonicalUrl });
      }
      if (!active()) return;
      applyCommunityDemoBanner(root, demoMode, documentRef);
      root.querySelector("#main-content")?.setAttribute("tabindex", "-1");
      root.querySelector("#main-content")?.focus({ preventScroll: true });
    } catch (error) {
      if (!active()) return;
      renderError(root, error);
    }
  };

  root.addEventListener("submit", (event) => {
    if (!active()) return;
    const form = event.target.closest('[data-community-action="filters"]');
    if (!form) return;
    event.preventDefault();
    const values = Object.fromEntries(new FormData(form));
    const nextFilters = sanitizePublicFilters(values);
    locationRef.hash = communityHref({
      kind: route.kind === "profile" ? "profile" : "leaderboard",
      publicId: route.publicId,
      filters: nextFilters,
    });
  }, { signal: controller.signal });

  root.addEventListener("click", async (event) => {
    if (!active()) return;
    const target = event.target.closest("[data-community-action]");
    if (!target) return;
    const action = target.dataset.communityAction;
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
    if (action === "retry") void load();
    if (action === "share") {
      if (!active() || !canonicalUrl || !leaderboard || target.dataset.pending === "true") return;
      target.dataset.pending = "true";
      target.disabled = true;
      target.setAttribute("aria-busy", "true");
      try {
        let selected = focus;
        const publicId = target.dataset.publicId;
        if (publicId && selected?.publicId !== publicId) {
          selected = normalizePublicMemberDetail(await api.member(publicId, filters));
          if (!active()) return;
        }
        const posterUrl = publicId
          ? publicShareUrl({ route: { kind: "profile", publicId }, filters, documentRef, locationRef, demoMode })
          : canonicalUrl;
        if (!posterUrl) throw new Error("部署同源 HTTPS 公开地址后才能生成二维码海报");
        const model = buildCommunityPosterModel({ leaderboard, focus: selected, filters, publicUrl: posterUrl, demo: demoMode });
        await downloadCommunityPoster(model, { documentRef, isActive: active });
        if (!active()) return;
        showToast(root, "分享图片已在浏览器本地生成", false, active);
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

  void load();
  return () => {
    if (disposed) return;
    disposed = true;
    clearSecret();
    controller.abort();
    documentRef.body.classList.remove("community-mode");
  };
}
