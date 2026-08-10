import assert from "node:assert/strict";
import test from "node:test";
import {
  aggregateTokenRows,
  adaptUsageDashboard,
  dateRangeForTimezone,
  formatCostSummary,
  formatMicrounitAmount,
  formatTokenCount,
  normalizeDevice,
  normalizeOrganization,
  normalizePriceRows,
  normalizeUser,
  personDetail,
  tokenRatio,
  toTokenBigInt,
} from "../server-adapter.js";

const users = [
  { id: "u1", email: "one@example.com", display_name: "一号", role: "admin", is_active: true },
  { id: "u2", email: "two@example.com", display_name: "二号", role: "member", is_active: true },
];
const devices = [
  { id: "d1", user_id: "u1", device_public_id: "public-1111", is_active: true, last_successful_sync_at: "2026-08-09T01:00:00Z" },
  { id: "d2", user_id: "u1", device_public_id: "public-2222", is_active: true, last_successful_sync_at: "2026-08-09T02:00:00Z" },
  { id: "d3", user_id: "u2", device_public_id: "public-3333", is_active: false, last_successful_sync_at: null },
];
const rows = [
  {
    date: "2026-08-09",
    timezone: "Asia/Shanghai",
    user_id: "u1",
    device_id: "d1",
    tool: "Codex",
    model: "gpt-5",
    source: "local",
    completeness: "exact",
    input_tokens: 10,
    output_tokens: 20,
    cache_read_tokens: 100,
    cache_write_tokens: 5,
    cost_microunits: 250000,
    cost_currency: "USD",
  },
  {
    date: "2026-08-09",
    timezone: "Asia/Shanghai",
    user_id: "u1",
    device_id: "d2",
    tool: "Claude Code",
    model: "claude-opus",
    source: "local",
    completeness: "exact",
    input_tokens: 8,
    output_tokens: 12,
    cache_read_tokens: 40,
    cache_write_tokens: 0,
    cost_microunits: 500000,
    cost_currency: "USD",
  },
];

test("normalizers map server naming without inventing hardware identity", () => {
  assert.equal(normalizeOrganization({ default_timezone: "Asia/Shanghai" }).timezone, "Asia/Shanghai");
  assert.equal(normalizeUser(users[0]).name, "一号");
  const device = normalizeDevice(devices[0], users.map(normalizeUser));
  assert.equal(device.enabled, true);
  assert.equal(device.user_name, "一号");
  assert.equal(device.label, "设备 public-1");
});

test("default date ranges use the organization's local calendar day across UTC boundaries", () => {
  assert.deepEqual(
    dateRangeForTimezone("Asia/Shanghai", new Date("2026-08-09T16:30:00Z")),
    { start: "2026-07-12", end: "2026-08-10", timezone: "Asia/Shanghai" },
  );
  assert.deepEqual(
    dateRangeForTimezone("Asia/Singapore", new Date("2026-08-09T16:30:00Z")),
    { start: "2026-07-12", end: "2026-08-10", timezone: "Asia/Singapore" },
  );
  assert.deepEqual(
    dateRangeForTimezone("America/Los_Angeles", new Date("2026-08-09T00:30:00Z")),
    { start: "2026-07-10", end: "2026-08-08", timezone: "America/Los_Angeles" },
  );
});

