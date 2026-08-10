import assert from "node:assert/strict";
import test from "node:test";
import { createApiClient } from "../api.js";
import { createCommunityApiClient, PUBLIC_API_PATHS } from "../community-api.js";

function jsonResponse(payload) {
  return new Response(JSON.stringify(payload), { headers: { "content-type": "application/json" } });
}

test("anonymous public API uses frozen paths/query and never sends credentials", async () => {
  const requests = [];
  const client = createCommunityApiClient({
    baseUrl: "https://team.example",
    fetchImpl: async (url, options) => {
      requests.push({ url, options });
      return jsonResponse(url.includes("/members/") ? {
        public_id: "member-1",
        nickname: "成员",
        rank: 1,
        metric_value: "3",
        totals: {},
      } : { entries: [] });
    },
  });

  await client.leaderboard({ period: "90d", metric: "norm", tool: "Kimi CLI", model: "kimi-k2" });
  await client.member("member-1", { period: "yesterday", metric: "cost" });

  assert.equal(PUBLIC_API_PATHS.leaderboard, "/api/v1/public/leaderboard");
  assert.equal(PUBLIC_API_PATHS.member, "/api/v1/public/members");
  assert.equal(
    requests[0].url,
    "https://team.example/api/v1/public/leaderboard?period=90d&metric=norm&tool=Kimi+CLI&model=kimi-k2&limit=100",
  );
  assert.equal(
    requests[1].url,
    "https://team.example/api/v1/public/members/member-1?period=yesterday&metric=cost",
  );
  requests.forEach(({ options }) => {
    assert.equal(options.credentials, "omit");
    assert.equal(options.referrerPolicy, "no-referrer");
    assert.equal(new Headers(options.headers).has("Authorization"), false);
  });
});

test("admin participant/public-profile/public-estimate calls submit explicit booleans", async () => {
  const requests = [];
  const client = createApiClient({
    baseUrl: "https://team.example",
    getApiKey: () => "admin-session",
    fetchImpl: async (url, options) => {
      requests.push({ url, method: options.method, body: JSON.parse(options.body) });
      return jsonResponse({});
    },
  });

  await client.createParticipant({ display_name: "昵称", public_profile_enabled: false, expires_in_minutes: 1440 });
  await client.setUserPublicProfile("user-1", true);
  await client.setPricePublicEstimate("price-1", false);

  assert.deepEqual(requests, [
    {
      url: "https://team.example/api/v1/admin/participants",
      method: "POST",
      body: { display_name: "昵称", public_profile_enabled: false, expires_in_minutes: 1440 },
    },
    {
      url: "https://team.example/api/v1/users/user-1",
      method: "PATCH",
      body: { public_profile_enabled: true },
    },
    {
      url: "https://team.example/api/v1/prices/price-1",
      method: "PATCH",
      body: { public_estimate: false },
    },
  ]);
});
