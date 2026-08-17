import {
  captureJoinCode,
  clearJoinCode,
  takeBatchInvitationToken,
  takeJoinCode,
} from "./join-secret.js";
import {
  ApiError,
  clearApiKey,
  createApiClient,
  normalizeCollection,
  readApiKey,
  saveApiKey,
} from "./api.js";
import { demoApi } from "./demo-data.js";
import { parseCommunityRoute } from "./community-contract.js";
import { mountCommunityApp } from "./community-app.js?v=beta8-member-entry-hotfix";
import {
  aggregateTokenRows,
  adaptUsageDashboard,
  dateRangeForTimezone,
  formatCostSummary,
  formatTokenCount,
  normalizeOrganization,
  normalizePriceRows,
  normalizeUser,
  personDetail,
  tokenRatio,
  toTokenBigInt,
} from "./server-adapter.js";

const app = document.querySelector("#app");
const params = new URLSearchParams(location.search);
const demoMode = params.get("demo") === "1";
const api = demoMode ? demoApi : createApiClient();
let communityCleanup = null;
let navigationGeneration = 0;

function isAdminEntry(locationRef = location) {
  const pathname = String(locationRef?.pathname || "/").replace(/\/+$/, "") || "/";
  return pathname === "/admin" || pathname === "/admin/index.html";
}

function memberRouteFromLocation() {
  if (isAdminEntry()) return null;
  const route = parseCommunityRoute(location) || { kind: "install" };
  if (route.kind === "install" && location.pathname !== "/install") {
    history.replaceState(null, "", `/install${location.search}`);
  }
  return route;
}

function adminLoginErrorMessage(error) {
  if (error?.status === 401) {
    return "管理员登录信息不正确，请检查社群标识、邮箱和密码后重试。";
  }
  return error?.message || "无法验证管理员登录信息";
}

function adminSessionErrorMessage(error) {
  if ([401, 403].includes(error?.status)) {
    return "管理员会话无效或已过期，请重新登录。";
  }
  return error?.message || "管理员后台暂时无法读取";
}

function isCurrentNavigation(generation) {
  return generation === navigationGeneration;
}

function beginNavigation() {
  navigationGeneration += 1;
  const cleanup = communityCleanup;
  communityCleanup = null;
  cleanup?.();
  document.querySelectorAll("dialog.token-dialog").forEach((dialog) => {
    dialog.close?.();
    dialog.remove();
  });
  return navigationGeneration;
}

const NAVIGATION = [
  ["overview", "总览", "grid"],
  ["people", "成员", "people"],
  ["devices", "设备", "laptop"],
  ["history", "历史明细", "ledger"],
  ["breakdown", "工具与模型", "layers"],
  ["costs", "成本", "coins"],
  ["settings", "设置与隐私", "settings"],
];
const ADMIN_ONLY_ROUTES = new Set(["costs"]);

const initialTimezone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
const initialRange = dateRangeForTimezone(initialTimezone);

const state = {
  me: null,
  dashboard: null,
  route: routeFromLocation(),
  filters: {
    ...initialRange,
  },
  loading: false,
  pageLoading: false,
  error: null,
  pageData: null,
};

function clearPrivateState() {
  state.me = null;
  state.dashboard = null;
  state.route = routeFromLocation();
  state.filters = { ...dateRangeForTimezone(initialTimezone) };
  state.loading = false;
  state.pageLoading = false;
  state.error = null;
  state.pageData = null;
}

