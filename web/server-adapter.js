function number(value) {
  const parsed = Number(value || 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function parseTokenBigInt(value) {
  if (value === null || value === undefined || value === "") return 0n;
  if (typeof value === "bigint") return value;
  if (typeof value === "number") {
    return Number.isFinite(value) && Number.isInteger(value) ? BigInt(value) : null;
  }
  if (typeof value === "string") {
    const normalized = value.trim();
    if (!normalized) return 0n;
    if (!/^-?\d+$/.test(normalized)) return null;
    try {
      return BigInt(normalized);
    } catch {
      return null;
    }
  }
  return null;
}

export function toTokenBigInt(value) {
  return parseTokenBigInt(value) ?? 0n;
}

export function compareTokenValues(left, right) {
  const normalizedLeft = toTokenBigInt(left);
  const normalizedRight = toTokenBigInt(right);
  if (normalizedLeft === normalizedRight) return 0;
  return normalizedLeft < normalizedRight ? -1 : 1;
}

export function tokenRatio(value, maximum) {
  const normalizedValue = toTokenBigInt(value);
  const normalizedMaximum = toTokenBigInt(maximum);
  if (normalizedValue <= 0n || normalizedMaximum <= 0n) return 0;
  if (normalizedValue >= normalizedMaximum) return 1;
  const precision = 1_000_000n;
  return Number((normalizedValue * precision) / normalizedMaximum) / Number(precision);
}

function formatScaledTokenBigInt(value, divisor) {
  const negative = value < 0n;
  const absolute = negative ? -value : value;
  const whole = absolute / divisor;
  const fractionDigits = whole >= 100n ? 0 : whole >= 10n ? 1 : 2;
  const scale = 10n ** BigInt(fractionDigits);
  const rounded = (absolute * scale + divisor / 2n) / divisor;
  const integerPart = rounded / scale;
  const fractionPart = rounded % scale;
  const fraction = fractionDigits
    ? `.${fractionPart.toString().padStart(fractionDigits, "0")}`.replace(/\.?0+$/, "")
    : "";
  return `${negative ? "-" : ""}${integerPart}${fraction}`;
}

export function formatTokenCount(value, { compact = true } = {}) {
  const normalized = parseTokenBigInt(value);
  if (normalized === null) return "—";
  if (!compact) return new Intl.NumberFormat("zh-CN").format(normalized);
  const absolute = normalized < 0n ? -normalized : normalized;
  if (absolute >= 100_000_000n) {
    return `${formatScaledTokenBigInt(normalized, 100_000_000n)} 亿`;
  }
  if (absolute >= 10_000n) {
    return `${formatScaledTokenBigInt(normalized, 10_000n)} 万`;
  }
  return new Intl.NumberFormat("zh-CN").format(normalized);
}

function microunitsToDecimalString(value) {
  const normalized = toTokenBigInt(value);
  const negative = normalized < 0n;
  const absolute = negative ? -normalized : normalized;
  const whole = absolute / 1_000_000n;
  const fraction = (absolute % 1_000_000n)
    .toString()
    .padStart(6, "0")
    .replace(/0+$/, "");
  return `${negative ? "-" : ""}${whole}${fraction ? `.${fraction}` : ""}`;
}

function compatibleMajorAmount(value) {
  const normalized = toTokenBigInt(value);
  const exact = microunitsToDecimalString(normalized);
  return normalized >= -BigInt(Number.MAX_SAFE_INTEGER) &&
    normalized <= BigInt(Number.MAX_SAFE_INTEGER)
    ? Number(exact)
    : exact;
}

export function formatMicrounitAmount(value, currency = "USD") {
  const parsed = parseTokenBigInt(value);
  if (parsed === null) return "—";
  const negative = parsed < 0n;
  const absolute = negative ? -parsed : parsed;
  const whole = absolute / 1_000_000n;
  let fraction = (absolute % 1_000_000n).toString().padStart(6, "0").replace(/0+$/, "");
  fraction = fraction.padEnd(2, "0");
  const decimal = `.${fraction}`;
  const normalizedCurrency = String(currency || "USD").toUpperCase();

  try {
    const parts = new Intl.NumberFormat("zh-CN", {
      style: "currency",
      currency: normalizedCurrency,
      minimumFractionDigits: 0,
      maximumFractionDigits: 0,
    }).formatToParts(whole);
    let lastNumericPart = -1;
    parts.forEach((part, index) => {
      if (part.type === "integer" || part.type === "group") lastNumericPart = index;
    });
    parts.splice(lastNumericPart + 1, 0, { type: "fraction", value: decimal });
    return `${negative ? "-" : ""}${parts.map((part) => part.value).join("")}`;
  } catch {
    const grouped = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 0 }).format(whole);
    return `${negative ? "-" : ""}${normalizedCurrency} ${grouped}${decimal}`;
  }
}

