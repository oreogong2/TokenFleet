const API_KEY_STORAGE = "tokenfleet.apiKey";

export class ApiError extends Error {
  constructor(message, { status = 0, code = "network_error", details = null } = {}) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

export function apiBaseFromDocument(documentRef = globalThis.document) {
  if (!documentRef) return "";
  const configured = documentRef
    .querySelector('meta[name="tokenfleet-api-base"]')
    ?.getAttribute("content")
    ?.trim();
  return configured ? configured.replace(/\/$/, "") : "";
}

export function readApiKey(storage = sessionStorage) {
  return storage.getItem(API_KEY_STORAGE) || "";
}

export function saveApiKey(value, storage = sessionStorage) {
  const normalized = String(value || "").trim();
  if (!normalized) {
    throw new Error("API Key 不能为空");
  }
  storage.setItem(API_KEY_STORAGE, normalized);
}

export function clearApiKey(storage = sessionStorage) {
  storage.removeItem(API_KEY_STORAGE);
}

export function toQuery(params = {}) {
  const query = new URLSearchParams();
  Object.entries(params).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== "") {
      query.set(key, String(value));
    }
  });
  const value = query.toString();
  return value ? `?${value}` : "";
}

export function parseJsonWithLosslessIntegers(text) {
  let normalized = "";
  let index = 0;
  while (index < text.length) {
    if (text[index] === '"') {
      const start = index;
      index += 1;
      while (index < text.length) {
        if (text[index] === "\\") {
          index += 2;
          continue;
        }
        if (text[index] === '"') {
          index += 1;
          break;
        }
        index += 1;
      }
      normalized += text.slice(start, index);
      continue;
    }

    if (text[index] === "-" || /\d/.test(text[index])) {
      const start = index;
      if (text[index] === "-") index += 1;
      while (/\d/.test(text[index] || "")) index += 1;
      let integerOnly = true;
      if (text[index] === ".") {
        integerOnly = false;
        index += 1;
        while (/\d/.test(text[index] || "")) index += 1;
      }
      if (text[index] === "e" || text[index] === "E") {
        integerOnly = false;
        index += 1;
        if (text[index] === "+" || text[index] === "-") index += 1;
        while (/\d/.test(text[index] || "")) index += 1;
      }
      const token = text.slice(start, index);
      if (integerOnly) {
        const integer = BigInt(token);
        if (integer > BigInt(Number.MAX_SAFE_INTEGER) || integer < -BigInt(Number.MAX_SAFE_INTEGER)) {
          normalized += JSON.stringify(token);
          continue;
        }
      }
      normalized += token;
      continue;
    }

    normalized += text[index];
    index += 1;
  }
  return JSON.parse(normalized);
}

async function parseResponse(response) {
  if (response.status === 204) return null;
  const contentType = response.headers.get("content-type") || "";
  if (!contentType.includes("application/json")) {
    const text = await response.text();
    if (!response.ok) {
      throw new ApiError(text || `请求失败（${response.status}）`, {
        status: response.status,
        code: "http_error",
      });
    }
    return text;
  }
  const payload = parseJsonWithLosslessIntegers(await response.text());
  if (!response.ok) {
    const detail = payload?.detail;
    const message =
      typeof detail === "string"
        ? detail
        : detail?.message || payload?.message || `请求失败（${response.status}）`;
    throw new ApiError(message, {
      status: response.status,
      code: detail?.code || payload?.code || "http_error",
      details: payload,
    });
  }
  return payload;
}

