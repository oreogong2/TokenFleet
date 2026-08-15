import {
  ApiError,
  apiBaseFromDocument,
  parseJsonWithLosslessIntegers,
  toQuery,
} from "./api.js";
import { sanitizePublicFilters } from "./community-contract.js";

export const PUBLIC_API_PATHS = Object.freeze({
  leaderboard: "/api/v1/public/leaderboard",
  member: "/api/v1/public/members",
  batchClaim: "/api/v1/public/invitation-batches/claim",
  shareGrantRedeem: "/api/v1/public/community-share-grants/redeem",
});

async function parsePublicResponse(response) {
  const contentType = response.headers.get("content-type") || "";
  if (!contentType.includes("application/json")) {
    const body = await response.text();
    throw new ApiError(response.ok ? "公开接口返回了无法识别的数据" : body || "公开接口请求失败", {
      status: response.status,
      code: "public_http_error",
    });
  }
  const payload = parseJsonWithLosslessIntegers(await response.text());
  if (!response.ok) {
    const detail = payload?.detail;
    throw new ApiError(
      typeof detail === "string" ? detail : detail?.message || payload?.message || "公开接口请求失败",
      { status: response.status, code: detail?.code || payload?.code || "public_http_error" },
    );
  }
  return payload;
}

export function createCommunityApiClient({
  baseUrl = apiBaseFromDocument(),
  fetchImpl = fetch,
  signal,
} = {}) {
  async function request(path, options = {}) {
    let response;
    try {
      const headers = new Headers(options.headers || {});
      headers.set("Accept", "application/json");
      if (options.body) headers.set("Content-Type", "application/json");
      // Anonymous community requests intentionally never read or attach the
      // administrator session token.
      response = await fetchImpl(`${baseUrl}${path}`, {
        ...options,
        headers,
        credentials: "omit",
        referrerPolicy: "no-referrer",
        signal,
      });
    } catch (error) {
      throw new ApiError("暂时无法读取社群榜，请稍后再试。", {
        code: "public_network_error",
        details: error,
      });
    }
    return parsePublicResponse(response);
  }

  return {
    leaderboard(rawFilters = {}) {
      const filters = sanitizePublicFilters(rawFilters);
      return request(`${PUBLIC_API_PATHS.leaderboard}${toQuery({
        period: filters.period,
        metric: filters.metric,
        tool: filters.tool,
        model: filters.model,
        limit: 100,
      })}`);
    },
    member(publicId, rawFilters = {}) {
      const filters = sanitizePublicFilters(rawFilters);
      return request(`${PUBLIC_API_PATHS.member}/${encodeURIComponent(publicId)}${toQuery({
        period: filters.period,
        metric: filters.metric,
        tool: filters.tool,
        model: filters.model,
      })}`);
    },
    claimInvitationBatch(payload) {
      return request(PUBLIC_API_PATHS.batchClaim, {
        method: "POST",
        body: JSON.stringify({
          invitation_token: String(payload.invitation_token || ""),
          display_name: String(payload.display_name || "").trim(),
          public_profile_enabled: payload.public_profile_enabled === true,
        }),
      });
    },
    redeemCommunityShareGrant(grant) {
      return request(PUBLIC_API_PATHS.shareGrantRedeem, {
        method: "POST",
        // The caller only ever obtains this value from the URL fragment.  The
        // fragment is scrubbed before this request, and this anonymous request
        // deliberately creates no browser session or persistent viewer state.
        body: JSON.stringify({ grant: String(grant || "") }),
      });
    },
  };
}
