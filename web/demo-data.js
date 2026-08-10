const DAY = 86_400_000;

async function pauseForDemoScenario(name) {
  const params = new URLSearchParams(String(globalThis.location?.search || "").replace(/^\?/, ""));
  if (params.get("scenario") === name) {
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
}
const anchor = new Date("2026-08-09T00:00:00+08:00");

const people = [
  { id: "u-demo-admin", public_id: "demo-admin", name: "演示·管理员", email: "admin@demo.invalid", can_login: true, role: "admin", public_profile_enabled: false, device_count: 3, status: "active" },
  { id: "u-demo-a", public_id: "demo-a", name: "演示·蓝鲸", email: "member-a@demo.invalid", can_login: true, role: "member", public_profile_enabled: false, device_count: 2, status: "active" },
  { id: "u-demo-b", public_id: "demo-b", name: "演示·云帆", email: "member-b@demo.invalid", can_login: true, role: "member", public_profile_enabled: true, device_count: 1, status: "active" },
  { id: "u-demo-c", public_id: "demo-c", name: "演示·星河", email: "member-c@demo.invalid", can_login: true, role: "member", public_profile_enabled: false, device_count: 2, status: "active" },
];

const toolMix = [
  ["Codex", 0.78],
  ["Claude Code", 0.2],
  ["CC Switch", 0.02],
];

const modelMix = [
  ["gpt-5-codex", 0.52, "Codex"],
  ["gpt-5", 0.26, "Codex"],
  ["claude-opus-4-1", 0.14, "Claude Code"],
  ["claude-sonnet-4", 0.08, "Claude Code"],
];

function dateAt(offset) {
  return new Date(anchor.getTime() - offset * DAY).toISOString().slice(0, 10);
}

const series = Array.from({ length: 30 }, (_, reverseIndex) => {
  const offset = 29 - reverseIndex;
  const wave = Math.sin(reverseIndex * 0.72) * 48_000_000;
  const weekday = [0, 6].includes(new Date(anchor.getTime() - offset * DAY).getDay()) ? 0.55 : 1;
  const total = Math.max(
    12_000_000,
    Math.round((210_000_000 + reverseIndex * 6_800_000 + wave) * weekday),
  );
  return { date: dateAt(offset), total_tokens: total };
});

const totalTokens = series.reduce((sum, day) => sum + day.total_tokens, 0);

const demoDevices = [
  ["d-demo-a1", "u-demo-admin", "MacBook Pro · 主力", 0],
  ["d-demo-a2", "u-demo-admin", "Mac Studio · 办公室", 0],
  ["d-demo-a3", "u-demo-admin", "MacBook Air · 出差", 2],
  ["d-demo-b1", "u-demo-a", "MacBook Pro", 0],
  ["d-demo-b2", "u-demo-a", "Mac mini", 1],
  ["d-demo-c1", "u-demo-b", "MacBook Air", 0],
  ["d-demo-d1", "u-demo-c", "Mac Studio", 0],
  ["d-demo-d2", "u-demo-c", "MacBook Pro", 5],
].map(([id, userId, label, hoursAgo], index) => ({
  id,
  user_id: userId,
  user_name: people.find((item) => item.id === userId)?.name,
  label,
  platform: "macOS",
  app_version: index % 3 === 0 ? "0.2.0" : "0.1.48",
  collector_version: "0.2.0",
  enabled: true,
  last_seen_at: new Date(anchor.getTime() + 12 * 3_600_000 - hoursAgo * 3_600_000).toISOString(),
  total_tokens: Math.round(totalTokens * (0.06 + (index % 4) * 0.021)),
}));

const primaryUsage = [
  ["Codex", "gpt-5-codex"],
  ["Codex", "gpt-5"],
  ["Claude Code", "claude-opus-4-1"],
  ["Codex", "gpt-5-codex"],
];

const demoPeople = people.map((person, index) => {
  const total = Math.round(totalTokens * [0.42, 0.24, 0.13, 0.21][index]);
  const cacheTokens = Math.round(total * [0.79, 0.74, 0.63, 0.81][index]);
  return {
    ...person,
    total_tokens: total,
    norm_tokens: total - cacheTokens,
    cache_tokens: cacheTokens,
    primary_tool: primaryUsage[index][0],
    primary_model: primaryUsage[index][1],
    estimated_cost: Number((total * 0.00000115).toFixed(2)),
    last_seen_at: demoDevices.find((device) => device.user_id === person.id)?.last_seen_at,
  };
}).sort((left, right) => right.total_tokens - left.total_tokens);

function makeHistory() {
  return series
    .slice()
    .reverse()
    .flatMap((day, dayIndex) =>
      modelMix.map(([model, ratio, tool], modelIndex) => {
        const tokens = Math.round(day.total_tokens * ratio);
        const input = Math.round(tokens * 0.08);
        const output = Math.round(tokens * 0.04);
        const cacheWrite = Math.round(tokens * 0.03);
        return {
          id: `${day.date}-${model}`,
          date: day.date,
          timezone: "Asia/Shanghai",
          tool,
          model,
          device_id: demoDevices[(dayIndex + modelIndex) % demoDevices.length].id,
          device_label: demoDevices[(dayIndex + modelIndex) % demoDevices.length].label,
          input_tokens: input,
          output_tokens: output,
          cache_write_tokens: cacheWrite,
          cache_read_tokens: Math.max(0, tokens - input - output - cacheWrite),
          total_tokens: tokens,
          completeness: "exact",
        };
      }),
    );
}

export const demoApi = {
  async me() {
    return {
      id: "u-demo-admin",
      name: "演示·管理员",
      email: "admin@demo.invalid",
      role: "admin",
      organization: { id: "org-demo", name: "示例 AI 工作室", timezone: "Asia/Shanghai" },
    };
  },
  async dashboard() {
    return {
      organization: {
        id: "org-demo",
        name: "示例 AI 工作室",
        timezone: "Asia/Shanghai",
        retention_days: 365,
      },
      range: { start: series[0].date, end: series.at(-1).date, timezone: "Asia/Shanghai" },
      totals: {
        total_tokens: totalTokens,
        norm_tokens: Math.round(totalTokens * 0.13),
        estimated_cost: Number((totalTokens * 0.00000115).toFixed(2)),
        active_members: 4,
        active_devices: 8,
      },
      series,
      by_tool: toolMix.map(([name, ratio]) => ({ name, total_tokens: Math.round(totalTokens * ratio) })),
      by_model: modelMix.map(([name, ratio, tool]) => ({ name, tool, total_tokens: Math.round(totalTokens * ratio) })),
      people: demoPeople,
      devices: demoDevices,
    };
  },
  async usage() {
    return { items: makeHistory(), total: series.length * modelMix.length };
  },
  async users() {
    return { items: demoPeople };
  },
  async createUser(payload) {
    const user = {
      id: `u-demo-${demoPeople.length + 1}`,
      name: payload.display_name || payload.email,
      email: payload.email,
      role: payload.role || "member",
      status: "active",
      device_count: 0,
      total_tokens: 0,
      estimated_cost: 0,
      last_seen_at: null,
    };
    demoPeople.push(user);
    return user;
  },
  async createParticipant(payload) {
    const number = demoPeople.length + 1;
    const user = {
      id: `u-demo-${number}`,
      public_id: `demo-${number}`,
      name: payload.display_name,
      email: "",
      can_login: false,
      public_profile_enabled: payload.public_profile_enabled === true,
      role: "member",
      status: "active",
      device_count: 0,
      total_tokens: 0,
      cache_tokens: 0,
      estimated_cost: null,
      unpriced_rows: 0,
      last_seen_at: null,
    };
    demoPeople.push(user);
    return {
      participant: user,
      enrollment_token: `demo_once_${number}_7Yp4_K2m9_A8q6_H3v5_N1s7`,
      expires_at: new Date(anchor.getTime() + Number(payload.expires_in_minutes || 1440) * 60_000).toISOString(),
    };
  },
  async setUserEnabled(id, enabled) {
    const user = demoPeople.find((item) => item.id === id);
    if (user) user.status = enabled ? "active" : "disabled";
    return user;
  },
  async setUserPublicProfile(id, enabled) {
    const user = demoPeople.find((item) => item.id === id);
    if (user && user.status !== "disabled") user.public_profile_enabled = enabled === true;
    return user;
  },
  async user(id) {
    const user = demoPeople.find((item) => item.id === id) || demoPeople[0];
    return {
      ...user,
      devices: demoDevices.filter((item) => item.user_id === user.id),
      usage: makeHistory().filter((item) =>
        demoDevices.some((device) => device.id === item.device_id && device.user_id === user.id),
      ),
    };
  },
  async devices() {
    return { items: demoDevices };
  },
  async setDeviceEnabled(id, enabled) {
    const device = demoDevices.find((item) => item.id === id);
    if (device) device.enabled = enabled;
    return device;
  },
  async createEnrollment(payload) {
    await pauseForDemoScenario("slow-enrollment");
    return {
      id: "enroll-demo",
      user_id: payload.user_id,
      token: "demo_once_7Yp4_K2m9_A8q6_H3v5_N1s7",
      expires_at: new Date(anchor.getTime() + DAY).toISOString(),
    };
  },
  async pricing() {
    await pauseForDemoScenario("slow-admin");
    return {
      version: "2026-08-demo",
      currency: "USD",
      items: modelMix.map(([model, , tool], index) => ({
        id: `price-${index + 1}`,
        model,
        tool,
        public_estimate: index < 2,
        input_per_million: [1.25, 1.25, 15, 3][index],
        output_per_million: [10, 10, 75, 15][index],
        cache_read_per_million: [0.125, 0.125, 1.5, 0.3][index],
        cache_write_per_million: [1.25, 1.25, 18.75, 3.75][index],
      })),
    };
  },
  async updatePricing(payload) {
    return payload;
  },
  async setPricePublicEstimate(id, enabled) {
    return { id, public_estimate: enabled === true };
  },
  async organization() {
    return {
      id: "org-demo",
      name: "示例 AI 工作室",
      timezone: "Asia/Shanghai",
      retention_days: 365,
    };
  },
  async updateOrganization(payload) {
    return { id: "org-demo", name: "示例 AI 工作室", ...payload };
  },
};