export function createApiClient({
  baseUrl = apiBaseFromDocument(),
  getApiKey = () => readApiKey(),
  fetchImpl = fetch,
} = {}) {
  async function request(path, options = {}) {
    const key = getApiKey();
    const headers = new Headers(options.headers || {});
    headers.set("Accept", "application/json");
    if (key) headers.set("Authorization", `Bearer ${key}`);
    if (options.body && !headers.has("Content-Type")) {
      headers.set("Content-Type", "application/json");
    }

    let response;
    try {
      response = await fetchImpl(`${baseUrl}${path}`, {
        ...options,
        headers,
      });
    } catch (error) {
      throw new ApiError("无法连接 TokenFleet 服务，请检查网络或服务地址。", {
        code: "network_error",
        details: error,
      });
    }
    return parseResponse(response);
  }

  return {
    login: (payload) =>
      request("/api/v1/auth/token", {
        method: "POST",
        body: JSON.stringify(payload),
      }),
    me: () => request("/api/v1/me"),
    dashboard: (params = {}) =>
      request(
        `/api/v1/dashboard${toQuery({
          ...params,
          start: undefined,
          end: undefined,
          start_date: params.start_date || params.start,
          end_date: params.end_date || params.end,
        })}`,
      ),
    usage: (params = {}) =>
      request(
        `/api/v1/usage${toQuery({
          ...params,
          start: undefined,
          end: undefined,
          start_date: params.start_date || params.start,
          end_date: params.end_date || params.end,
        })}`,
      ),
    users: (params) => request(`/api/v1/users${toQuery(params)}`),
    createUser: (payload) =>
      request("/api/v1/users", {
        method: "POST",
        body: JSON.stringify(payload),
      }),
    createParticipant: (payload) =>
      request("/api/v1/admin/participants", {
        method: "POST",
        body: JSON.stringify({
          display_name: payload.display_name,
          public_profile_enabled: payload.public_profile_enabled === true,
          expires_in_minutes: Number(payload.expires_in_minutes),
        }),
      }),
    invitationBatches: () => request("/api/v1/admin/invitation-batches"),
    createInvitationBatch: (payload) =>
      request("/api/v1/admin/invitation-batches", {
        method: "POST",
        body: JSON.stringify({
          capacity: Number(payload.capacity),
          expires_in_hours: Number(payload.expires_in_hours),
        }),
      }),
    closeInvitationBatch: (id) =>
      request(`/api/v1/admin/invitation-batches/${encodeURIComponent(id)}/close`, {
        method: "POST",
      }),
    user: (id, params) =>
      request(`/api/v1/users/${encodeURIComponent(id)}${toQuery(params)}`),
    setUserEnabled: (id, enabled) =>
      request(`/api/v1/users/${encodeURIComponent(id)}`, {
        method: "PATCH",
        body: JSON.stringify({ is_active: enabled }),
      }),
    setUserPublicProfile: (id, enabled) =>
      request(`/api/v1/users/${encodeURIComponent(id)}`, {
        method: "PATCH",
        body: JSON.stringify({ public_profile_enabled: enabled === true }),
      }),
    devices: (params) => request(`/api/v1/devices${toQuery(params)}`),
    setDeviceEnabled: (id, enabled) =>
      request(`/api/v1/devices/${encodeURIComponent(id)}`, {
        method: "PATCH",
        body: JSON.stringify({ is_active: enabled }),
      }),
    createEnrollment: (payload) =>
      request("/api/v1/enrollment-tokens", {
        method: "POST",
        body: JSON.stringify({
          user_id: payload.user_id,
          expires_in_minutes:
            payload.expires_in_minutes || Number(payload.expires_in_hours || 1) * 60,
        }),
      }),
    pricing: () => request("/api/v1/pricing"),
    updatePricing: (payload) =>
      request("/api/v1/pricing", {
        method: "POST",
        body: JSON.stringify(payload),
      }),
    setPricePublicEstimate: (id, enabled) =>
      request(`/api/v1/prices/${encodeURIComponent(id)}`, {
        method: "PATCH",
        body: JSON.stringify({ public_estimate: enabled === true }),
      }),
    organization: () => request("/api/v1/organization"),
    updateOrganization: (payload) =>
      request("/api/v1/organization", {
        method: "PATCH",
        body: JSON.stringify({
          default_timezone: payload.default_timezone || payload.timezone,
          retention_days: payload.retention_days,
          ...(payload.name ? { name: payload.name } : {}),
        }),
      }),
  };
}

export function normalizeCollection(payload, preferredKeys = []) {
  if (Array.isArray(payload)) return payload;
  for (const key of preferredKeys) {
    if (Array.isArray(payload?.[key])) return payload[key];
  }
  return [];
}