test("raw atomic rows become balanced team, person and device summaries", () => {
  const dashboard = adaptUsageDashboard(
    {
      rows,
      totals: {
        input_tokens: 18,
        output_tokens: 32,
        cache_read_tokens: 140,
        cache_write_tokens: 5,
        priced_costs_microunits: { USD: 750000 },
        unpriced_rows: 0,
      },
      organization_timezone: "Asia/Shanghai",
      timezone_warning: null,
    },
    {
      organization: { id: "org", name: "团队", default_timezone: "Asia/Shanghai" },
      users,
      devices,
      start: "2026-08-01",
      end: "2026-08-09",
    },
  );
  assert.equal(dashboard.totals.total_tokens, 195n);
  assert.equal(dashboard.totals.norm_tokens, 50n);
  assert.equal(dashboard.totals.estimated_cost, 0.75);
  assert.equal(dashboard.totals.estimated_cost_currency, "USD");
  assert.deepEqual(dashboard.totals.estimated_costs, { USD: 0.75 });
  assert.deepEqual(dashboard.totals.estimated_costs_microunits, { USD: "750000" });
  assert.equal(dashboard.series[0].total_tokens, 195n);
  assert.equal(dashboard.by_tool.length, 2);
  const person = dashboard.people.find((item) => item.id === "u1");
  assert.equal(person.device_count, 2);
  assert.equal(person.total_tokens, 195n);
  assert.equal(person.norm_tokens, 50n);
  assert.equal(person.cache_read_tokens, 140n);
  assert.equal(person.cache_write_tokens, 5n);
  assert.equal(person.cache_tokens, 145n);
  assert.equal(person.primary_tool, "Codex");
  assert.equal(person.primary_model, "gpt-5");
  assert.deepEqual(person.by_tool.map((item) => item.name), ["Codex", "Claude Code"]);
  assert.deepEqual(person.by_model.map((item) => item.name), ["gpt-5", "claude-opus"]);
  assert.equal(person.estimated_cost, 0.75);
  assert.equal(person.estimated_cost_currency, "USD");
  assert.deepEqual(person.estimated_costs, { USD: 0.75 });
  assert.deepEqual(person.estimated_costs_microunits, { USD: "750000" });
  assert.equal(dashboard.devices.find((item) => item.id === "d1").total_tokens, 135n);
  assert.equal(dashboard.rows.reduce((sum, row) => sum + row.total_tokens, 0n), 195n);
  const detail = personDetail(dashboard, "u1");
  assert.equal(detail.devices.length, 2);
  assert.equal(detail.usage.length, 2);
  assert.equal(personDetail(dashboard, "missing"), null);
  const inactivePerson = dashboard.people.find((item) => item.id === "u2");
  assert.equal(inactivePerson.total_tokens, 0n);
  assert.equal(inactivePerson.cache_tokens, 0n);
  assert.equal(inactivePerson.primary_tool, null);
  assert.equal(inactivePerson.primary_model, null);
});

test("unpriced usage is explicit for organization, member, and device summaries", () => {
  const dashboard = adaptUsageDashboard(
    {
      rows: rows.map((row) => ({
        ...row,
        cost_microunits: null,
        cost_currency: null,
      })),
      totals: {
        input_tokens: 18,
        output_tokens: 32,
        cache_read_tokens: 140,
        cache_write_tokens: 5,
        priced_costs_microunits: {},
        unpriced_rows: 2,
      },
    },
    { users, devices },
  );

  assert.deepEqual(dashboard.totals.estimated_costs, {});
  assert.deepEqual(dashboard.totals.estimated_costs_microunits, {});
  assert.equal(dashboard.totals.estimated_cost, null);
  assert.equal(dashboard.totals.unpriced_rows, 2);
  assert.equal(formatCostSummary(dashboard.totals), "未定价");

  const person = dashboard.people.find((item) => item.id === "u1");
  assert.equal(person.unpriced_rows, 2);
  assert.equal(formatCostSummary(person), "未定价");

  const firstDevice = dashboard.devices.find((item) => item.id === "d1");
  assert.equal(firstDevice.unpriced_rows, 1);
  assert.equal(formatCostSummary(firstDevice), "未定价");
  assert.equal(formatCostSummary({}), "—");
  assert.equal(
    formatCostSummary({ estimated_costs_microunits: { USD: "750000" }, unpriced_rows: 1 }),
    "US$0.75 · 部分未定价",
  );
  assert.equal(formatCostSummary(dashboard.totals).includes("$0"), false);
});

