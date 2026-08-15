import {
  PUBLIC_PERIODS,
  isHttpsPublicUrl,
  sanitizePublicFilters,
} from "./community-contract.js";
import { createQrMatrix } from "./qr-code.js";
import { formatTokenCount, toTokenBigInt } from "./server-adapter.js";

export const COMMUNITY_POSTER_LAYOUT = Object.freeze({
  urlX: 500,
  urlMaxWidth: 590,
  qrX: 88,
  qrSize: 370,
});

function cleanText(value, limit = 80) {
  return String(value ?? "")
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .trim()
    .slice(0, limit);
}

function tokenValue(person) {
  return formatTokenCount(person?.totalTokens ?? "0", { compact: true });
}

function posterCost(cost) {
  if (!cost || cost.unpriced || !cost.amounts?.length) return "未定价";
  return cost.amounts.map(({ currency, microunits }) => {
    const cents = (toTokenBigInt(microunits) + 5000n) / 10000n;
    const whole = cents / 100n;
    const decimal = String(cents % 100n).padStart(2, "0");
    const prefix = currency === "USD" ? "US$" : currency === "CNY" ? "¥" : `${currency} `;
    return `${prefix}${whole}.${decimal}`;
  }).join(" · ");
}

function primaryBreakdown(person, dimension) {
  const isTool = dimension === "tool";
  const primaryName = isTool ? person?.primaryTool : person?.primaryModel;
  const primaryTokens = isTool ? person?.primaryToolTokens : person?.primaryModelTokens;
  const distribution = isTool ? person?.tools : person?.models;
  const fallback = Array.isArray(distribution) ? distribution[0] : null;
  return {
    name: cleanText(primaryName || fallback?.name, 42) || "暂无可靠字段",
    value: primaryTokens !== null && primaryTokens !== undefined
      ? formatTokenCount(primaryTokens, { compact: true })
      : fallback
        ? formatTokenCount(fallback.totalTokens, { compact: true })
        : "—",
    count: Math.max(
      0,
      Number(isTool ? person?.toolCount : person?.modelCount) || 0,
      Array.isArray(distribution) ? distribution.length : 0,
    ),
  };
}

function posterRow(person, focus) {
  const tool = primaryBreakdown(person, "tool");
  const model = primaryBreakdown(person, "model");
  return {
    rank: person.rank,
    nickname: cleanText(person.displayName, 42) || "匿名参赛者",
    tool: tool.name,
    toolValue: tool.value,
    toolCount: tool.count,
    model: model.name,
    modelValue: model.value,
    modelCount: model.count,
    tokenValue: tokenValue(person),
    costValue: posterCost(person.cost),
    isFocus: Boolean(
      focus && person.rank === focus.rank && person.displayName === focus.displayName
    ),
  };
}

export function buildCommunityPosterModel({ leaderboard, focus = null, filters = {}, publicUrl, demo = false }) {
  if (!isHttpsPublicUrl(publicUrl)) throw new TypeError("分享海报需要公开 HTTPS 榜单地址");
  const safeFilters = sanitizePublicFilters({ ...filters, metric: "tokens" });
  const periodLabel = PUBLIC_PERIODS.find(([key]) => key === safeFilters.period)?.[1] || "今天";
  const topPeople = (leaderboard?.participants || []).slice(0, 10);
  const reportedTotal = Number(leaderboard?.totalEntries) || 0;
  const totalEntries = reportedTotal || Number(focus?.rank) || 0;
  const top = topPeople.map((person) => posterRow(person, focus));
  const focusRow = focus ? posterRow(focus, focus) : null;
  if (focusRow) {
    focusRow.totalEntries = totalEntries;
    focusRow.hasConsistentRankTotal = Boolean(
      focusRow.rank && totalEntries && Number(focusRow.rank) <= totalEntries,
    );
    focusRow.exceededPercent = focusRow.hasConsistentRankTotal
      ? Math.max(0, Math.min(100, Math.round(((totalEntries - focusRow.rank) / totalEntries) * 100)))
      : null;
  }
  // The public board has no viewer identity.  It may still be shared, but its
  // hero must describe the board itself rather than fabricate a "my ranking"
  // card or silently select the first participant as the viewer.
  const hero = focusRow
    ? {
      ...focusRow,
      kind: "personal",
      label: "个人成绩",
    }
    : {
      kind: "leaderboard",
      label: "当前榜单",
      periodLabel,
      totalEntries,
      detail: safeFilters.tool || safeFilters.model
        ? [safeFilters.tool, safeFilters.model].filter(Boolean).join(" · ")
        : "全部工具 · 全部模型",
    };
  return Object.freeze({
    shareKind: focusRow ? "personal" : "leaderboard",
    title: "Token 消耗排行榜",
    subtitle: `${periodLabel} · 含缓存 Token · API 公开标准价估算`,
    filters: Object.freeze([
      safeFilters.tool ? `工具：${cleanText(safeFilters.tool, 42)}` : "全部工具",
      safeFilters.model ? `模型：${cleanText(safeFilters.model, 42)}` : "全部模型",
    ]),
    rows: Object.freeze(top),
    focus: focusRow ? Object.freeze(focusRow) : null,
    hero: Object.freeze(hero),
    publicUrl: new URL(publicUrl).href,
    footer: focusRow ? "扫码查看同一口径的完整排行榜" : "扫码查看当前公开排行榜",
    slogan: "让自己 AI Native 化，Learn in Public.",
    demoLabel: demo === true ? "演示数据 · 非真实排名" : "",
  });
}