function routeFromLocation() {
  const value = location.hash.replace(/^#\/?/, "") || "overview";
  const [name, id] = value.split("/");
  return { name: NAVIGATION.some(([key]) => key === name) ? name : "overview", id: id || null };
}

function applyDefaultDateRange(timezone) {
  const range = dateRangeForTimezone(timezone);
  state.filters.start = range.start;
  state.filters.end = range.end;
  state.filters.timezone = range.timezone;
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function icon(name, size = 19) {
  const paths = {
    grid: '<rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/>',
    people: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>',
    laptop: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M2 20h20M9 20v-1h6v1"/>',
    ledger: '<path d="M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z"/><path d="M7 8h10M7 12h10M7 16h6"/>',
    layers: '<path d="m12 2 9 5-9 5-9-5 9-5Z"/><path d="m3 12 9 5 9-5M3 17l9 5 9-5"/>',
    coins: '<circle cx="12" cy="12" r="9"/><path d="M16 8h-6a2 2 0 1 0 0 4h4a2 2 0 1 1 0 4H8M12 6v12"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1.08-1.5 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.6 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6h.08A1.65 1.65 0 0 0 10 3.09V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9c.12.6.65 1.03 1.26 1.03H21a2 2 0 1 1 0 4h-.09c-.64 0-1.2.4-1.51 1Z"/>',
    logout: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5M21 12H9"/>',
    arrow: '<path d="m9 18 6-6-6-6"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    refresh: '<path d="M20 6v6h-6M4 18v-6h6"/><path d="M18.5 9A7 7 0 0 0 6.2 5.5L4 8M5.5 15A7 7 0 0 0 17.8 18.5L20 16"/>',
    shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Z"/><path d="m9 12 2 2 4-4"/>',
  };
  return `<svg class="icon" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.grid}</svg>`;
}

function formatTokens(value, { compact = true } = {}) {
  return formatTokenCount(value, { compact });
}

function formatMoney(value, currency = "USD") {
  const number = Number(value || 0);
  const normalizedCurrency = String(currency || "USD").toUpperCase();
  try {
    return new Intl.NumberFormat("zh-CN", {
      style: "currency",
      currency: normalizedCurrency,
      maximumFractionDigits: number >= 1000 ? 0 : 2,
    }).format(number);
  } catch {
    return `${normalizedCurrency} ${new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 2 }).format(number)}`;
  }
}

function formatCostBreakdown(summary = {}) {
  return formatCostSummary(summary);
}

function costEstimateNote(summary, fallback) {
  if (toTokenBigInt(summary?.unpriced_rows) <= 0n) return fallback;
  const hasPricedRows = Object.keys(summary?.estimated_costs_microunits || {}).length > 0 ||
    Object.keys(summary?.estimated_costs || {}).length > 0;
  return hasPricedRows ? `部分明细未定价；${fallback}` : "当前明细尚未配置价格";
}

function formatTime(value) {
  if (!value) return "从未同步";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "未知";
  const minutes = Math.round((Date.now() - date.getTime()) / 60_000);
  if (minutes < 1) return "刚刚";
  if (minutes < 60) return `${minutes} 分钟前`;
  if (minutes < 1440) return `${Math.round(minutes / 60)} 小时前`;
  return new Intl.DateTimeFormat("zh-CN", { month: "short", day: "numeric" }).format(date);
}

function formatExpiry(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "未知";
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

function titleForRoute() {
  if (state.route.name === "people" && state.route.id) return "成员详情";
  return NAVIGATION.find(([key]) => key === state.route.name)?.[1] || "总览";
}

function pageDescription() {
  const descriptions = {
    overview: "所有授权设备的 AI 用量合计，不代表成员产出。",
    people: "按用量查看成员的多设备合计、主力工具与模型；序号只用于成本管理，不代表绩效。",
    devices: "设备使用随机 ID；不采集主机名、序列号或硬件指纹。",
    history: "按日期展开到工具、模型和设备；相同桶重复上报不会重复累加。",
    breakdown: "理解社群成员正在使用哪些客户端与模型。",
    costs: "API 等价估算、实际账单和固定订阅必须分开核算。",
    settings: "社群口径、保留策略与最小化采集边界。",
  };
  return descriptions[state.route.name] || descriptions.overview;
}

function rangeControls() {
  return `<form class="range-controls" data-action="change-range">
    <label><span>开始</span><input type="date" name="start" value="${escapeHTML(state.filters.start)}" max="${escapeHTML(state.filters.end)}"></label>
    <span class="range-separator">—</span>
    <label><span>结束</span><input type="date" name="end" value="${escapeHTML(state.filters.end)}" min="${escapeHTML(state.filters.start)}"></label>
    <button class="icon-button" type="submit" title="刷新当前范围" aria-label="刷新当前范围">${icon("refresh")}</button>
  </form>`;
}

function renderLogin(message = "") {
  app.innerHTML = `<main class="login-shell">
    <section class="login-art" aria-hidden="true">
      <div class="orbit orbit-one"></div><div class="orbit orbit-two"></div>
      <div class="login-mark"><span>TF</span></div>
      <p>AI usage,<br><em>made accountable.</em></p>
      <small>只记数量，不看内容。</small>
    </section>
    <section class="login-panel">
      <div class="eyebrow">TOKENFLEET / COMMUNITY LEDGER</div>
      <h1>进入社群管理后台</h1>
      <p class="login-copy"><strong>仅限管理员。</strong>成员批次邀请、一次性设备码和成员昵称不能在此使用。请使用管理员账号登录；服务端签发的会话令牌只保存在当前浏览器标签页，关闭标签页后自动清除。</p>
      ${message ? `<div class="inline-alert" role="alert">${escapeHTML(message)}</div>` : ""}
      <form class="login-form" data-action="login">
        <label for="org-slug">社群标识<input id="org-slug" name="org_slug" autocomplete="organization" required maxlength="64" placeholder="your-community"></label>
        <label for="email">邮箱<input id="email" name="email" type="email" autocomplete="username" required placeholder="name@company.com"></label>
        <label for="password">密码</label>
        <div class="secret-input"><input id="password" name="password" type="password" autocomplete="current-password" required><button type="button" data-action="toggle-secret" aria-label="显示或隐藏密码">显示</button></div>
        <button class="primary-button" type="submit">验证并进入 ${icon("arrow", 18)}</button>
      </form>
      <a class="demo-link" href="?demo=1#/overview">没有服务端？打开隔离演示模式</a>
      <a class="demo-link" href="/rank">匿名查看社群榜</a>
      <div class="privacy-strip">${icon("shield", 18)}<span>社群服务不接收 prompt、回复、代码、项目路径或任何第三方凭证。</span></div>
    </section>
  </main>`;
}

function renderShell() {
  const org = state.me?.organization || state.dashboard?.organization || {};
  const activeName = state.route.name;
  app.innerHTML = `<div class="app-shell">
    <aside class="sidebar">
      <a class="brand" href="#/overview" aria-label="TokenFleet 总览"><span class="brand-mark">TF</span><span><strong>TokenFleet</strong><small>COMMUNITY LEDGER</small></span></a>
      <div class="org-chip"><span class="org-avatar">${escapeHTML((org.name || "T").slice(0, 1))}</span><span><strong>${escapeHTML(org.name || "社群")}</strong><small>${escapeHTML(org.timezone || state.filters.timezone)}</small></span></div>
      <nav aria-label="主要导航">${NAVIGATION.filter(([key]) => state.me?.role === "admin" || !ADMIN_ONLY_ROUTES.has(key)).map(([key, label, iconName]) => `<a href="#/${key}" class="nav-item ${activeName === key ? "active" : ""}" aria-label="${escapeHTML(label)}" title="${escapeHTML(label)}" ${activeName === key ? 'aria-current="page"' : ""}>${icon(iconName)}<span>${label}</span></a>`).join("")}</nav>
      <a class="nav-item" href="/rank" aria-label="匿名社群榜" title="匿名社群榜">${icon("people")}<span>社群榜</span></a>
      <div class="sidebar-foot">
        <div class="privacy-promise"><span class="status-light"></span><span><strong>内容零采集</strong><small>仅同步 Token 聚合</small></span></div>
        <button class="nav-item logout-button" type="button" data-action="logout">${icon("logout")}<span>${demoMode ? "退出演示" : "退出"}</span></button>
      </div>
    </aside>
    <main id="main-content" class="main-content" tabindex="-1">
      ${demoMode ? `<div class="demo-banner"><strong>隔离演示模式</strong><span>以下为固定假数据，不会写入真实服务。</span><a href="${escapeHTML(location.pathname)}">退出演示</a></div>` : ""}
      <header class="page-header"><div><div class="eyebrow">${escapeHTML(org.name || "TOKENFLEET")}</div><h1>${escapeHTML(titleForRoute())}</h1><p>${escapeHTML(pageDescription())}</p></div>${["overview", "history", "breakdown", "costs"].includes(activeName) ? rangeControls() : ""}</header>
      <section class="page-body">${state.pageLoading ? renderSkeleton() : renderPage()}</section>
    </main>
  </div><div id="toast-region" class="toast-region" aria-live="polite"></div>`;
}

function renderSkeleton() {
  return `<div class="skeleton-grid" aria-label="正在加载"><div class="skeleton tall"></div><div class="skeleton"></div><div class="skeleton"></div><div class="skeleton wide"></div></div>`;
}

function renderPage() {
  if (state.error) return renderError(state.error);
  if (state.route.name === "overview") return renderOverview();
  if (state.route.name === "people") return state.route.id ? renderPersonDetail() : renderPeople();
  if (state.route.name === "devices") return renderDevices();
  if (state.route.name === "history") return renderHistory();
  if (state.route.name === "breakdown") return renderBreakdown();
  if (state.route.name === "costs") return renderCosts();
  if (state.route.name === "settings") return renderSettings();
  return renderOverview();
}

function renderError(error) {
  const auth = error?.status === 401 || error?.status === 403;
  return `<div class="state-card error-state"><span class="state-code">${auth ? "AUTH" : "OFFLINE"}</span><h2>${auth ? "当前凭证无权访问" : "这一页暂时无法读取"}</h2><p>${escapeHTML(error?.message || "未知错误")}</p><div class="state-actions"><button class="secondary-button" data-action="retry">重试</button>${auth ? '<button class="text-button" data-action="logout">重新登录</button>' : ""}</div></div>`;
}

function metricCard(label, value, note, accent = "green") {
  return `<article class="metric-card accent-${accent}"><div class="metric-label">${escapeHTML(label)}</div><strong title="${escapeHTML(String(value.full ?? value.text))}">${escapeHTML(value.text)}</strong><p>${escapeHTML(note)}</p></article>`;
}

function seriesChart(series = []) {
  if (!series.length) return emptyInline("这个范围还没有用量");
  const width = 760;
  const height = 210;
  const inset = 12;
  const max = series.reduce((current, item) => {
    const value = toTokenBigInt(item.total_tokens);
    return value > current ? value : current;
  }, 1n);
  const points = series.map((item, index) => {
    const x = inset + (index / Math.max(series.length - 1, 1)) * (width - inset * 2);
    const y = height - inset - tokenRatio(item.total_tokens, max) * (height - inset * 2);
    return [x, y, item];
  });
  const line = points.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const area = `${inset},${height - inset} ${line} ${width - inset},${height - inset}`;
  const observations = points.map(([x, y, item]) => {
    const value = formatTokens(item.total_tokens, { compact: false });
    const tooltipX = Math.max(4, Math.min(width - 150, x - 75));
    const tooltipY = y < 54 ? y + 16 : y - 50;
    return `<g class="chart-observation" tabindex="0" role="img" aria-label="${escapeHTML(item.date)}，${escapeHTML(value)}"><circle cx="${x}" cy="${y}" r="16" class="chart-hit"/><circle cx="${x}" cy="${y}" r="3.5" class="chart-point"/><g class="chart-tooltip" aria-hidden="true"><rect x="${tooltipX}" y="${tooltipY}" width="150" height="38" rx="6"/><text x="${tooltipX + 10}" y="${tooltipY + 15}">${escapeHTML(item.date)}</text><text x="${tooltipX + 10}" y="${tooltipY + 30}" class="chart-tooltip-value">${escapeHTML(value)}</text></g></g>`;
  }).join("");
  return `<div class="chart-wrap"><svg class="series-chart" viewBox="0 0 ${width} ${height}" role="img" aria-label="${series.length} 天 Token 趋势"><defs><linearGradient id="chart-area" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1d774f" stop-opacity=".24"/><stop offset="1" stop-color="#1d774f" stop-opacity="0"/></linearGradient></defs><line x1="${inset}" y1="${height * 0.35}" x2="${width - inset}" y2="${height * 0.35}" class="chart-grid"/><line x1="${inset}" y1="${height * 0.68}" x2="${width - inset}" y2="${height * 0.68}" class="chart-grid"/><polygon points="${area}" fill="url(#chart-area)"/><polyline points="${line}" class="chart-line"/>${observations}</svg><div class="chart-axis"><span>${escapeHTML(series[0].date)}</span><span>峰值 ${formatTokens(max)}</span><span>${escapeHTML(series.at(-1).date)}</span></div></div>`;
}

function distribution(items = [], color = "blue") {
  if (!items.length) return emptyInline("暂无可展示的分项");
  const max = items.reduce((current, item) => {
    const value = toTokenBigInt(item.total_tokens ?? item.tokens);
    return value > current ? value : current;
  }, 1n);
  return `<div class="distribution">${items.slice(0, 8).map((item, index) => {
    const value = toTokenBigInt(item.total_tokens ?? item.tokens);
    const width = Math.max(1, tokenRatio(value, max) * 100).toFixed(2);
    return `<div class="distribution-row"><div><span class="rank-number">${String(index + 1).padStart(2, "0")}</span><strong title="${escapeHTML(item.name || item.model || item.tool)}">${escapeHTML(item.name || item.model || item.tool || "未识别")}</strong>${item.tool && item.name !== item.tool ? `<small>${escapeHTML(item.tool)}</small>` : ""}</div><div class="bar-track"><span class="bar-fill bar-${color}" style="width:${width}%"></span></div><b title="${formatTokens(value, { compact: false })}">${formatTokens(value)}</b></div>`;
  }).join("")}</div>`;
}

function renderOverview() {
  const dashboard = state.dashboard || {};
  const totals = dashboard.totals || {};
  const people = normalizeCollection(dashboard.people, ["items"]);
  const devices = normalizeCollection(dashboard.devices, ["items"]);
  const estimate = formatCostBreakdown(totals);
  return `${dashboard.timezone_warning ? `<div class="timezone-warning" role="status"><strong>混合设备时区</strong><span>${escapeHTML(dashboard.timezone_warning)}</span></div>` : ""}<div class="metric-grid">
    ${metricCard("设备 Token 合计", { text: formatTokens(totals.total_tokens), full: formatTokens(totals.total_tokens, { compact: false }) }, "包含所有已授权设备与缓存 Token", "ink")}
    ${metricCard("API 等价估算", { text: estimate, full: estimate }, costEstimateNote(totals, "按币种分别估算，不合并汇率"), "blue")}
    ${metricCard("活跃成员", { text: String(totals.active_members || people.length), full: totals.active_members || people.length }, "Token 不是绩效或产出指标", "green")}
    ${metricCard("在线设备", { text: String(totals.active_devices || devices.filter((item) => item.enabled).length), full: totals.active_devices }, `共 ${devices.length} 台已登记设备`, "orange")}
  </div>
  <div class="overview-grid">
    <article class="panel trend-panel"><div class="panel-head"><div><span class="panel-kicker">DAILY FLOW</span><h2>社群用量走势</h2></div><span class="soft-badge">${escapeHTML(dashboard.range?.timezone || state.filters.timezone)}</span></div>${seriesChart(dashboard.series || [])}</article>
    <article class="panel tool-panel"><div class="panel-head"><div><span class="panel-kicker">CLIENT MIX</span><h2>工具分布</h2></div></div>${distribution(dashboard.by_tool || [], "green")}</article>
    <article class="panel people-panel"><div class="panel-head"><div><span class="panel-kicker">COMMUNITY LEDGER</span><h2>社群用量榜</h2></div><a href="#/people">查看全部 ${icon("arrow", 16)}</a></div>${peopleTable(people.slice(0, 5), true)}</article>
    <article class="panel device-panel"><div class="panel-head"><div><span class="panel-kicker">DEVICE PULSE</span><h2>最近设备</h2></div><a href="#/devices">设备管理 ${icon("arrow", 16)}</a></div>${deviceList(devices.slice(0, 5))}</article>
  </div>`;
}

function peopleTable(items, compact = false) {
  if (!items.length) return emptyInline("还没有成员；请先新建成员，再生成设备邀请码");
  const header = compact
    ? "<th><span class=\"sr-only\">用量序号</span>#</th><th>成员</th><th>主力工具 / 模型</th><th>Token / 缓存</th><th>API 估算</th><th><span class=\"sr-only\">操作</span></th>"
    : "<th><span class=\"sr-only\">用量序号</span>#</th><th>成员</th><th>主力工具 / 模型</th><th>设备</th><th>Token</th><th>缓存</th><th>API 估算</th><th>最近同步</th><th>参与社群榜</th><th><span class=\"sr-only\">操作</span></th>";
  const rows = items.map((person, index) => {
    const disabled = person.status === "disabled";
    const publicEligible = person.role === "member" && !disabled;
    const member = `<td><a class="person-cell" href="#/people/${encodeURIComponent(person.id)}"><span class="avatar">${escapeHTML((person.name || person.email || "?").slice(0, 1))}</span><span><strong>${escapeHTML(person.name || "未命名")}${disabled ? '<i class="member-state">已禁用</i>' : ""}</strong>${compact ? "" : `<small>${escapeHTML(person.email || "")}</small>`}</span></a></td>`;
    const signature = `<td><span class="usage-signature"><strong>${escapeHTML(person.primary_tool || "暂无工具")}</strong><small>${escapeHTML(person.primary_model || "暂无模型")}</small></span></td>`;
    const rank = `<td><span class="rank-number" title="仅按当前范围 Token 排序，不代表绩效">${String(index + 1).padStart(2, "0")}</span></td>`;
    const enrollmentLabel = Number(person.device_count || 0) > 0 ? "添加新设备" : "补发设备码";
    const quickEnrollment = !compact && state.me?.role === "admin" && publicEligible
      ? `<button class="text-button small" type="button" data-action="open-enrollment" data-user-id="${escapeHTML(person.id)}" title="为这名既有成员生成一次性设备码；旧的未使用有效码会立即失效，不会新建成员或占用批次名额">${enrollmentLabel}</button>`
      : "";
    const action = `<td><div class="row-actions">${quickEnrollment}<a class="row-link" href="#/people/${encodeURIComponent(person.id)}" aria-label="查看 ${escapeHTML(person.name || "成员")}">${icon("arrow", 17)}</a></div></td>`;
    if (compact) {
      return `<tr>${rank}${member}${signature}<td class="usage-amount" title="Token ${formatTokens(person.total_tokens, { compact: false })}；缓存 ${formatTokens(person.cache_tokens, { compact: false })}"><strong>${formatTokens(person.total_tokens)}</strong><small>缓存 ${formatTokens(person.cache_tokens)}</small></td><td>${escapeHTML(formatCostBreakdown(person))}</td>${action}</tr>`;
    }
    const communitySwitch = state.me?.role === "admin"
      ? `<td><button type="button" class="switch-control" role="switch" aria-checked="${person.public_profile_enabled === true}" aria-label="${escapeHTML(person.name || "成员")}参与社群榜" data-action="toggle-public-profile" data-user-id="${escapeHTML(person.id)}" data-enabled="${person.public_profile_enabled !== true}" data-active="${publicEligible}" ${publicEligible ? "" : `disabled title="${disabled ? "请先重新启用成员" : "仅成员可参与社群榜"}"`}><span aria-hidden="true"></span><b>${person.role !== "member" ? "不适用" : disabled && person.public_profile_enabled ? "已隐藏" : person.public_profile_enabled === true ? "公开" : "关闭"}</b></button></td>`
      : `<td>${person.public_profile_enabled === true ? '<span class="status-badge status-active">公开</span>' : "—"}</td>`;
    return `<tr>${rank}${member}${signature}<td>${Number(person.device_count || 0)} 台</td><td title="${formatTokens(person.total_tokens, { compact: false })}"><strong>${formatTokens(person.total_tokens)}</strong></td><td title="缓存读写合计 ${formatTokens(person.cache_tokens, { compact: false })}">${formatTokens(person.cache_tokens)}</td><td>${escapeHTML(formatCostBreakdown(person))}</td><td>${escapeHTML(formatTime(person.last_seen_at))}</td>${communitySwitch}${action}</tr>`;
  }).join("");
  return `<div class="table-scroll"><table class="usage-ranking ${compact ? "usage-ranking-compact" : ""}"><thead><tr>${header}</tr></thead><tbody>${rows}</tbody></table><p class="ranking-note">按当前日期范围的设备 Token 合计排序；用于费用与容量管理，不代表工作量、产出或绩效。</p></div>`;
}

function peoplePageData(people = state.dashboard?.people || []) {
  return {
    items: people,
    batches: normalizeCollection(state.pageData, ["batches"]),
  };
}

function renderPeople() {
  const people = normalizeCollection(state.pageData, ["items", "users"]);
  const batches = normalizeCollection(state.pageData, ["batches"]);
  const adminActions = state.me?.role === "admin"
    ? `<div class="section-action-buttons"><a class="secondary-button small" href="#/rank">查看公开榜</a><button class="primary-button small" data-action="open-batch">${icon("plus", 17)} 创建自助批次（单批最多 50）</button><button class="secondary-button small" data-action="open-member">${icon("plus", 17)} 单独新建参赛者</button><button class="secondary-button small" data-action="open-enrollment">${icon("plus", 17)} 给已有成员补发设备码</button></div>`
    : "";
  const batchPanel = state.me?.role === "admin" ? invitationBatchPanel(batches) : "";
  return `<div class="section-actions"><div class="section-count"><strong>${people.length}</strong><span>名已登记成员</span></div>${adminActions}</div>${batchPanel}<article class="panel full-panel">${peopleTable(people)}</article><dialog id="batch-dialog">${batchDialog()}</dialog><dialog id="member-dialog">${memberDialog()}</dialog><dialog id="enrollment-dialog">${enrollmentDialog(people)}</dialog>`;
}

function invitationBatchPanel(batches) {
  if (!batches.length) return `<article class="panel invitation-batch-panel"><div class="panel-head"><div><span class="panel-kicker">SELF-SERVICE BATCHES</span><h2>自助接入批次</h2></div></div><div class="empty-state compact"><span>50</span><p>还没有批次链接。单批最多 50，可创建多个批次进入同一社群；成员自己登记唯一昵称并领取个人设备码。</p></div></article>`;
  const statusLabels = { open: "开放中", full: "已满额", expired: "已过期", closed: "已关闭" };
  return `<article class="panel invitation-batch-panel"><div class="panel-head"><div><span class="panel-kicker">SELF-SERVICE BATCHES</span><h2>自助接入批次</h2></div><small>批次令牌只在创建时返回一次</small></div><div class="invitation-batch-list">${batches.map((batch) => `<div class="invitation-batch-row"><div><span class="status-badge ${batch.status === "open" ? "status-active" : "status-disabled"}">${escapeHTML(statusLabels[batch.status] || batch.status)}</span><strong>${Number(batch.claimed_count || 0)} / ${Number(batch.capacity || 0)} 人已领取</strong><small>有效期至 ${escapeHTML(formatExpiry(batch.expires_at))}</small></div>${batch.status === "open" ? `<button class="danger-button small" type="button" data-action="close-invitation-batch" data-batch-id="${escapeHTML(batch.id)}">关闭批次</button>` : ""}</div>`).join("")}</div></article>`;
}

function batchDialog() {
  return `<form method="dialog" class="dialog-card" data-action="create-invitation-batch"><div class="dialog-head"><div><span class="panel-kicker">ONE LINK / MANY MEMBERS</span><h2>创建自助接入批次</h2></div><button class="icon-button" type="button" data-action="close-dialog" aria-label="关闭">×</button></div><p>生成一个可发到社群的链接。每人填写唯一公开昵称，系统再给他单独的 60 分钟一次性设备码。</p><label>单批人数<input name="capacity" type="number" min="1" max="50" value="50" required></label><label>批次有效期<select name="expires_in_hours" required><option value="1">1 小时</option><option value="6">6 小时</option><option value="12">12 小时</option><option value="24" selected>24 小时</option></select></label><div class="inline-alert"><strong>单批最多 50，可创建多个批次进入同一社群。</strong>关闭、过期或满额后，外部统一显示“批次不可用”，不会暴露具体原因。</div><div class="dialog-actions"><button class="text-button" type="button" data-action="close-dialog">取消</button><button class="primary-button small" type="submit" value="default">生成批次链接</button></div></form>`;
}

function memberDialog() {
  return `<form method="dialog" class="dialog-card" data-action="create-member"><div class="dialog-head"><div><span class="panel-kicker">NEW PARTICIPANT</span><h2>新建参赛者</h2></div><button class="icon-button" type="button" data-action="close-dialog" aria-label="关闭">×</button></div><p>只需昵称。参赛者没有后台账号；创建后会得到只显示一次的专属接入链接。</p><label>公开昵称<input name="display_name" maxlength="128" autocomplete="off" required placeholder="例如：小王"></label><label>链接有效期<select name="expires_in_minutes" required><option value="60">1 小时</option><option value="1440" selected>24 小时</option></select></label><label class="consent-check"><input name="public_profile_enabled" type="checkbox" value="true"><span><strong>立即参与社群榜</strong><small>默认关闭。开启后昵称、排名、四类 Token、估算费用、工具/模型和日趋势可被匿名访问；不公开邮箱、设备、小时、会话或消息。</small></span></label><div class="dialog-actions"><button class="text-button" type="button" data-action="close-dialog">取消</button><button class="primary-button small" type="submit" value="default">创建并生成链接</button></div></form>`;
}

function enrollmentDialog(people) {
  return `<form method="dialog" class="dialog-card" data-action="create-enrollment"><div class="dialog-head"><div><span class="panel-kicker">SAFE REISSUE</span><h2>给已有成员补发设备码</h2></div><button class="icon-button" type="button" data-action="close-dialog" aria-label="关闭">×</button></div><p>适合成员领取后漏保存，或需要连接另一台设备。新码 60 分钟有效、只能用一次；生成后，该成员此前仍未使用且未过期的旧码会立即失效。</p><label>确认成员<select name="user_id" required><option value="">选择已有成员</option>${people.filter((person) => person.status === "active" && person.role === "member").map((person) => `<option value="${escapeHTML(person.id)}">${escapeHTML(person.name)} · ${Number(person.device_count || 0)} 台设备${person.email ? ` · ${escapeHTML(person.email)}` : ""}</option>`).join("")}</select></label><div class="inline-alert">同一成员只保留一个有效未用码；不会重复创建成员，不占自助批次名额，已使用码及其审计记录不会改变。</div><p class="form-note">请核对昵称和现有设备数量，生成后立即通过私密渠道发送；原始码不会在后台显示或保存。</p><div class="dialog-actions"><button class="text-button" type="button" data-action="close-dialog">取消</button><button class="primary-button small" type="submit" value="default">确认补发 60 分钟设备码</button></div></form>`;
}

function renderPersonDetail() {
  const person = state.pageData || {};
  const devices = normalizeCollection(person.devices, ["items"]);
  const usage = normalizeCollection(person.usage, ["items"]);
  const total = person.total_tokens === null || person.total_tokens === undefined
    ? usage.reduce((sum, item) => sum + toTokenBigInt(item.total_tokens), 0n)
    : toTokenBigInt(person.total_tokens);
  const disabled = person.status === "disabled";
  const canManage = state.me?.role === "admin" && person.id !== state.me?.id;
  const statusAction = canManage
    ? `<button class="${disabled ? "secondary-button" : "danger-button"} small" data-action="toggle-user" data-user-id="${escapeHTML(person.id)}" data-enabled="${disabled ? "true" : "false"}">${disabled ? "重新启用成员" : "禁用成员"}</button>`
    : "";
  const publicAction = state.me?.role === "admin" && person.role === "member"
    ? `<button type="button" class="switch-control" role="switch" aria-checked="${person.public_profile_enabled === true}" aria-label="${escapeHTML(person.name || "成员")}参与社群榜" data-action="toggle-public-profile" data-user-id="${escapeHTML(person.id)}" data-enabled="${person.public_profile_enabled !== true}" data-active="${!disabled}" ${disabled ? 'disabled title="请先重新启用成员"' : ""}><span aria-hidden="true"></span><b>${disabled && person.public_profile_enabled ? "已禁用（公开页隐藏）" : person.public_profile_enabled === true ? "公开榜已开启" : "参与社群榜"}</b></button>`
    : "";
  const enrollmentAction = state.me?.role === "admin" && person.role === "member" && !disabled
    ? `<button class="secondary-button small" type="button" data-action="open-enrollment" data-user-id="${escapeHTML(person.id)}">${devices.length > 0 ? "添加新设备" : "补发设备码"}</button>`
    : "";
  const costText = formatCostBreakdown(person);
  return `<a class="back-link" href="#/people">← 返回成员列表</a><section class="person-hero"><span class="avatar large">${escapeHTML((person.name || "?").slice(0, 1))}</span><div><h2>${escapeHTML(person.name || "未命名成员")}</h2><p>${person.email ? escapeHTML(person.email) : '<span class="muted-label">无后台登录账号</span>'}</p></div><div class="person-status-actions"><span class="status-badge ${disabled ? "status-disabled" : "status-active"}">${disabled ? "已禁用" : "正常"}</span>${enrollmentAction}${publicAction}${statusAction}</div></section><div class="metric-grid three">${metricCard("Token 合计", { text: formatTokens(total), full: formatTokens(total, { compact: false }) }, "当前查询范围内的设备合计", "ink")}${metricCard("设备", { text: String(devices.length), full: devices.length }, `${devices.filter((item) => item.enabled).length} 台启用`, "green")}${metricCard("API 标准价估算", { text: costText, full: costText }, costEstimateNote(person, "按已识别模型和计价组成分别估算，不等于真实账单"), "blue")}</div><div class="two-column"><article class="panel"><div class="panel-head"><div><span class="panel-kicker">DEVICES</span><h2>名下设备</h2></div></div>${deviceList(devices)}</article><article class="panel"><div class="panel-head"><div><span class="panel-kicker">MODEL LEDGER</span><h2>最近模型</h2></div></div>${distribution(aggregateBy(usage, "model"), "blue")}</article></div><dialog id="enrollment-dialog">${enrollmentDialog([{ ...person, device_count: devices.length }])}</dialog>`;
}

function deviceList(items) {
  if (!items.length) return emptyInline("暂无已登记设备");
  return `<div class="device-list">${items.map((device) => `<div class="device-row"><span class="device-icon">${icon("laptop", 18)}</span><span><strong>${escapeHTML(device.label || `设备 ${String(device.id || "").slice(-6)}`)}</strong><small>${escapeHTML(device.user_name || device.platform || "macOS")} · ${escapeHTML(formatTime(device.last_seen_at))}</small></span><span class="device-health ${device.enabled === false ? "disabled" : ""}">${device.enabled === false ? "已禁用" : "正常"}</span></div>`).join("")}</div>`;
}

function renderDevices() {
  const devices = normalizeCollection(state.pageData, ["items", "devices"]);
  if (!devices.length) return `<article class="panel">${emptyInline("尚未登记设备")}</article>`;
  return `<div class="device-grid">${devices.map((device) => `<article class="device-card ${device.enabled === false ? "is-disabled" : ""}"><div class="device-card-top"><span class="device-icon large">${icon("laptop", 24)}</span><span class="device-health ${device.enabled === false ? "disabled" : ""}">${device.enabled === false ? "已禁用" : "已连接"}</span></div><h2>${escapeHTML(device.label || `设备 ${String(device.id || "").slice(-6)}`)}</h2><p>${escapeHTML(device.user_name || "未分配成员")}</p><dl><div><dt>Token</dt><dd>${formatTokens(device.total_tokens)}</dd></div><div><dt>最近同步</dt><dd>${escapeHTML(formatTime(device.last_seen_at))}</dd></div><div><dt>客户端</dt><dd>${escapeHTML(device.app_version || "未知")}</dd></div><div><dt>设备 ID</dt><dd><code>${escapeHTML(String(device.id || "").slice(0, 8))}</code></dd></div></dl>${state.me?.role === "admin" ? `<button class="${device.enabled === false ? "secondary-button" : "danger-button"} full" data-action="toggle-device" data-device-id="${escapeHTML(device.id)}" data-enabled="${device.enabled === false ? "true" : "false"}">${device.enabled === false ? "重新启用" : "禁用设备"}</button>` : ""}</article>`).join("")}</div>`;
}

function aggregateBy(items, key) {
  return aggregateTokenRows(items, key, (item) => ({ tool: item.tool }));
}

function renderHistory() {
  const items = normalizeCollection(state.pageData, ["items", "usage"]);
  if (!items.length) return `<article class="panel">${emptyInline("这个范围还没有上报记录")}</article>`;
  const days = new Map();
  items.forEach((item) => {
    if (!days.has(item.date)) days.set(item.date, []);
    days.get(item.date).push(item);
  });
  return `<div class="history-list">${[...days.entries()].map(([date, rows], index) => {
    const total = rows.reduce((sum, row) => sum + toTokenBigInt(row.total_tokens), 0n);
    const tools = aggregateBy(rows, "tool");
    return `<details class="history-day" ${index < 2 ? "open" : ""}><summary><span class="day-date"><strong>${escapeHTML(date)}</strong><small>${rows.length} 个工具/模型/设备桶</small></span><span class="tool-pills">${tools.slice(0, 3).map((tool) => `<i>${escapeHTML(tool.name)}</i>`).join("")}</span><span class="day-total" title="${formatTokens(total, { compact: false })}">${formatTokens(total)}</span><span class="disclosure">⌄</span></summary><div class="table-scroll history-table"><table><thead><tr><th>工具 / 模型</th><th>设备</th><th>输入</th><th>输出</th><th>缓存读</th><th>缓存写</th><th>合计</th></tr></thead><tbody>${rows.map((row) => `<tr><td><strong>${escapeHTML(row.tool || "未识别")}</strong><small>${escapeHTML(row.model || "未识别模型")}${row.completeness && row.completeness !== "exact" ? ` · ${escapeHTML(row.completeness)}` : ""}</small></td><td title="${escapeHTML(row.device_id || "")}">${escapeHTML(row.device_label || String(row.device_id || "").slice(0, 8) || "—")}</td><td>${formatTokens(row.input_tokens)}</td><td>${formatTokens(row.output_tokens)}</td><td>${formatTokens(row.cache_read_tokens)}</td><td>${formatTokens(row.cache_write_tokens)}</td><td><strong>${formatTokens(row.total_tokens)}</strong></td></tr>`).join("")}</tbody></table></div></details>`;
  }).join("")}</div>`;
}

function renderBreakdown() {
  const dashboard = state.dashboard || {};
  return `<div class="two-column breakdown-columns"><article class="panel"><div class="panel-head"><div><span class="panel-kicker">BY CLIENT</span><h2>工具</h2></div><span class="soft-badge">含缓存</span></div>${distribution(dashboard.by_tool || [], "green")}</article><article class="panel"><div class="panel-head"><div><span class="panel-kicker">BY MODEL</span><h2>模型</h2></div><span class="soft-badge">Top 8</span></div>${distribution(dashboard.by_model || [], "blue")}</article></div><article class="explain-card"><span class="explain-number">01</span><div><h2>为什么“总 Token”会很大？</h2><p>这里的合计包含 input、output、cache read 和 cache write。大量缓存读取说明 Agent 在复用上下文，不等于发生了同等规模的付费输出。</p></div><span class="explain-number">02</span><div><h2>用量序号应该怎么理解？</h2><p>它只是当前日期范围的成本与容量视图。任务复杂度、缓存策略与模型差异都会改变 Token，不能把序号解释成员工绩效或产出。</p></div></article>`;
}

function priceEditor() {
  const tools = (state.dashboard?.by_tool || []).map((item) => item.name).filter(Boolean);
  const models = (state.dashboard?.by_model || []).map((item) => item.name).filter(Boolean);
  const effectiveFrom = state.filters.end || "";
  return `<article class="panel full-panel pricing-editor"><div class="panel-head"><div><span class="panel-kicker">ADD PRICE VERSION</span><h2>新增模型价格</h2></div><span class="soft-badge">仅管理员</span></div><p class="form-note">请按供应商公开价格或实际合同自行核验后录入；TokenFleet 不预填“当前官方价”。新版本用于此后上报，已有未定价明细不会自动重算。</p><form data-action="create-price"><div class="pricing-identity-grid"><label>工具<input name="tool" list="observed-tools" maxlength="128" autocomplete="off" required placeholder="例如 Codex"></label><label>模型<input name="model" list="observed-models" maxlength="128" autocomplete="off" required placeholder="填写上报中的精确模型名"></label><label>币种<input name="currency" minlength="3" maxlength="3" pattern="[A-Za-z]{3}" autocomplete="off" required placeholder="USD"></label><label>生效日期<input name="effective_from" type="date" value="${escapeHTML(effectiveFrom)}" required></label></div><div class="pricing-rate-grid"><label>输入 / 百万<input name="input_per_million" type="number" inputmode="decimal" min="0" step="0.00000001" required></label><label>输出 / 百万<input name="output_per_million" type="number" inputmode="decimal" min="0" step="0.00000001" required></label><label>缓存读 / 百万<input name="cache_read_per_million" type="number" inputmode="decimal" min="0" step="0.00000001" required></label><label>缓存写 / 百万<input name="cache_write_per_million" type="number" inputmode="decimal" min="0" step="0.00000001" required></label></div><label class="consent-check"><input name="public_estimate" type="checkbox" value="true" checked><span><strong>用于社群榜 API 等价估算</strong><small>显式开启后，这个冻结价格版本才可用于匿名榜的估算费用；协议价或私有价格请取消勾选。费率本身不会出现在公开接口。</small></span></label><datalist id="observed-tools">${tools.map((name) => `<option value="${escapeHTML(name)}"></option>`).join("")}</datalist><datalist id="observed-models">${models.map((name) => `<option value="${escapeHTML(name)}"></option>`).join("")}</datalist><button class="primary-button small" type="submit">保存价格版本</button></form></article>`;
}

function latestPrivatePriceVersions(items) {
  const latest = new Map();
  items.forEach((item) => {
    const key = `${String(item.tool || "").toLocaleLowerCase()}\u0000${String(item.model || "").toLocaleLowerCase()}`;
    const current = latest.get(key);
    if (!current || String(item.effective_from || "") > String(current.effective_from || "")) {
      latest.set(key, item);
    }
  });
  return [...latest.values()].filter((item) => item.public_estimate !== true);
}

function renderCosts() {
  const pricing = state.pageData || {};
  const items = normalizePriceRows(pricing);
  const totals = state.dashboard?.totals || {};
  const estimate = formatCostBreakdown(totals);
  const versionLabel = items.length ? `${items.length} 个价格版本` : "未配置";
  const latestPrivate = latestPrivatePriceVersions(items);
  const publicCoverageWarning = latestPrivate.length
    ? `<div class="boundary-card" role="alert"><span class="boundary-icon">!</span><div><strong>有 ${latestPrivate.length} 个工具/模型的最新价格版本是私有价格</strong><p>这些版本生效后的新用量会在公开榜显示“未定价”，不会继续沿用更早的公开价格。请确认这是预期行为。</p></div></div>`
    : "";
  return `<div class="cost-ledger"><article class="cost-card estimate"><span>01 / ESTIMATE</span><h2>${escapeHTML(estimate)}</h2><strong>API 等价估算</strong><p>${escapeHTML(costEstimateNote(totals, "按币种分别列示，不做隐含汇率换算。"))}</p></article><article class="cost-card actual"><span>02 / INVOICE</span><h2>—</h2><strong>实际 API 账单</strong><p>尚未导入供应商发票，不能拿估算冒充真实支出。</p></article><article class="cost-card fixed"><span>03 / FIXED</span><h2>—</h2><strong>固定订阅费用</strong><p>Claude/Codex 套餐与席位费应另行登记。</p></article></div>${state.me?.role === "admin" ? priceEditor() : ""}${publicCoverageWarning}<article class="panel full-panel"><div class="panel-head"><div><span class="panel-kicker">PRICE SNAPSHOT</span><h2>模型价格版本</h2></div><span class="soft-badge">${escapeHTML(versionLabel)}</span></div>${items.length ? `<div class="table-scroll"><table><thead><tr><th>模型</th><th>工具</th><th>生效日期</th><th>币种</th><th>输入 / 百万</th><th>输出 / 百万</th><th>缓存读 / 百万</th><th>缓存写 / 百万</th><th>社群榜估算</th></tr></thead><tbody>${items.map((item) => { const currency = item.currency || "USD"; return `<tr><td><strong>${escapeHTML(item.model)}</strong></td><td>${escapeHTML(item.tool || "—")}</td><td><time datetime="${escapeHTML(item.effective_from || "")}">${escapeHTML(item.effective_from || "—")}</time></td><td><strong>${escapeHTML(currency)}</strong></td><td>${escapeHTML(formatMoney(item.input_per_million, currency))}</td><td>${escapeHTML(formatMoney(item.output_per_million, currency))}</td><td>${escapeHTML(formatMoney(item.cache_read_per_million, currency))}</td><td>${escapeHTML(formatMoney(item.cache_write_per_million, currency))}</td><td><button type="button" class="switch-control" role="switch" aria-checked="${item.public_estimate === true}" aria-label="${escapeHTML(item.model || "价格版本")}允许用于社群榜估算" data-action="toggle-price-public" data-price-id="${escapeHTML(item.id || "")}" data-enabled="${item.public_estimate !== true}" ${item.id ? "" : 'disabled title="该版本缺少可更新 ID"'}><span aria-hidden="true"></span><b>${item.public_estimate === true ? "允许" : "私有"}</b></button></td></tr>`; }).join("")}</tbody></table></div>` : emptyInline("还没有配置价格版本")}</article>`;
}

function renderSettings() {
  const org = state.pageData || state.me?.organization || {};
  const admin = state.me?.role === "admin";
  return `<div class="settings-layout"><div><article class="panel settings-card"><div class="panel-head"><div><span class="panel-kicker">COMMUNITY</span><h2>社群口径</h2></div></div><form data-action="save-organization"><label>社群名称<input name="name" value="${escapeHTML(org.name || "")}" ${admin ? "" : "disabled"}></label><div class="form-grid"><label>默认时区<select name="timezone" ${admin ? "" : "disabled"}>${["Asia/Shanghai", "Asia/Singapore", "UTC", "America/Los_Angeles"].map((zone) => `<option ${zone === org.timezone ? "selected" : ""}>${zone}</option>`).join("")}</select></label><label>数据保留天数<input type="number" name="retention_days" min="30" max="3650" value="${escapeHTML(org.retention_days || 365)}" ${admin ? "" : "disabled"}></label></div>${admin ? '<button class="primary-button small" type="submit">保存社群设置</button>' : '<p class="form-note">仅管理员可以修改。</p>'}</form></article><article class="panel settings-card"><div class="panel-head"><div><span class="panel-kicker">EXTERNAL CONNECTIONS</span><h2>第三方服务边界</h2></div></div><div class="boundary-card"><span class="boundary-icon">↗</span><div><strong>第三方排行榜或社区服务由成员自行连接</strong><p>TokenFleet 不接收、不保存、也不转发个人专属 URL、访问令牌或设备密钥。TokenFleet 社群服务不可用时，不会改变其他服务的连接状态。</p></div></div></article></div><aside><article class="privacy-manifesto"><span class="panel-kicker">DATA MINIMIZATION</span><h2>我们只知道多少，<br><em>不知道说了什么。</em></h2><ul><li><span>采集</span>日期、时区、工具、模型、四类 Token、匿名设备 ID</li><li><span>不采集</span>prompt、回复、代码、文件、项目路径、会话正文</li><li><span>不评价</span>Token 不作为个人绩效或产出指标</li></ul></article><article class="panel key-card"><span class="panel-kicker">SESSION SECURITY</span><h2>当前浏览器凭证</h2><p>短期会话令牌只保存在 sessionStorage。关闭这个标签页后会自动清除。</p><button class="danger-button full" data-action="logout">清除并退出</button></article></aside></div>`;
}

function emptyInline(message) {
  return `<div class="empty-inline"><span>∅</span><p>${escapeHTML(message)}</p></div>`;
}

async function loadBase(generation) {
  if (!isCurrentNavigation(generation)) return false;
  state.loading = true;
  state.error = null;
  try {
    if (demoMode) {
      const nextMe = await api.me();
      if (!isCurrentNavigation(generation)) return false;
      const nextRange = dateRangeForTimezone(
        nextMe?.organization?.default_timezone || nextMe?.organization?.timezone,
      );
      const nextFilters = { ...state.filters, ...nextRange };
      const nextDashboard = await api.dashboard(nextFilters);
      if (!isCurrentNavigation(generation)) return false;
      state.me = nextMe;
      state.filters = nextFilters;
      state.dashboard = nextDashboard;
    } else {
      const [rawMe, rawOrganization, rawDevices] = await Promise.all([
        api.me(),
        api.organization(),
        api.devices(),
      ]);
      if (!isCurrentNavigation(generation)) return false;
      const organization = normalizeOrganization(rawOrganization);
      const nextRange = dateRangeForTimezone(organization.default_timezone);
      const nextFilters = { ...state.filters, ...nextRange };
      const [rawUsage, rawUsers] = await Promise.all([
        api.dashboard({ start: nextFilters.start, end: nextFilters.end }),
        rawMe.role === "admin" ? api.users() : Promise.resolve([rawMe]),
      ]);
      if (!isCurrentNavigation(generation)) return false;
      const nextMe = { ...normalizeUser(rawMe), organization };
      const nextDashboard = adaptUsageDashboard(rawUsage, {
        organization,
        users: rawUsers,
        devices: rawDevices,
        start: nextFilters.start,
        end: nextFilters.end,
      });
      if (!isCurrentNavigation(generation)) return false;
      state.me = nextMe;
      state.filters = nextFilters;
      state.dashboard = nextDashboard;
    }
    if (!isCurrentNavigation(generation)) return false;
    if (state.dashboard?.organization?.timezone) {
      state.filters.timezone = state.dashboard.organization.timezone;
    }
    return true;
  } catch (error) {
    if (!isCurrentNavigation(generation)) return false;
    state.error = error;
    if (!demoMode && (error?.status === 401 || error?.status === 403)) clearApiKey();
    throw error;
  } finally {
    if (isCurrentNavigation(generation)) state.loading = false;
  }
}

async function refreshDashboard(generation = navigationGeneration) {
  if (!isCurrentNavigation(generation)) return false;
  if (demoMode) {
    const nextDashboard = await api.dashboard({ ...state.filters });
    if (!isCurrentNavigation(generation)) return false;
    state.dashboard = nextDashboard;
    return true;
  }
  const nextFilters = { ...state.filters };
  const [rawUsage, rawDevices] = await Promise.all([
    api.dashboard({ start: nextFilters.start, end: nextFilters.end }),
    api.devices(),
  ]);
  if (!isCurrentNavigation(generation)) return false;
  const rawUsers = state.me.role === "admin" ? await api.users() : [state.me];
  if (!isCurrentNavigation(generation)) return false;
  const nextDashboard = adaptUsageDashboard(rawUsage, {
    organization: state.me.organization,
    users: rawUsers,
    devices: rawDevices,
    start: nextFilters.start,
    end: nextFilters.end,
  });
  if (!isCurrentNavigation(generation)) return false;
  state.dashboard = nextDashboard;
  return true;
}

async function loadPage(generation = navigationGeneration) {
  if (!isCurrentNavigation(generation)) return false;
  if (state.me?.role !== "admin" && ADMIN_ONLY_ROUTES.has(state.route.name)) {
    state.route = { name: "overview", id: null };
    history.replaceState(null, "", "#/overview");
  }
  const route = { ...state.route };
  const filters = { ...state.filters };
  state.pageLoading = true;
  state.error = null;
  renderShell();
  try {
    let nextPageData;
    if (!demoMode && route.name === "overview") {
      nextPageData = state.dashboard;
    } else if (!demoMode && route.name === "breakdown") {
      nextPageData = state.dashboard;
    } else if (!demoMode && route.name === "people" && route.id) {
      nextPageData = personDetail(state.dashboard, route.id);
      if (!nextPageData) throw new ApiError("成员不存在或无权访问", { status: 404 });
    } else if (!demoMode && route.name === "people") {
      nextPageData = {
        items: state.dashboard.people,
        batches: state.me?.role === "admin" ? await api.invitationBatches() : [],
      };
    } else if (!demoMode && route.name === "devices") {
      nextPageData = state.dashboard.devices;
    } else if (!demoMode && route.name === "history") {
      nextPageData = { items: state.dashboard.rows };
    } else if (!demoMode && route.name === "costs") {
      nextPageData = await api.pricing();
    } else if (!demoMode && route.name === "settings") {
      nextPageData = normalizeOrganization(await api.organization());
    } else if (route.name === "overview" || route.name === "breakdown") {
      nextPageData = state.dashboard;
    } else if (route.name === "people" && route.id) {
      nextPageData = await api.user(route.id, filters);
    } else if (route.name === "people") {
      const [people, batches] = await Promise.all([
        api.users(filters),
        state.me?.role === "admin" ? api.invitationBatches() : Promise.resolve([]),
      ]);
      nextPageData = {
        items: normalizeCollection(people, ["items", "users"]),
        batches: normalizeCollection(batches, ["items", "batches"]),
      };
    } else if (route.name === "devices") {
      nextPageData = await api.devices(filters);
    } else if (route.name === "history") {
      nextPageData = await api.usage(filters);
    } else if (route.name === "costs") {
      nextPageData = await api.pricing();
    } else if (route.name === "settings") {
      nextPageData = await api.organization();
    }
    if (!isCurrentNavigation(generation)) return false;
    state.pageData = nextPageData;
  } catch (error) {
    if (!isCurrentNavigation(generation)) return false;
    state.error = error;
  } finally {
    if (!isCurrentNavigation(generation)) return false;
    state.pageLoading = false;
    renderShell();
    document.querySelector("#main-content")?.focus({ preventScroll: true });
  }
  return true;
}

function toast(message, type = "success", generation = navigationGeneration) {
  if (!isCurrentNavigation(generation)) return;
  const region = document.querySelector("#toast-region");
  if (!region) return;
  const item = document.createElement("div");
  item.className = `toast toast-${type}`;
  item.textContent = message;
  region.append(item);
  setTimeout(() => { if (isCurrentNavigation(generation)) item.remove(); }, 4200);
}

async function boot(generation = beginNavigation()) {
  if (!isCurrentNavigation(generation)) return;
  const publicRoute = memberRouteFromLocation();
  if (publicRoute) {
    const joinCode = publicRoute.kind === "join" ? takeJoinCode() : "";
    const batchInvitationToken = publicRoute.kind === "batch"
      ? takeBatchInvitationToken()
      : "";
    if (!["join", "batch"].includes(publicRoute.kind)) clearJoinCode();
    if (!isCurrentNavigation(generation)) return;
    communityCleanup = mountCommunityApp({
      root: app,
      route: publicRoute,
      demoMode,
      joinCode,
      batchInvitationToken,
      isCurrent: () => isCurrentNavigation(generation),
    });
    return;
  }
  if (!isCurrentNavigation(generation)) return;
  document.body.classList.remove("community-mode");
  document.title = "TokenFleet · AI 用量账本";
  if (!demoMode && !readApiKey()) {
    if (!isCurrentNavigation(generation)) return;
    renderLogin();
    return;
  }
  if (!isCurrentNavigation(generation)) return;
  app.innerHTML = `<div class="boot-screen"><span class="boot-mark">TF</span><p>正在打开用量账本…</p></div>`;
  try {
    if (!await loadBase(generation) || !isCurrentNavigation(generation)) return;
    await loadPage(generation);
  } catch (error) {
    if (!isCurrentNavigation(generation)) return;
    renderLogin(adminSessionErrorMessage(error));
  }
}

window.addEventListener("hashchange", async () => {
  captureJoinCode();
  const generation = beginNavigation();
  if (memberRouteFromLocation()) {
    await boot(generation);
    return;
  }
  if (!isCurrentNavigation(generation)) return;
  state.route = routeFromLocation();
  if (!demoMode && !readApiKey()) {
    if (!isCurrentNavigation(generation)) return;
    renderLogin();
    return;
  }
  await loadPage(generation);
});

document.addEventListener("submit", async (event) => {
  const form = event.target.closest("form[data-action]");
  if (!form) return;
  const action = form.dataset.action;
  const generation = navigationGeneration;
  event.preventDefault();
  if (form.dataset.pending === "true") return;
  const data = Object.fromEntries(new FormData(form));
  const controls = [...form.querySelectorAll("button,input,select")].map((control) => ({
    control,
    disabled: control.disabled,
  }));
  const submitter = event.submitter;
  const submitterHTML = submitter?.innerHTML;
  form.dataset.pending = "true";
  form.setAttribute("aria-busy", "true");
  controls.forEach(({ control }) => { control.disabled = true; });
  if (submitter) submitter.textContent = "处理中…";

  try {
  if (action === "login") {
    try {
      const result = await api.login({
        org_slug: data.org_slug,
        email: data.email,
        password: data.password,
      });
      if (!isCurrentNavigation(generation)) return;
      saveApiKey(result.access_token);
      await boot();
    } catch (error) {
      if (!isCurrentNavigation(generation)) return;
      clearApiKey();
      renderLogin(adminLoginErrorMessage(error));
    }
  }

  if (action === "change-range") {
    if (data.start > data.end) {
      toast("开始日期不能晚于结束日期", "error");
      return;
    }
    state.filters.start = data.start;
    state.filters.end = data.end;
    try {
      if (!await refreshDashboard(generation) || !isCurrentNavigation(generation)) return;
      await loadPage(generation);
    } catch (error) {
      if (!isCurrentNavigation(generation)) return;
      state.error = error;
      renderShell();
    }
  }

  if (action === "create-invitation-batch") {
    if (event.submitter?.value === "cancel") return;
    try {
      const result = await api.createInvitationBatch({
        capacity: Number(data.capacity),
        expires_in_hours: Number(data.expires_in_hours),
      });
      if (!isCurrentNavigation(generation)) return;
      form.closest("dialog")?.close();
      const nextPage = peoplePageData(state.dashboard.people);
      nextPage.batches = [result.batch, ...nextPage.batches];
      state.pageData = nextPage;
      renderShell();
      showOneTimeBatchInvite(result, generation);
      toast("自助批次已创建；请立即复制链接", "success", generation);
    } catch (error) {
      if (isCurrentNavigation(generation)) toast(error.message, "error", generation);
    }
  }

  if (action === "create-member") {
    if (event.submitter?.value === "cancel") return;
    try {
      const result = await api.createParticipant({
        display_name: String(data.display_name || "").trim(),
        public_profile_enabled: data.public_profile_enabled === "true",
        expires_in_minutes: Number(data.expires_in_minutes),
      });
      if (!isCurrentNavigation(generation)) return;
      form.reset();
      form.closest("dialog")?.close();
      if (!await refreshDashboard(generation) || !isCurrentNavigation(generation)) return;
      state.pageData = peoplePageData(state.dashboard.people);
      renderShell();
      showOneTimeConnection(result, generation);
      toast("参赛者已创建；请立即复制专属接入材料", "success", generation);
    } catch (error) {
      if (isCurrentNavigation(generation)) toast(error.message, "error", generation);
    }
  }

  if (action === "create-enrollment") {
    if (event.submitter?.value === "cancel") return;
    try {
      const result = await api.createEnrollment({ user_id: data.user_id, expires_in_minutes: 60 });
      if (!isCurrentNavigation(generation)) return;
      form.closest("dialog")?.close();
      showOneTimeConnection(result, generation);
      toast("新设备码已生成；旧的未使用有效码已失效，成员数和批次名额未变化", "success", generation);
    } catch (error) {
      if (isCurrentNavigation(generation)) toast(error.message, "error", generation);
    }
  }

  if (action === "save-organization") {
    try {
      const updated = normalizeOrganization(await api.updateOrganization({
        name: data.name,
        timezone: data.timezone,
        retention_days: Number(data.retention_days),
      }));
      if (!isCurrentNavigation(generation)) return;
      state.pageData = updated;
      if (state.me?.organization) state.me.organization = updated;
      toast("社群设置已保存", "success", generation);
      renderShell();
    } catch (error) {
      if (isCurrentNavigation(generation)) toast(error.message, "error", generation);
    }
  }

  if (action === "create-price") {
    try {
      await api.updatePricing({
        tool: String(data.tool || "").trim(),
        model: String(data.model || "").trim(),
        currency: String(data.currency || "").trim().toUpperCase(),
        effective_from: data.effective_from,
        input_per_million: String(data.input_per_million || "").trim(),
        output_per_million: String(data.output_per_million || "").trim(),
        cache_read_per_million: String(data.cache_read_per_million || "").trim(),
        cache_write_per_million: String(data.cache_write_per_million || "").trim(),
        public_estimate: data.public_estimate === "true",
      });
      if (!isCurrentNavigation(generation)) return;
      const nextPricing = await api.pricing();
      if (!isCurrentNavigation(generation)) return;
      state.pageData = nextPricing;
      renderShell();
      toast("价格版本已保存；之后上报将按生效日期匹配", "success", generation);
    } catch (error) {
      if (isCurrentNavigation(generation)) toast(error.message, "error", generation);
    }
  }
  } finally {
    if (!isCurrentNavigation(generation)) return;
    delete form.dataset.pending;
    form.removeAttribute("aria-busy");
    controls.forEach(({ control, disabled }) => { control.disabled = disabled; });
    if (submitter && submitterHTML !== undefined) submitter.innerHTML = submitterHTML;
  }
});

document.addEventListener("click", async (event) => {
  const target = event.target.closest("[data-action]");
  if (!target) return;
  const action = target.dataset.action;
  const generation = navigationGeneration;

  if (action === "toggle-secret") {
    const input = target.parentElement.querySelector("input");
    input.type = input.type === "password" ? "text" : "password";
    target.textContent = input.type === "password" ? "显示" : "隐藏";
  }
  if (action === "logout") {
    const logoutGeneration = beginNavigation();
    clearApiKey();
    clearJoinCode();
    clearPrivateState();
    if (demoMode) location.href = "./";
    else if (isCurrentNavigation(logoutGeneration)) renderLogin();
  }
  if (action === "close-dialog") target.closest("dialog")?.close();
  if (action === "retry") await loadPage(generation);
  if (action === "open-member") document.querySelector("#member-dialog")?.showModal();
  if (action === "open-batch") document.querySelector("#batch-dialog")?.showModal();
  if (action === "open-enrollment") {
    const dialog = document.querySelector("#enrollment-dialog");
    const select = dialog?.querySelector('select[name="user_id"]');
    if (select && target.dataset.userId) select.value = target.dataset.userId;
    dialog?.showModal();
  }
  if (action === "close-invitation-batch") {
    if (target.dataset.pending === "true" || !target.dataset.batchId) return;
    if (!confirm("关闭这个自助批次？尚未领取的人将统一看到“批次不可用”，已生成的个人设备码不受影响。")) return;
    target.dataset.pending = "true";
    target.disabled = true;
    target.setAttribute("aria-busy", "true");
    try {
      const updated = await api.closeInvitationBatch(target.dataset.batchId);
      if (!isCurrentNavigation(generation)) return;
      const nextPage = peoplePageData(state.dashboard.people);
      nextPage.batches = nextPage.batches.map((batch) =>
        batch.id === updated.id ? { ...batch, ...updated } : batch
      );
      state.pageData = nextPage;
      renderShell();
      toast("自助批次已关闭", "success", generation);
    } catch (error) {
      if (!isCurrentNavigation(generation)) return;
      delete target.dataset.pending;
      target.disabled = false;
      target.removeAttribute("aria-busy");
      toast(error.message, "error", generation);
    }
  }
  if (action === "toggle-user") {
    const enabled = target.dataset.enabled === "true";
    const verb = enabled ? "重新启用" : "禁用";
    if (!confirm(`${verb}这名成员？历史数据不会被删除。`)) return;
    target.disabled = true;
    try {
      await api.setUserEnabled(target.dataset.userId, enabled);
      if (!isCurrentNavigation(generation)) return;
      if (!await refreshDashboard(generation) || !isCurrentNavigation(generation)) return;
      state.pageData = personDetail(state.dashboard, target.dataset.userId);
      renderShell();
      toast(`成员已${verb}`, "success", generation);
    } catch (error) {
      if (!isCurrentNavigation(generation)) return;
      target.disabled = false;
      toast(error.message, "error", generation);
    }
  }
  if (action === "toggle-public-profile") {
    if (target.dataset.pending === "true") return;
    if (target.dataset.active !== "true") {
      toast("请先重新启用成员，再开启社群榜", "error");
      return;
    }
    const enabled = target.dataset.enabled === "true";
    target.dataset.pending = "true";
    target.disabled = true;
    target.setAttribute("aria-busy", "true");
    try {
      await api.setUserPublicProfile(target.dataset.userId, enabled);
      if (!isCurrentNavigation(generation)) return;
      if (!await refreshDashboard(generation) || !isCurrentNavigation(generation)) return;
      state.pageData = state.route.id
        ? personDetail(state.dashboard, target.dataset.userId)
        : peoplePageData(state.dashboard.people);
      renderShell();
      toast(enabled ? "已开启匿名社群榜公开资料" : "已从公开榜移除；私有历史未删除", "success", generation);
    } catch (error) {
      if (!isCurrentNavigation(generation)) return;
      delete target.dataset.pending;
      target.disabled = false;
      target.removeAttribute("aria-busy");
      toast(error.message, "error", generation);
    }
  }
  if (action === "toggle-price-public") {
    if (target.dataset.pending === "true" || !target.dataset.priceId) return;
    const enabled = target.dataset.enabled === "true";
    if (enabled && !confirm("允许这个冻结价格版本用于匿名社群榜的 API 等价估算？费率本身不会公开。")) return;
    if (!enabled && !confirm("设为私有后，如果它是该工具/模型最新生效的价格，新用量会在公开榜显示“未定价”，不会沿用旧公开价格。确认继续？")) return;
    target.dataset.pending = "true";
    target.disabled = true;
    target.setAttribute("aria-busy", "true");
    try {
      await api.setPricePublicEstimate(target.dataset.priceId, enabled);
      if (!isCurrentNavigation(generation)) return;
      const nextPricing = await api.pricing();
      if (!isCurrentNavigation(generation)) return;
      state.pageData = nextPricing;
      renderShell();
      toast(enabled ? "该价格版本已允许用于社群榜估算" : "该价格版本已设为私有", "success", generation);
    } catch (error) {
      if (!isCurrentNavigation(generation)) return;
      delete target.dataset.pending;
      target.disabled = false;
      target.removeAttribute("aria-busy");
      toast(error.message, "error", generation);
    }
  }
  if (action === "toggle-device") {
    const enabled = target.dataset.enabled === "true";
    const verb = enabled ? "重新启用" : "禁用";
    if (!confirm(`${verb}这台设备？历史数据不会被删除。`)) return;
    target.disabled = true;
    try {
      await api.setDeviceEnabled(target.dataset.deviceId, enabled);
      if (!isCurrentNavigation(generation)) return;
      if (!await refreshDashboard(generation) || !isCurrentNavigation(generation)) return;
      state.pageData = state.dashboard.devices;
      renderShell();
      toast(`设备已${verb}`, "success", generation);
    } catch (error) {
      if (!isCurrentNavigation(generation)) return;
      target.disabled = false;
      toast(error.message, "error", generation);
    }
  }
});

function showOneTimeConnection(result, generation = navigationGeneration) {
  if (!isCurrentNavigation(generation)) return;
  let rawCode = String(
    result.enrollment_token || result.token || result.enrollment?.token || result.enrollment?.enrollment_token || "",
  );
  if (!rawCode) {
    toast("服务端没有返回一次性连接码", "error", generation);
    return;
  }
  const expiresAt = result.expires_at || result.enrollment?.expires_at || "所选有效期后";
  const masked = "••••••••••••";
  const dialog = document.createElement("dialog");
  dialog.className = "token-dialog";
  dialog.innerHTML = `<div class="dialog-card"><div class="dialog-head"><div><span class="panel-kicker">COPY NOW</span><h2>一次性专属接入</h2></div><button class="icon-button" type="button" data-dialog-close aria-label="关闭">×</button></div><div class="token-copy"><code aria-label="已隐藏的一次性连接码">${escapeHTML(masked)}</code><button class="secondary-button" type="button" data-copy-code>复制连接码</button></div><button class="primary-button" type="button" data-copy-link>复制专属接入链接</button><p>原始连接码不会显示在页面或写入浏览器存储。请立即通过私密渠道发送；接入页只让成员复制连接码到固定官方 TokenFleet 客户端。过期时间：${escapeHTML(expiresAt)}。</p></div>`;
  if (!isCurrentNavigation(generation)) return;
  document.body.append(dialog);
  const joinLink = () => `${location.origin}/join#code=${encodeURIComponent(rawCode)}`;
  dialog.querySelector("[data-dialog-close]").addEventListener("click", () => dialog.close());
  dialog.querySelector("[data-copy-code]").addEventListener("click", async () => {
    await navigator.clipboard.writeText(rawCode);
    if (!isCurrentNavigation(generation)) return;
    toast("连接码已复制", "success", generation);
  });
  dialog.querySelector("[data-copy-link]").addEventListener("click", async () => {
    await navigator.clipboard.writeText(joinLink());
    if (!isCurrentNavigation(generation)) return;
    toast("专属接入链接已复制", "success", generation);
  });
  dialog.addEventListener("close", () => {
    rawCode = "";
    dialog.remove();
  }, { once: true });
  if (isCurrentNavigation(generation)) dialog.showModal();
}

function showOneTimeBatchInvite(result, generation = navigationGeneration) {
  if (!isCurrentNavigation(generation)) return;
  let rawToken = String(result.invitation_token || "");
  if (!/^[A-Za-z0-9_-]{32,256}$/.test(rawToken)) {
    toast("服务端没有返回有效的批次令牌", "error", generation);
    return;
  }
  const batch = result.batch || {};
  const dialog = document.createElement("dialog");
  dialog.className = "token-dialog";
  dialog.innerHTML = `<div class="dialog-card"><div class="dialog-head"><div><span class="panel-kicker">COPY ONCE / SHARE PRIVATELY</span><h2>自助批次链接已生成</h2></div><button class="icon-button" type="button" data-dialog-close aria-label="关闭">×</button></div><div class="batch-link-summary"><strong>${Number(batch.claimed_count || 0)} / ${Number(batch.capacity || 50)}</strong><span>本批已领取 · 有效期至 ${escapeHTML(formatExpiry(batch.expires_at))}</span></div><button class="primary-button" type="button" data-copy-batch-link>复制本批次自助接入链接</button><p>批次令牌不会显示在页面或写入浏览器存储。单批最多 50，可继续创建多个批次进入同一社群；每位成员只会拿到自己的个人设备码。</p><p class="form-note">若链接被外传，可在成员页立即关闭批次；系统对外不会区分已满、已关、过期或无效。</p></div>`;
  if (!isCurrentNavigation(generation)) return;
  document.body.append(dialog);
  const batchLink = () => `${location.origin}/join/batch#invite=${encodeURIComponent(rawToken)}`;
  dialog.querySelector("[data-dialog-close]").addEventListener("click", () => dialog.close());
  dialog.querySelector("[data-copy-batch-link]").addEventListener("click", async () => {
    await navigator.clipboard.writeText(batchLink());
    if (!isCurrentNavigation(generation)) return;
    toast("本批次自助接入链接已复制", "success", generation);
  });
  dialog.addEventListener("close", () => {
    rawToken = "";
    dialog.remove();
  }, { once: true });
  if (isCurrentNavigation(generation)) dialog.showModal();
}

boot();

export { aggregateBy, escapeHTML, formatMoney, formatTokens, routeFromLocation };
