import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  ApiError,
  apiBaseFromDocument,
  clearApiKey,
  createApiClient,
  normalizeCollection,
  parseJsonWithLosslessIntegers,
  readApiKey,
  saveApiKey,
  toQuery,
} from "../api.js";
import { demoApi } from "../demo-data.js";

function memoryStorage() {
  const values = new Map();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
}

function response(payload, status = 200) {
  return new Response(payload === null ? null : JSON.stringify(payload), {
    status,
    headers: payload === null ? {} : { "content-type": "application/json" },
  });
}

test("API base removes trailing slash", () => {
  const fakeDocument = {
    querySelector: () => ({ getAttribute: () => "https://team.example/api/" }),
  };
  assert.equal(apiBaseFromDocument(fakeDocument), "https://team.example/api");
});

test("query omits empty values and encodes timezone", () => {
  assert.equal(
    toQuery({ start: "2026-08-01", timezone: "Asia/Shanghai", user: "" }),
    "?start=2026-08-01&timezone=Asia%2FShanghai",
  );
});

test("JSON parsing preserves unsafe integers as strings without changing safe values", () => {
  const payload = parseJsonWithLosslessIntegers(
    '{"safe":9007199254740991,"unsafe":9007199254740993,"negative":-9007199254740995,"decimal":1.25,"note":"unsafe: 9007199254740993"}',
  );

  assert.equal(payload.safe, 9007199254740991);
  assert.equal(payload.unsafe, "9007199254740993");
  assert.equal(payload.negative, "-9007199254740995");
  assert.equal(payload.decimal, 1.25);
  assert.equal(payload.note, "unsafe: 9007199254740993");
});

test("client keeps extreme row and currency-map microunits lossless", async () => {
  const client = createApiClient({
    getApiKey: () => "",
    fetchImpl: async () => new Response(
      '{"rows":[{"cost_microunits":9007199254740993}],"totals":{"priced_costs_microunits":{"USD":18014398509481988}}}',
      { headers: { "content-type": "application/json" } },
    ),
  });

  const payload = await client.dashboard();
  assert.equal(payload.rows[0].cost_microunits, "9007199254740993");
  assert.equal(payload.totals.priced_costs_microunits.USD, "18014398509481988");
});

test("API key lives in supplied session-like storage", () => {
  const storage = memoryStorage();
  saveApiKey("  tf_live_test  ", storage);
  assert.equal(readApiKey(storage), "tf_live_test");
  clearApiKey(storage);
  assert.equal(readApiKey(storage), "");
  assert.throws(() => saveApiKey("  ", storage), /不能为空/);
});

test("client sends bearer key and stable query", async () => {
  const requests = [];
  const client = createApiClient({
    baseUrl: "https://team.example",
    getApiKey: () => "tf_test_key",
    fetchImpl: async (url, options) => {
      requests.push({ url, options });
      return response({ totals: {} });
    },
  });
  await client.dashboard({ start: "2026-08-01", end: "2026-08-09" });
  assert.equal(requests[0].url, "https://team.example/api/v1/dashboard?start_date=2026-08-01&end_date=2026-08-09");
  assert.equal(requests[0].options.headers.get("Authorization"), "Bearer tf_test_key");
  assert.equal(requests[0].options.headers.get("Accept"), "application/json");
});

test("HTTP errors preserve status without exposing credentials", async () => {
  const client = createApiClient({
    getApiKey: () => "private-value",
    fetchImpl: async () => response({ detail: { code: "forbidden", message: "无权访问" } }, 403),
  });
  await assert.rejects(client.me(), (error) => {
    assert.ok(error instanceof ApiError);
    assert.equal(error.status, 403);
    assert.equal(error.code, "forbidden");
    assert.equal(error.message, "无权访问");
    assert.equal(error.message.includes("private-value"), false);
    return true;
  });
});