function formatMajorAmount(value, currency = "USD") {
  const numberValue = Number(value);
  if (!Number.isFinite(numberValue)) return "—";
  const normalizedCurrency = String(currency || "USD").toUpperCase();
  try {
    return new Intl.NumberFormat("zh-CN", {
      style: "currency",
      currency: normalizedCurrency,
      maximumFractionDigits: numberValue >= 1000 ? 0 : 2,
    }).format(numberValue);
  } catch {
    return `${normalizedCurrency} ${new Intl.NumberFormat("zh-CN", {
      maximumFractionDigits: 2,
    }).format(numberValue)}`;
  }
}

export function formatCostSummary(summary = {}) {
  const hasUnpricedRows = toTokenBigInt(summary.unpriced_rows) > 0n;
  const microunitEntries = Object.entries(summary.estimated_costs_microunits || {})
    .filter(([, value]) => value !== null && value !== undefined)
    .sort(([left], [right]) => left.localeCompare(right));
  let pricedText = microunitEntries
    .map(([currency, value]) => formatMicrounitAmount(value, currency))
    .join(" · ");

  if (!pricedText) {
    const entries = Object.entries(summary.estimated_costs || {})
      .filter(([, value]) => Number.isFinite(Number(value)))
      .sort(([left], [right]) => left.localeCompare(right));
    pricedText = entries.map(([currency, value]) => formatMajorAmount(value, currency)).join(" · ");
  }

  if (!pricedText && hasUnpricedRows) return "未定价";
  if (!pricedText && summary.estimated_cost !== null && summary.estimated_cost !== undefined) {
    pricedText = formatMajorAmount(
      summary.estimated_cost,
      summary.estimated_cost_currency || "USD",
    );
  }
  if (!pricedText) return "—";
  return hasUnpricedRows ? `${pricedText} · 部分未定价` : pricedText;
}