function roundedRect(context, x, y, width, height, radius) {
  context.beginPath();
  context.roundRect(x, y, width, height, radius);
  context.fill();
}

function strokeRoundedRect(context, x, y, width, height, radius) {
  context.beginPath();
  context.roundRect(x, y, width, height, radius);
  context.stroke();
}

function fitText(context, value, maxWidth) {
  const text = cleanText(value, 80);
  if (context.measureText(text).width <= maxWidth) return text;
  let result = text;
  while (result && context.measureText(`${result}…`).width > maxWidth) result = result.slice(0, -1);
  return `${result}…`;
}

function drawQr(context, matrix, x, y, size) {
  const quiet = 4;
  const modules = matrix.length + quiet * 2;
  const unit = Math.max(1, Math.floor(size / modules));
  const renderedSize = modules * unit;
  const offsetX = x + Math.floor((size - renderedSize) / 2);
  const offsetY = y + Math.floor((size - renderedSize) / 2);
  context.fillStyle = "#ffffff";
  context.fillRect(x, y, size, size);
  context.fillStyle = "#185f43";
  matrix.forEach((row, rowIndex) => row.forEach((dark, columnIndex) => {
    if (!dark) return;
    const left = offsetX + (columnIndex + quiet) * unit;
    const top = offsetY + (rowIndex + quiet) * unit;
    context.fillRect(left, top, unit, unit);
  }));
}