test("a JSON row with four 9e15 token fields aggregates and formats exactly", () => {
  const apiPayload = JSON.parse(JSON.stringify({
    rows: [{
      ...rows[0],
      input_tokens: 9_000_000_000_000_000,
      output_tokens: 9_000_000_000_000_000,
      cache_read_tokens: 9_000_000_000_000_000,
      cache_write_tokens: 9_000_000_000_000_000,
    }],
    totals: {},
  }));
  const dashboard = adaptUsageDashboard(apiPayload, { users, devices });
  const expected = 36_000_000_000_000_000n;

  assert.equal(dashboard.rows[0].input_tokens, 9_000_000_000_000_000n);
  assert.equal(dashboard.rows[0].total_tokens, expected);
  assert.equal(dashboard.totals.total_tokens, expected);
  assert.equal(dashboard.series[0].total_tokens, expected);
  assert.equal(formatTokenCount(expected, { compact: false }), "36,000,000,000,000,000");
  assert.equal(formatTokenCount(expected), "360000000 亿");
});

test("multiple rows are re-aggregated exactly instead of trusting rounded JSON totals", () => {
  const exactInputTotal = 17_999_999_999_999_999n;
  const roundedJsonInputTotal = Number(exactInputTotal);
  assert.notEqual(toTokenBigInt(roundedJsonInputTotal), exactInputTotal);

  const dashboard = adaptUsageDashboard(
    {
      rows: [
        {
          ...rows[0],
          input_tokens: 9_000_000_000_000_000,
          output_tokens: 1,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
        },
        {
          ...rows[1],
          input_tokens: 8_999_999_999_999_999,
          output_tokens: 1,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
        },
      ],
      totals: {
        input_tokens: roundedJsonInputTotal,
        output_tokens: 2,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
      },
    },
    { users, devices },
  );
  const expected = 18_000_000_000_000_001n;

  assert.equal(dashboard.totals.total_tokens, expected);
  assert.equal(dashboard.totals.norm_tokens, expected);
  assert.equal(dashboard.series[0].total_tokens, expected);
  assert.equal(dashboard.people.find((item) => item.id === "u1").total_tokens, expected);
});

test("BigInt aggregation and sorting distinguish adjacent totals beyond Number precision", () => {
  const lower = 17_999_999_999_999_999n;
  const higher = 18_000_000_000_000_000n;
  assert.equal(Number(lower), Number(higher));

  const dashboard = adaptUsageDashboard(
    {
      rows: [
        {
          ...rows[0],
          tool: "Lower",
          model: "lower-model",
          input_tokens: 9_000_000_000_000_000,
          output_tokens: 8_999_999_999_999_999,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
        },
        {
          ...rows[1],
          user_id: "u2",
          device_id: "d3",
          tool: "Higher",
          model: "higher-model",
          input_tokens: 9_000_000_000_000_000,
          output_tokens: 9_000_000_000_000_000,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
        },
      ],
      totals: {},
    },
    { users, devices },
  );

  assert.deepEqual(dashboard.people.map((item) => item.id), ["u2", "u1"]);
  assert.equal(dashboard.people[0].primary_tool, "Higher");
  assert.equal(dashboard.people[0].primary_model, "higher-model");
  assert.equal(dashboard.people[0].cache_tokens, 0n);
  assert.deepEqual(dashboard.by_tool.map((item) => item.name), ["Higher", "Lower"]);
  assert.deepEqual(dashboard.by_model.map((item) => item.name), ["higher-model", "lower-model"]);
  assert.equal(dashboard.by_tool[0].total_tokens, higher);

  const regrouped = aggregateTokenRows(dashboard.rows, "tool");
  assert.deepEqual(regrouped.map((item) => item.name), ["Higher", "Lower"]);
  assert.equal(tokenRatio(lower, higher) >= 0.999999, true);
  assert.equal(tokenRatio(higher, higher), 1);
});