export function dateRangeForTimezone(timezone = "UTC", now = new Date(), days = 30) {
  const instant = now instanceof Date ? now : new Date(now);
  if (Number.isNaN(instant.getTime())) throw new RangeError("invalid date");
  let effectiveTimezone = timezone || "UTC";
  let parts;
  try {
    parts = new Intl.DateTimeFormat("en-US", {
      timeZone: effectiveTimezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(instant);
  } catch {
    effectiveTimezone = "UTC";
    parts = new Intl.DateTimeFormat("en-US", {
      timeZone: effectiveTimezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(instant);
  }
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const end = `${values.year}-${values.month}-${values.day}`;
  const dayCount = Math.max(1, Math.trunc(Number(days) || 30));
  const startInstant = new Date(
    Date.UTC(Number(values.year), Number(values.month) - 1, Number(values.day) - dayCount + 1),
  );
  return {
    start: startInstant.toISOString().slice(0, 10),
    end,
    timezone: effectiveTimezone,
  };
}

function totalTokens(row) {
  return (
    toTokenBigInt(row.input_tokens) +
    toTokenBigInt(row.output_tokens) +
    toTokenBigInt(row.cache_read_tokens) +
    toTokenBigInt(row.cache_write_tokens)
  );
}

function currencyMicrounitsFromRows(rows) {
  const totals = {};
  rows.forEach((row) => {
    if (row.cost_microunits === null || row.cost_microunits === undefined || !row.cost_currency) {
      return;
    }
    const currency = String(row.cost_currency).toUpperCase();
    totals[currency] = (totals[currency] ?? 0n) + toTokenBigInt(row.cost_microunits);
  });
  return totals;
}

function currencyMicrounitsFromValues(values = {}) {
  const totals = {};
  Object.entries(values).forEach(([currency, value]) => {
    const normalizedCurrency = String(currency).toUpperCase();
    totals[normalizedCurrency] =
      (totals[normalizedCurrency] ?? 0n) + toTokenBigInt(value);
  });
  return totals;
}

function singleCurrencySummary(costs) {
  const entries = Object.entries(costs);
  if (entries.length !== 1) return { estimated_cost: null, estimated_cost_currency: null };
  return {
    estimated_cost: entries[0][1],
    estimated_cost_currency: entries[0][0],
  };
}

function costSummary(microunitsByCurrency) {
  const estimatedCostsMicrounits = {};
  const estimatedCosts = {};
  Object.entries(microunitsByCurrency).forEach(([currency, value]) => {
    estimatedCostsMicrounits[currency] = value.toString();
    estimatedCosts[currency] = compatibleMajorAmount(value);
  });
  return {
    estimated_costs_microunits: estimatedCostsMicrounits,
    estimated_costs: estimatedCosts,
    ...singleCurrencySummary(estimatedCosts),
  };
}

function unpricedRowCount(rows) {
  return rows.filter(
    (row) => row.cost_microunits === null || row.cost_microunits === undefined || !row.cost_currency,
  ).length;
}

export function normalizeOrganization(value = {}) {
  return {
    ...value,
    timezone: value.timezone || value.default_timezone || "UTC",
    default_timezone: value.default_timezone || value.timezone || "UTC",
  };
}

export function normalizeUser(value = {}) {
  return {
    ...value,
    email: value.email || "",
    name: value.name || value.display_name || value.email || "未命名成员",
    status: value.status || (value.is_active === false ? "disabled" : "active"),
    can_login: value.can_login === true,
    public_id: value.public_id || null,
    public_profile_enabled: value.public_profile_enabled === true,
  };
}

export function normalizeDevice(value = {}, users = []) {
  const user = users.find((item) => item.id === value.user_id);
  return {
    ...value,
    enabled: value.enabled ?? value.is_active ?? true,
    is_active: value.is_active ?? value.enabled ?? true,
    user_name: value.user_name || user?.name || user?.email || "未分配成员",
    label: value.label || `设备 ${String(value.device_public_id || value.id || "").slice(0, 8)}`,
  };
}

export function normalizePriceRows(payload = {}) {
  const rows = Array.isArray(payload)
    ? payload
    : Array.isArray(payload.items)
      ? payload.items
      : Array.isArray(payload.prices)
        ? payload.prices
        : [];
  const fallbackCurrency = Array.isArray(payload) ? "USD" : payload.currency || "USD";
  return rows.map((row) => ({
    ...row,
    currency: String(row.currency || fallbackCurrency).toUpperCase(),
    public_estimate: row.public_estimate === true,
  }));
}

export function aggregateTokenRows(rows, key, extras = () => ({})) {
  const values = new Map();
  rows.forEach((row) => {
    const name = row[key] || "未识别";
    const current = values.get(name) || { name, ...extras(row), total_tokens: 0n };
    current.total_tokens += toTokenBigInt(row.total_tokens);
    values.set(name, current);
  });
  return [...values.values()].sort((left, right) =>
    compareTokenValues(right.total_tokens, left.total_tokens),
  );
}

export function adaptUsageDashboard(
  payload = {},
  { organization = {}, users = [], devices = [], start = null, end = null } = {},
) {
  const normalizedOrganization = normalizeOrganization(organization);
  const normalizedUsers = users.map(normalizeUser);
  const normalizedDevices = devices.map((device) => normalizeDevice(device, normalizedUsers));
  const rows = (Array.isArray(payload.rows) ? payload.rows : []).map((row) => {
    const device = normalizedDevices.find((item) => item.id === row.device_id);
    const user = normalizedUsers.find((item) => item.id === row.user_id);
    const inputTokens = toTokenBigInt(row.input_tokens);
    const outputTokens = toTokenBigInt(row.output_tokens);
    const cacheReadTokens = toTokenBigInt(row.cache_read_tokens);
    const cacheWriteTokens = toTokenBigInt(row.cache_write_tokens);
    return {
      ...row,
      input_tokens: inputTokens,
      output_tokens: outputTokens,
      cache_read_tokens: cacheReadTokens,
      cache_write_tokens: cacheWriteTokens,
      total_tokens: totalTokens({
        input_tokens: inputTokens,
        output_tokens: outputTokens,
        cache_read_tokens: cacheReadTokens,
        cache_write_tokens: cacheWriteTokens,
      }),
      device_label: device?.label || `设备 ${String(row.device_id || "").slice(0, 8)}`,
      user_name: user?.name || "未命名成员",
    };
  });

  const dayMap = new Map();
  rows.forEach((row) => dayMap.set(row.date, (dayMap.get(row.date) ?? 0n) + row.total_tokens));
  const series = [...dayMap.entries()]
    .map(([date, total_tokens]) => ({ date, total_tokens }))
    .sort((left, right) => left.date.localeCompare(right.date));

  const personRows = normalizedUsers.map((user) => {
    const ownRows = rows.filter((row) => row.user_id === user.id);
    const ownDevices = normalizedDevices.filter((device) => device.user_id === user.id);
    const ownTools = aggregateTokenRows(ownRows, "tool");
    const ownModels = aggregateTokenRows(ownRows, "model", (row) => ({ tool: row.tool }));
    const primaryTool = ownTools[0]?.name || null;
    const primaryToolModels = primaryTool
      ? aggregateTokenRows(
          ownRows.filter((row) => (row.tool || "未识别") === primaryTool),
          "model",
          (row) => ({ tool: row.tool }),
        )
      : [];
    const lastSeenValues = ownDevices
      .map((device) => device.last_successful_sync_at || device.last_seen_at)
      .filter(Boolean)
      .sort();
    const estimatedCosts = costSummary(currencyMicrounitsFromRows(ownRows));
    const inputTokens = ownRows.reduce((sum, row) => sum + row.input_tokens, 0n);
    const outputTokens = ownRows.reduce((sum, row) => sum + row.output_tokens, 0n);
    const cacheReadTokens = ownRows.reduce((sum, row) => sum + row.cache_read_tokens, 0n);
    const cacheWriteTokens = ownRows.reduce((sum, row) => sum + row.cache_write_tokens, 0n);
    return {
      ...user,
      device_count: ownDevices.length,
      input_tokens: inputTokens,
      output_tokens: outputTokens,
      cache_read_tokens: cacheReadTokens,
      cache_write_tokens: cacheWriteTokens,
      cache_tokens: cacheReadTokens + cacheWriteTokens,
      norm_tokens: inputTokens + outputTokens,
      total_tokens: inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens,
      primary_tool: primaryTool,
      // Keep the displayed signature coherent: the model is the most-used
      // model within the member's most-used tool, not an unrelated global top.
      primary_model: primaryToolModels[0]?.name || null,
      by_tool: ownTools,
      by_model: ownModels,
      ...estimatedCosts,
      unpriced_rows: unpricedRowCount(ownRows),
      last_seen_at: lastSeenValues.at(-1) || null,
    };
  });

  const deviceRows = normalizedDevices.map((device) => {
    const ownRows = rows.filter((row) => row.device_id === device.id);
    return {
      ...device,
      total_tokens: ownRows.reduce((sum, row) => sum + row.total_tokens, 0n),
      ...costSummary(currencyMicrounitsFromRows(ownRows)),
      unpriced_rows: unpricedRowCount(ownRows),
      last_seen_at: device.last_successful_sync_at || device.last_seen_at,
    };
  });

  const atomicTotals = payload.totals || {};
  const inputTotal = rows.length
    ? rows.reduce((sum, row) => sum + row.input_tokens, 0n)
    : toTokenBigInt(atomicTotals.input_tokens);
  const outputTotal = rows.length
    ? rows.reduce((sum, row) => sum + row.output_tokens, 0n)
    : toTokenBigInt(atomicTotals.output_tokens);
  const cacheReadTotal = rows.length
    ? rows.reduce((sum, row) => sum + row.cache_read_tokens, 0n)
    : toTokenBigInt(atomicTotals.cache_read_tokens);
  const cacheWriteTotal = rows.length
    ? rows.reduce((sum, row) => sum + row.cache_write_tokens, 0n)
    : toTokenBigInt(atomicTotals.cache_write_tokens);
  const total = inputTotal + outputTotal + cacheReadTotal + cacheWriteTotal;
  const priced = atomicTotals.priced_costs_microunits || {};
  const estimatedCosts = costSummary(
    rows.length ? currencyMicrounitsFromRows(rows) : currencyMicrounitsFromValues(priced),
  );

  return {
    organization: normalizedOrganization,
    range: {
      start: start || series[0]?.date || null,
      end: end || series.at(-1)?.date || null,
      timezone: payload.organization_timezone || normalizedOrganization.timezone,
    },
    totals: {
      total_tokens: total,
      norm_tokens: inputTotal + outputTotal,
      ...estimatedCosts,
      active_members: personRows.filter((person) => person.total_tokens > 0n).length,
      active_devices: deviceRows.filter((device) => device.enabled && device.total_tokens > 0n).length,
      unpriced_rows: rows.length ? unpricedRowCount(rows) : number(atomicTotals.unpriced_rows),
      priced_costs_microunits: priced,
    },
    series,
    by_tool: aggregateTokenRows(rows, "tool"),
    by_model: aggregateTokenRows(rows, "model", (row) => ({ tool: row.tool })),
    people: personRows.sort((left, right) =>
      compareTokenValues(right.total_tokens, left.total_tokens),
    ),
    devices: deviceRows.sort((left, right) =>
      String(right.last_seen_at || "").localeCompare(String(left.last_seen_at || "")),
    ),
    rows,
    timezone_warning: payload.timezone_warning || null,
  };
}

export function personDetail(dashboard, userId) {
  const person = dashboard.people.find((item) => item.id === userId);
  if (!person) return null;
  return {
    ...person,
    devices: dashboard.devices.filter((item) => item.user_id === userId),
    usage: dashboard.rows.filter((item) => item.user_id === userId),
  };
}
