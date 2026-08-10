import assert from "node:assert/strict";
import test from "node:test";
import {
  communityHref,
  formatPublicCost,
  normalizePublicLeaderboard,
  normalizePublicMemberDetail,
  parseCommunityRoute,
} from "../community-contract.js";
import { createCommunityDemoApi } from "../community-demo-data.js";

const exactTotals = {
  input_tokens: "900719925474099312345",
  output_tokens: "7",
  cache_read_tokens: "11",
  cache_write_tokens: "13",
  norm_tokens: "900719925474099312352",
  total_tokens: "900719925474099312376",
  estimated_cost_microunits: "18014398509481988",
  cost_currency: "USD",
  unpriced: false,
  mixed_currency: false,
};

test("frozen public leaderboard contract stays lossless and drops private extras", () => {
  const board = normalizePublicLeaderboard({
    period: "7d",
    metric: "tokens",
    total_entries: 137,
    mixed_timezones: true,
    timezone_warning: "部分数据来自不同的设备本地时区。",
    entries: [
      {
        rank: 1,
        public_id: "safe-public-id",
        nickname: "公开昵称",
        metric_value: "900719925474099312376",
        totals: exactTotals,
        email: "must-not-survive@example.com",
        internal_id: "private-user-id",
        device_id: "private-device-id",
      },
      {
        rank: null,
        public_id: "unpriced",
        nickname: "未定价成员",
        metric_value: null,
        totals: {
          input_tokens: "1",
          output_tokens: "2",
          cache_read_tokens: "3",
          cache_write_tokens: "4",
          norm_tokens: "3",
          total_tokens: "10",
          estimated_cost_microunits: null,
          cost_currency: null,
          unpriced: true,
          mixed_currency: false,
        },
      },
    ],
  });

  assert.equal(board.period, "7d");
  assert.equal(board.metric, "tokens");
  assert.equal(board.totalEntries, 137);
  assert.equal(board.mixedTimezones, true);
  assert.equal(board.timezoneWarning, "部分数据来自不同的设备本地时区。");
  assert.equal(board.participants[0].totalTokens, "900719925474099312376");
  assert.equal(board.participants[0].metricValue, "900719925474099312376");
  assert.equal(board.participants[1].rank, null);
  assert.equal(formatPublicCost(board.participants[1].cost), "未定价");
  assert.equal("email" in board.participants[0], false);
  assert.equal("internal_id" in board.participants[0], false);
  assert.equal("device_id" in board.participants[0], false);
});

test("real PublicMemberDetailResponse nested totals feed non-zero tool/model/trend values", () => {
  const detail = normalizePublicMemberDetail({
    rank: 9,
    public_id: "member-nine",
    nickname: "九号",
    metric_value: exactTotals.total_tokens,
    mixed_timezones: true,
    timezone_warning: "设备本地日桶未跨时区重归日。",
    totals: exactTotals,
    tool_distribution: [
      { name: "Codex", metric_value: "100", totals: { ...exactTotals, total_tokens: "100" } },
    ],
    model_distribution: [
      { name: "gpt-5.2-codex", metric_value: "88", totals: { ...exactTotals, total_tokens: "88" } },
    ],
    daily_trend: [
      { date: "2026-08-09", metric_value: "77", totals: { ...exactTotals, total_tokens: "77" } },
    ],
  });

  assert.equal(detail.tools[0].name, "Codex");
  assert.equal(detail.mixedTimezones, true);
  assert.equal(detail.timezoneWarning, "设备本地日桶未跨时区重归日。");
  assert.equal(detail.tools[0].totalTokens, "900719925474099312376");
  assert.equal(detail.tools[0].normTokens, "900719925474099312352");
  assert.equal(detail.tools[0].metricValue, "100");
  assert.equal(detail.tools[0].cost.amounts[0].microunits, "18014398509481988");
  assert.equal(formatPublicCost(detail.tools[0].cost), "US$18,014,398,509.481988");
  assert.equal(detail.models[0].metricValue, "88");
  assert.equal(detail.dailyTrend[0].metricValue, "77");
  assert.equal(detail.dailyTrend[0].totalTokens, "900719925474099312376");
  assert.equal(detail.dailyTrend[0].normTokens, "900719925474099312352");
  assert.equal(detail.dailyTrend[0].cost.amounts[0].microunits, "18014398509481988");
});

test("/rank is canonical while /community stays a compatible read route", () => {
  assert.equal(parseCommunityRoute({ pathname: "/rank", search: "?metric=norm&period=30d", hash: "" }).kind, "leaderboard");
  assert.equal(parseCommunityRoute({ pathname: "/community", search: "", hash: "" }).kind, "leaderboard");
  assert.equal(parseCommunityRoute({ pathname: "/", search: "", hash: "#/rank/p/demo-1?period=3d" }).publicId, "demo-1");
  assert.equal(parseCommunityRoute({ pathname: "/join", search: "", hash: "" }).kind, "join");
  assert.equal(
    communityHref({ kind: "profile", publicId: "demo-1", filters: { period: "30d", metric: "cost" } }),
    "/rank/p/demo-1?period=30d&metric=cost",
  );
});

test("demo norm distributions use norm_tokens for every tool/model row", async () => {
  const api = createCommunityDemoApi();
  const detail = normalizePublicMemberDetail(await api.member("demo-1", { metric: "norm" }));
  for (const item of [...detail.tools, ...detail.models]) {
    assert.equal(item.metricValue, item.normTokens);
  }
});