test("member signature keeps the primary model within the primary tool", () => {
  const dashboard = adaptUsageDashboard(
    {
      rows: [
        {
          ...rows[0],
          tool: "Codex",
          model: "gpt-split-a",
          input_tokens: 31,
          output_tokens: 0,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
        },
        {
          ...rows[0],
          device_id: "d2",
          tool: "Codex",
          model: "gpt-split-b",
          input_tokens: 30,
          output_tokens: 0,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
        },
        {
          ...rows[1],
          tool: "Claude Code",
          model: "claude-global-top",
          input_tokens: 40,
          output_tokens: 0,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
        },
      ],
    },
    { users, devices },
  );
  const person = dashboard.people.find((item) => item.id === "u1");

  assert.equal(person.primary_tool, "Codex");
  assert.equal(person.primary_model, "gpt-split-a");
  assert.equal(person.by_model[0].name, "claude-global-top");
});

test("USD and CNY estimates remain separate for the organization and each member", () => {
  const mixedRows = [
    rows[0],
    {
      ...rows[1],
      cost_microunits: 500000,
      cost_currency: "cny",
    },
  ];
  const dashboard = adaptUsageDashboard(
    {
      rows: mixedRows,
      totals: {
        input_tokens: 18,
        output_tokens: 32,
        cache_read_tokens: 140,
        cache_write_tokens: 5,
        priced_costs_microunits: { USD: 250000, CNY: 500000 },
      },
    },
    { users, devices, organization: { default_timezone: "UTC" } },
  );

  assert.deepEqual(dashboard.totals.estimated_costs, { USD: 0.25, CNY: 0.5 });
  assert.equal(dashboard.totals.estimated_cost, null);
  assert.equal(dashboard.totals.estimated_cost_currency, null);

  const person = dashboard.people.find((item) => item.id === "u1");
  assert.deepEqual(person.estimated_costs, { USD: 0.25, CNY: 0.5 });
  assert.equal(person.estimated_cost, null);
  assert.equal(person.estimated_cost_currency, null);
});

test("cost microunits aggregate and format exactly beyond Number safe precision", () => {
  const dashboard = adaptUsageDashboard(
    {
      rows: [
        { ...rows[0], cost_microunits: "9007199254740993", cost_currency: "USD" },
        { ...rows[1], cost_microunits: "9007199254740995", cost_currency: "USD" },
      ],
      totals: {
        priced_costs_microunits: { USD: "18014398509481988" },
        unpriced_rows: 0,
      },
    },
    { users, devices },
  );
  const exactMicrounits = "18014398509481988";
  const exactMajorAmount = "18014398509.481988";

  assert.equal(dashboard.totals.estimated_costs_microunits.USD, exactMicrounits);
  assert.equal(dashboard.totals.estimated_costs.USD, exactMajorAmount);
  assert.equal(dashboard.totals.estimated_cost, exactMajorAmount);
  assert.equal(
    dashboard.people.find((item) => item.id === "u1").estimated_costs_microunits.USD,
    exactMicrounits,
  );
  assert.equal(formatMicrounitAmount(exactMicrounits, "USD"), "US$18,014,398,509.481988");
  assert.equal(formatCostSummary(dashboard.totals), "US$18,014,398,509.481988");
});

test("price rows retain their own currency and use a payload fallback only when absent", () => {
  const prices = normalizePriceRows({
    currency: "usd",
    items: [
      { model: "gpt-priced-in-cny", currency: "cny", input_per_million: 10 },
      { model: "legacy-usd-row", input_per_million: 2 },
    ],
  });

  assert.equal(prices[0].currency, "CNY");
  assert.equal(prices[1].currency, "USD");
  assert.equal(prices[0].input_per_million, 10);
});

test("mixed timezone warning is preserved for the UI", () => {
  const dashboard = adaptUsageDashboard(
    { rows, totals: {}, organization_timezone: "UTC", timezone_warning: "device-local warning" },
    { users, devices, organization: { default_timezone: "UTC" } },
  );
  assert.equal(dashboard.timezone_warning, "device-local warning");
});