test("login, member, enrollment and device status use the server contract", async () => {
  const requests = [];
  const client = createApiClient({
    baseUrl: "https://team.example",
    getApiKey: () => "",
    fetchImpl: async (url, options) => {
      requests.push({ url, options, body: options.body ? JSON.parse(options.body) : null });
      return response(url.endsWith("/auth/token") ? { access_token: "jwt", token_type: "bearer", expires_in: 3600 } : {});
    },
  });
  await client.login({ org_slug: "alpha", email: "a@example.com", password: "secret-pass" });
  await client.createUser({
    email: "member@example.com",
    password: "temporary-password",
    display_name: "成员",
    role: "member",
  });
  await client.setUserEnabled("user-id", false);
  await client.createEnrollment({ user_id: "user-id", expires_in_minutes: 60, label: "not-sent" });
  await client.setDeviceEnabled("device-id", false);
  await client.updatePricing({
    tool: "Codex",
    model: "gpt-reviewed",
    currency: "USD",
    effective_from: "2026-08-09",
    input_per_million: "1.00000001",
    output_per_million: "2.5",
    cache_read_per_million: "0.125",
    cache_write_per_million: "1.25",
  });
  assert.deepEqual(requests[0].body, {
    org_slug: "alpha",
    email: "a@example.com",
    password: "secret-pass",
  });
  assert.deepEqual(requests[1].body, {
    email: "member@example.com",
    password: "temporary-password",
    display_name: "成员",
    role: "member",
  });
  assert.equal(requests[1].url, "https://team.example/api/v1/users");
  assert.deepEqual(requests[2].body, { is_active: false });
  assert.equal(requests[2].url, "https://team.example/api/v1/users/user-id");
  assert.deepEqual(requests[3].body, { user_id: "user-id", expires_in_minutes: 60 });
  assert.deepEqual(requests[4].body, { is_active: false });
  assert.equal(requests[5].url, "https://team.example/api/v1/pricing");
  assert.equal(requests[5].options.method, "POST");
  assert.deepEqual(requests[5].body, {
    tool: "Codex",
    model: "gpt-reviewed",
    currency: "USD",
    effective_from: "2026-08-09",
    input_per_million: "1.00000001",
    output_per_million: "2.5",
    cache_read_per_million: "0.125",
    cache_write_per_million: "1.25",
  });
});

test("network errors become a user-readable ApiError", async () => {
  const client = createApiClient({
    getApiKey: () => "",
    fetchImpl: async () => {
      throw new TypeError("socket closed");
    },
  });
  await assert.rejects(client.me(), (error) => {
    assert.ok(error instanceof ApiError);
    assert.equal(error.code, "network_error");
    assert.match(error.message, /无法连接/);
    return true;
  });
});

test("collection normalizer accepts supported envelopes only", () => {
  assert.deepEqual(normalizeCollection([1, 2]), [1, 2]);
  assert.deepEqual(normalizeCollection({ items: [3] }, ["items"]), [3]);
  assert.deepEqual(normalizeCollection({ items: "wrong" }, ["items"]), []);
  assert.deepEqual(normalizeCollection(null, ["items"]), []);
});

test("demo data is deterministic and internally balanced", async () => {
  const [first, second] = await Promise.all([demoApi.dashboard(), demoApi.dashboard()]);
  assert.deepEqual(first, second);
  const seriesTotal = first.series.reduce((sum, item) => sum + item.total_tokens, 0);
  assert.equal(seriesTotal, first.totals.total_tokens);
  const toolTotal = first.by_tool.reduce((sum, item) => sum + item.total_tokens, 0);
  assert.ok(Math.abs(toolTotal - seriesTotal) <= first.by_tool.length);
  assert.equal(first.devices.length, 8);
  assert.ok(first.people.every((person) => person.primary_tool && person.primary_model));
  assert.ok(first.people.every((person) => person.cache_tokens > 0));
  assert.deepEqual(
    first.people.map((person) => person.total_tokens),
    first.people.map((person) => person.total_tokens).toSorted((left, right) => right - left),
  );
});