export function renderCommunityPosterCanvas(model, documentRef = document) {
  const canvas = documentRef.createElement("canvas");
  canvas.width = 1200;
  canvas.height = 1600;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("当前浏览器无法生成海报");

  context.fillStyle = "#f4f0e6";
  context.fillRect(0, 0, 1200, 1600);
  context.strokeStyle = "rgba(23,33,28,.045)";
  context.lineWidth = 1;
  for (let x = 0; x <= 1200; x += 40) {
    context.beginPath(); context.moveTo(x, 0); context.lineTo(x, 1600); context.stroke();
  }
  for (let y = 0; y <= 1600; y += 40) {
    context.beginPath(); context.moveTo(0, y); context.lineTo(1200, y); context.stroke();
  }

  if (model.demoLabel) {
    context.fillStyle = "#e9bb55";
    context.fillRect(0, 0, 1200, 50);
    context.fillStyle = "#402900";
    context.font = "800 21px Avenir Next, PingFang SC, sans-serif";
    context.textAlign = "center";
    context.fillText(model.demoLabel, 600, 33);
    context.save();
    context.translate(600, 760);
    context.rotate(-0.18);
    context.fillStyle = "rgba(29,119,79,.08)";
    context.font = "800 78px Avenir Next, PingFang SC, sans-serif";
    context.fillText("DEMO · 非真实排名", 0, 0);
    context.restore();
  }

  context.textAlign = "left";
  context.fillStyle = "#1d774f";
  roundedRect(context, 82, 78, 210, 44, 22);
  context.fillStyle = "#fffdf7";
  context.font = "750 20px Avenir Next, PingFang SC, sans-serif";
  context.fillText("TOKENFLEET", 112, 107);
  context.fillStyle = "#17211c";
  context.font = "750 64px Avenir Next, PingFang SC, sans-serif";
  context.fillText(model.title, 82, 190);
  context.fillStyle = "#657068";
  context.font = "600 25px Avenir Next, PingFang SC, sans-serif";
  context.fillText(model.subtitle, 84, 233);

  // A compact score strip gives the name/Token pair and the rank a shared
  // baseline.  Keeping the old tall card after removing the secondary fields
  // left an obvious empty lower half in every exported poster.
  const heroY = 260;
  const heroHeight = 112;
  const panelY = 396;
  context.fillStyle = "#fffdf7";
  roundedRect(context, 76, heroY, 1048, heroHeight, 22);
  context.strokeStyle = "rgba(29,119,79,.28)";
  context.lineWidth = 2;
  strokeRoundedRect(context, 77, heroY + 1, 1046, heroHeight - 2, 21);
  if (model.hero.kind === "personal") {
    const hero = model.hero;
    context.fillStyle = "#17211c";
    context.font = "750 26px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, hero.nickname, 565), 108, 302);
    context.fillStyle = "#1d774f";
    context.font = "850 34px Avenir Next, PingFang SC, sans-serif";
    const focusTokenValue = fitText(context, hero.tokenValue, 510);
    context.fillText(focusTokenValue, 108, 345);
    const focusTokenWidth = context.measureText(focusTokenValue).width;
    context.fillStyle = "#657068";
    context.font = "750 15px Avenir Next, PingFang SC, sans-serif";
    context.fillText("TOKEN · 含缓存", 122 + focusTokenWidth, 344);
    context.strokeStyle = "rgba(29,119,79,.18)";
    context.lineWidth = 2;
    context.beginPath();
    context.moveTo(714, 279);
    context.lineTo(714, 353);
    context.stroke();
    context.textAlign = "left";
    context.fillStyle = "#657068";
    context.font = "700 16px Avenir Next, PingFang SC, sans-serif";
    context.fillText("排名", 760, 293);
    context.fillStyle = "#1d774f";
    // Keep the rank as the first visual on the right, without letting a
    // single-digit rank overpower the name and Token value on the left.
    context.font = "850 34px Avenir Next, sans-serif";
    const rankValue = hero.rank ? `#${hero.rank}` : "未上榜";
    context.fillText(rankValue, 760, 339);
    const rankWidth = context.measureText(rankValue).width;
    if (hero.rank && hero.hasConsistentRankTotal) {
      context.font = "800 20px Avenir Next, PingFang SC, sans-serif";
      context.fillText(`/ ${hero.totalEntries}`, 772 + rankWidth, 337);
    }
    context.textAlign = "left";
  } else {
    const hero = model.hero;
    context.fillStyle = "#657068";
    context.font = "700 18px Avenir Next, PingFang SC, sans-serif";
    context.fillText(hero.label, 108, 292);
    context.fillStyle = "#17211c";
    context.font = "750 38px Avenir Next, PingFang SC, sans-serif";
    context.fillText(hero.periodLabel, 108, 333);
    context.fillStyle = "#657068";
    context.font = "700 17px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, hero.detail, 565), 108, 356);
    context.strokeStyle = "rgba(29,119,79,.18)";
    context.lineWidth = 2;
    context.beginPath();
    context.moveTo(714, 279);
    context.lineTo(714, 353);
    context.stroke();
    context.fillStyle = "#657068";
    context.font = "700 18px Avenir Next, PingFang SC, sans-serif";
    context.fillText("参与人数", 760, 292);
    context.fillStyle = "#1d774f";
    context.font = "850 40px Avenir Next, PingFang SC, sans-serif";
    context.fillText(`${hero.totalEntries || "—"} 人`, 760, 333);
    context.fillStyle = "#657068";
    context.font = "700 18px Avenir Next, PingFang SC, sans-serif";
    context.fillText("公开社群 Token 排名", 760, 356);
  }

  const rankingPanelHeight = Math.max(254, 82 + model.rows.length * 58);
  context.fillStyle = "rgba(255,253,247,.92)";
  roundedRect(context, 76, panelY, 1048, rankingPanelHeight, 24);
  context.fillStyle = "#657068";
  context.font = "700 19px Avenir Next, PingFang SC, sans-serif";
  context.fillText("名次", 108, panelY + 46);
  context.fillText("成员", 168, panelY + 46);
  context.fillText("主力工具", 430, panelY + 46);
  context.fillText("主力模型", 630, panelY + 46);
  context.textAlign = "right";
  context.fillText("Token", 956, panelY + 46);
  context.fillText("估算", 1090, panelY + 46);

  let y = panelY + 94;
  const drawRow = (row) => {
    if (row.isFocus) {
      context.fillStyle = "rgba(220,239,226,.82)";
      context.fillRect(92, y - 30, 1016, 56);
    }
    context.strokeStyle = "rgba(23,33,28,.09)";
    context.beginPath(); context.moveTo(108, y + 27); context.lineTo(1092, y + 27); context.stroke();
    context.textAlign = "left";
    context.fillStyle = row.rank && row.rank <= 3 ? "#1d774f" : "#657068";
    context.font = "700 21px Avenir Next, sans-serif";
    context.fillText(row.rank ? String(row.rank).padStart(2, "0") : "—", 108, y);
    context.fillStyle = "#17211c";
    context.font = "650 19px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, row.nickname, 230), 168, y);
    context.font = "650 16px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, row.tool, 175), 430, y - 6);
    context.fillStyle = "#657068";
    context.font = "600 13px Avenir Next, PingFang SC, sans-serif";
    context.fillText(
      `${row.toolValue}${row.toolCount > 1 ? ` · 共 ${row.toolCount} 个` : ""}`,
      430,
      y + 16,
    );
    context.fillStyle = "#17211c";
    context.font = "650 16px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, row.model, 190), 630, y - 6);
    context.fillStyle = "#657068";
    context.font = "600 13px Avenir Next, PingFang SC, sans-serif";
    context.fillText(
      `${row.modelValue}${row.modelCount > 1 ? ` · 共 ${row.modelCount} 个` : ""}`,
      630,
      y + 16,
    );
    context.textAlign = "right";
    context.fillStyle = "#17211c";
    context.font = "700 18px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, row.tokenValue, 110), 956, y);
    context.fillStyle = row.costValue === "未定价" ? "#d66336" : "#657068";
    context.font = "650 16px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, row.costValue, 125), 1090, y);
    y += 58;
  };
  model.rows.forEach((row) => drawRow(row));
  if (model.rows.length < 10) {
    context.textAlign = "center";
    context.fillStyle = "#657068";
    context.font = "650 16px Avenir Next, PingFang SC, sans-serif";
    context.fillText(
      `当前范围仅有 ${model.rows.length} 位公开参赛成员`,
      600,
      panelY + rankingPanelHeight - 27,
    );
    context.textAlign = "left";
  }

  const footerY = Math.min(1132, panelY + rankingPanelHeight + 24);
  const footerHeight = 388;
  const footerContentY = footerY + 9;
  context.fillStyle = "#fffdf7";
  roundedRect(context, 76, footerY, 1048, footerHeight, 24);
  context.textAlign = "left";
  context.fillStyle = "#17211c";
  context.font = "750 20px Avenir Next, PingFang SC, sans-serif";
  context.fillText(model.footer, 500, footerContentY + 70);
  context.fillStyle = "#1d774f";
  context.font = "850 29px Avenir Next, PingFang SC, sans-serif";
  context.fillText(model.slogan, 500, footerContentY + 118);
  context.fillStyle = "#657068";
  context.font = "600 18px Avenir Next, PingFang SC, sans-serif";
  context.fillText(
    model.rows.length >= 10 ? "Top 10 之外还有更多排名" : "当前筛选下仅展示公开参榜成员",
    500,
    footerContentY + 157,
  );
  context.font = "600 18px Avenir Next, PingFang SC, sans-serif";
  context.fillText(model.filters.join(" · "), 500, footerContentY + 197);
  context.font = "500 17px Avenir Next, sans-serif";
  context.fillText(
    fitText(context, model.publicUrl, COMMUNITY_POSTER_LAYOUT.urlMaxWidth),
    COMMUNITY_POSTER_LAYOUT.urlX,
    footerContentY + 247,
  );
  drawQr(
    context,
    createQrMatrix(model.publicUrl),
    COMMUNITY_POSTER_LAYOUT.qrX,
    footerContentY,
    COMMUNITY_POSTER_LAYOUT.qrSize,
  );
  return canvas;
}

function canvasBlob(canvas) {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => blob ? resolve(blob) : reject(new Error("海报 PNG 生成失败")), "image/png");
  });
}

export async function createCommunityPosterBlob(model, { documentRef = document } = {}) {
  return canvasBlob(renderCommunityPosterCanvas(model, documentRef));
}

export async function downloadCommunityPoster(model, {
  documentRef = document,
  urlRef = URL,
  isActive = () => true,
} = {}) {
  if (!isActive()) return null;
  const blob = await createCommunityPosterBlob(model, { documentRef });
  if (!isActive()) return null;
  const objectUrl = urlRef.createObjectURL(blob);
  if (!isActive()) {
    urlRef.revokeObjectURL(objectUrl);
    return null;
  }
  const link = documentRef.createElement("a");
  link.href = objectUrl;
  link.download = `TokenFleet-社群榜-${new Date().toISOString().slice(0, 10)}.png`;
  link.rel = "noopener";
  if (isActive()) link.click();
  setTimeout(() => urlRef.revokeObjectURL(objectUrl), 0);
  return blob;
}
