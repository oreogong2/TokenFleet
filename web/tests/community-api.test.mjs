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
  await client.claimInvitationBatch({
    invitation_token: "Batch_0123456789-abcdefghijklmnop",
    display_name: "  昵称  ",
    public_profile_enabled: true,
  });
  await client.redeemCommunityShareGrant("demo_community_share_grant_0123456789_abcdefghijklmnop");

  assert.equal(PUBLIC_API_PATHS.leaderboard, "/api/v1/public/leaderboard");
  assert.equal(PUBLIC_API_PATHS.member, "/api/v1/public/members");
  assert.equal(PUBLIC_API_PATHS.batchClaim, "/api/v1/public/invitation-batches/claim");
  assert.equal(PUBLIC_API_PATHS.shareGrantRedeem, "/api/v1/public/community-share-grants/redeem");
  assert.equal(
    requests[0].url,
    "https://team.example/api/v1/public/leaderboard?period=90d&metric=norm&tool=Kimi+CLI&model=kimi-k2&limit=100",
  );
  assert.equal(
    requests[1].url,
    "https://team.example/api/v1/public/members/member-1?period=yesterday&metric=cost",
  );
  assert.equal(requests[2].url, "https://team.example/api/v1/public/invitation-batches/claim");
  assert.equal(requests[2].options.method, "POST");
  assert.deepEqual(JSON.parse(requests[2].options.body), {
    invitation_token: "Batch_0123456789-abcdefghijklmnop",
    display_name: "昵称",
    public_profile_enabled: true,
  });
  assert.equal(requests[3].url, "https://team.example/api/v1/public/community-share-grants/redeem");
  assert.equal(requests[3].options.method, "POST");
  assert.deepEqual(JSON.parse(requests[3].options.body), {
    grant: "demo_community_share_grant_0123456789_abcdefghijklmnop",
  });
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
      requests.push({
        url,
        method: options.method,
        body: options.body ? JSON.parse(options.body) : null,
      });
      return jsonResponse({});
    },
  });

  await client.createParticipant({ display_name: "昵称", public_profile_enabled: false, expires_in_minutes: 1440 });
  await client.setUserPublicProfile("user-1", true);
  await client.setPricePublicEstimate("price-1", false);
  await client.createInvitationBatch({ capacity: 50, expires_in_hours: 24 });
  await client.closeInvitationBatch("batch-1");

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
    {
      url: "https://team.example/api/v1/admin/invitation-batches",
      method: "POST",
      body: { capacity: 50, expires_in_hours: 24 },
    },
    {
      url: "https://team.example/api/v1/admin/invitation-batches/batch-1/close",
      method: "POST",
      body: null,
    },
  ]);
});