test("web source never stores API keys in localStorage or accepts Shengcai secrets", async () => {
  const [appSource, apiSource, html] = await Promise.all([
    readFile(new URL("../app.js", import.meta.url), "utf8"),
    readFile(new URL("../api.js", import.meta.url), "utf8"),
    readFile(new URL("../index.html", import.meta.url), "utf8"),
  ]);
  const combined = `${appSource}\n${apiSource}\n${html}`;
  assert.equal(combined.includes("localStorage"), false);
  assert.equal(/name=["'](?:webhook|shengcai|opentoken|device_secret)/i.test(combined), false);
  assert.match(appSource, /不接收、不保存、也不转发/);
});

test("member entry and public navigation never expose the administrator console", async () => {
  const [appSource, publicSource, communitySource, html, adminHtml] = await Promise.all([
    readFile(new URL("../app.js", import.meta.url), "utf8"),
    readFile(new URL("../public-app.js", import.meta.url), "utf8"),
    readFile(new URL("../community-app.js", import.meta.url), "utf8"),
    readFile(new URL("../index.html", import.meta.url), "utf8"),
    readFile(new URL("../admin/index.html", import.meta.url), "utf8"),
  ]);

  assert.match(appSource, /pathname === "\/admin"/);
  assert.match(appSource, /这里是管理员入口，仅限管理员；普通成员无需在此操作。[\s\S]*成员批次邀请、一次性设备码和成员昵称不能在此使用/);
  assert.match(appSource, /href="\/install"[\s\S]*href="\/rank"/);
  assert.match(appSource, /管理员登录信息不正确/);
  assert.equal(appSource.includes("invalid credentials"), false);
  assert.match(publicSource, /parseCommunityRoute\(location\) \|\| \{ kind: "install" \}/);
  assert.match(publicSource, /history\.replaceState\(null, "", `\/install\$\{location\.search\}`\)/);
  assert.equal(/管理员|\/admin/.test(publicSource), false);
  assert.equal(communitySource.includes("管理员后台"), false);
  assert.equal(communitySource.includes('href="/admin'), false);
  assert.match(communitySource, /随机设备 ID、平台、App／采集器版本、时区和统计完整性/);
  assert.equal(communitySource.includes("不上传提示词、回复、代码、文件、项目路径、邮箱或设备详情"), false);
  assert.equal(html.includes("管理员后台"), false);
  assert.equal(/社群标识|邮箱|密码|验证并进入/.test(html), false);
  assert.match(html, /src="\/public-app\.js/);
  assert.equal(html.includes("/app.js"), false);
  assert.match(adminHtml, /管理员入口/);
  assert.match(adminHtml, /<meta name="robots" content="noindex,nofollow"/);
  assert.match(adminHtml, /src="\/app\.js/);
});

test("cost UI labels currencies explicitly and dialog cancel buttons close without submitting", async () => {
  const appSource = await readFile(new URL("../app.js", import.meta.url), "utf8");

  assert.match(appSource, /normalizePriceRows\(pricing\)/);
  assert.match(appSource, /<th>币种<\/th>/);
  assert.match(appSource, /<th>生效日期<\/th>/);
  assert.match(appSource, /item\.effective_from/);
  assert.match(appSource, /formatMoney\(item\.input_per_million, currency\)/);
  const closeControls = appSource.match(/<button[^>]*data-action="close-dialog"[^>]*>/g) || [];
  assert.equal(closeControls.length, 6);
  closeControls.forEach((control) => assert.match(control, /type="button"/));
  assert.match(appSource, /if \(action === "close-dialog"\) target\.closest\("dialog"\)\?\.close\(\);/);
});

test("unauthenticated hash navigation stays on the login screen", async () => {
  const appSource = await readFile(new URL("../app.js", import.meta.url), "utf8");
  assert.match(
    appSource,
    /hashchange[\s\S]*!demoMode && !readApiKey\(\)[\s\S]*renderLogin\(\)[\s\S]*return;/,
  );
});

test("token UI keeps BigInt values until the chart ratio boundary", async () => {
  const appSource = await readFile(new URL("../app.js", import.meta.url), "utf8");

  assert.match(appSource, /return formatTokenCount\(value, \{ compact \}\);/);
  assert.match(appSource, /tokenRatio\(item\.total_tokens, max\)/);
  assert.match(appSource, /tokenRatio\(value, max\)/);
  assert.equal(
    /Number\((?:item|row|person|device|totals)\.(?:total_tokens|input_tokens|output_tokens|cache_read_tokens|cache_write_tokens)/.test(appSource),
    false,
  );
});

test("initial usage range is recalculated after the organization timezone is known", async () => {
  const appSource = await readFile(new URL("../app.js", import.meta.url), "utf8");

  assert.equal(appSource.includes("toISOString().slice(0, 10)"), false);
  assert.match(
    appSource,
    /const organization = normalizeOrganization\(rawOrganization\);[\s\S]*const nextRange = dateRangeForTimezone\(organization\.default_timezone\);[\s\S]*api\.dashboard\(\{ start: nextFilters\.start, end: nextFilters\.end \}\)/,
  );
});

test("global navigation generation gates admin/public loads, mutations, dialogs and logout", async () => {
  const appSource = await readFile(new URL("../app.js", import.meta.url), "utf8");

  assert.match(appSource, /let navigationGeneration = 0;/);
  assert.match(appSource, /function beginNavigation\(\)[\s\S]*navigationGeneration \+= 1;[\s\S]*cleanup\?\.\(\)/);
  assert.match(appSource, /async function loadBase\(generation\)[\s\S]*isCurrentNavigation\(generation\)/);
  assert.match(appSource, /async function loadPage\(generation = navigationGeneration\)[\s\S]*const route = \{ \.\.\.state\.route \};[\s\S]*isCurrentNavigation\(generation\)/);
  assert.match(appSource, /const generation = navigationGeneration;[\s\S]*createEnrollment[\s\S]*if \(!isCurrentNavigation\(generation\)\) return;[\s\S]*showOneTimeConnection\(result, generation\)/);
  assert.match(appSource, /if \(action === "logout"\) \{[\s\S]*beginNavigation\(\);[\s\S]*renderLogin/);
  assert.match(appSource, /function clearPrivateState\(\)[\s\S]*state\.me = null;[\s\S]*state\.dashboard = null;[\s\S]*state\.pageData = null;/);
  assert.match(appSource, /if \(action === "logout"\) \{[\s\S]*clearApiKey\(\);[\s\S]*clearJoinCode\(\);[\s\S]*clearPrivateState\(\);/);
  assert.match(appSource, /people\.filter\(\(person\) => person\.status === "active" && person\.role === "member"\)/);
});

test("overview, cost, and member estimates use explicit unpriced-aware summaries", async () => {
  const appSource = await readFile(new URL("../app.js", import.meta.url), "utf8");

  assert.match(appSource, /const estimate = formatCostBreakdown\(totals\);/);
  assert.match(appSource, /formatCostBreakdown\(person\)/);
  assert.match(appSource, /return formatCostSummary\(summary\);/);
  assert.equal(/formatCostBreakdown\([^)]*estimated_cost/.test(appSource), false);
});

test("community overview exposes a cost-oriented usage ranking with model and cache context", async () => {
  const appSource = await readFile(new URL("../app.js", import.meta.url), "utf8");

  assert.match(appSource, /<h2>社群用量榜<\/h2>/);
  assert.match(appSource, /主力工具 \/ 模型/);
  assert.match(appSource, /person\.primary_tool/);
  assert.match(appSource, /person\.primary_model/);
  assert.match(appSource, /person\.cache_tokens/);
  assert.match(appSource, /member-state/);
  assert.match(appSource, /已禁用/);
  assert.match(appSource, /不代表工作量、产出或绩效/);
});

test("member navigation hides and redirects admin-only pricing", async () => {
  const appSource = await readFile(new URL("../app.js", import.meta.url), "utf8");

  assert.match(appSource, /const ADMIN_ONLY_ROUTES = new Set\(\["costs"\]\);/);
  assert.match(appSource, /state\.me\?\.role === "admin" \|\| !ADMIN_ONLY_ROUTES\.has\(key\)/);
  assert.match(appSource, /aria-label="\$\{escapeHTML\(label\)\}" title="\$\{escapeHTML\(label\)\}"/);
  assert.match(
    appSource,
    /state\.me\?\.role !== "admin" && ADMIN_ONLY_ROUTES\.has\(state\.route\.name\)[\s\S]*history\.replaceState\(null, "", "#\/overview"\)/,
  );
});

test("async forms block duplicate submissions and expose a busy state", async () => {
  const appSource = await readFile(new URL("../app.js", import.meta.url), "utf8");

  assert.match(appSource, /if \(form\.dataset\.pending === "true"\) return;/);
  assert.match(appSource, /form\.setAttribute\("aria-busy", "true"\);/);
  assert.match(appSource, /controls\.forEach\(\(\{ control \}\) => \{ control\.disabled = true; \}\);/);
  assert.match(appSource, /finally \{[\s\S]*delete form\.dataset\.pending;[\s\S]*control\.disabled = disabled;/);
});

test("admins can create verified price versions without bundled price guesses", async () => {
  const appSource = await readFile(new URL("../app.js", import.meta.url), "utf8");

  assert.match(appSource, /data-action="create-price"/);
  assert.match(appSource, /供应商公开价格或实际合同自行核验后录入/);
  assert.match(appSource, /不预填“当前官方价”/);
  assert.match(appSource, /已有未定价明细不会自动重算/);
  assert.match(appSource, /await api\.updatePricing\(/);
  assert.match(appSource, /latestPrivatePriceVersions\(items\)/);
  assert.match(appSource, /新用量会在公开榜显示“未定价”/);
  assert.match(appSource, /currency: String\(data\.currency/);
  assert.match(appSource, /\.toUpperCase\(\)/);
  assert.match(appSource, /input_per_million: String\(data\.input_per_million/);
  assert.equal(/name="(?:input|output|cache_read|cache_write)_per_million"[^>]*value=/.test(appSource), false);
});
