import {
  PUBLIC_METRICS,
  PUBLIC_PERIODS,
  formatPublicCost,
  isHttpsPublicUrl,
  publicMetricValue,
  sanitizePublicFilters,
} from "./community-contract.js";
import { createQrMatrix } from "./qr-code.js";
import { formatTokenCount } from "./server-adapter.js";

export const COMMUNITY_POSTER_LAYOUT = Object.freeze({
  urlX: 500,
  urlMaxWidth: 590,
  qrX: 88,
  qrY: 1141,
  qrSize: 370,
});

function cleanText(value, limit = 80) {
  return String(value ?? "")
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .trim()
    .slice(0, limit);
}

function primaryValue(person, metric) {
  if (metric === "cost") return formatPublicCost(person.cost);
  return formatTokenCount(publicMetricValue(person, metric), { compact: true });
}

export function buildCommunityPosterModel({ leaderboard, focus = null, filters = {}, publicUrl, demo = false }) {
  if (!isHttpsPublicUrl(publicUrl)) throw new TypeError("分享海报需要公开 HTTPS 榜单地址");
  const safeFilters = sanitizePublicFilters(filters);
  const periodLabel = PUBLIC_PERIODS.find(([key]) => key === safeFilters.period)?.[1] || "今天";
  const metricLabel = PUBLIC_METRICS.find(([key]) => key === safeFilters.metric)?.[1] || "含缓存";
  const topPeople = (leaderboard?.participants || []).slice(0, 10);
  const top = topPeople.map((person) => ({
    rank: person.rank,
    nickname: cleanText(person.displayName, 42) || "匿名参赛者",
    value: primaryValue(person, safeFilters.metric),
  }));
  const focusRow = focus ? {
    rank: focus.rank,
    nickname: cleanText(focus.displayName, 42) || "匿名参赛者",
    value: primaryValue(focus, safeFilters.metric),
  } : null;

  return Object.freeze({
    title: "Token 消耗排行榜",
    subtitle: `${periodLabel} · ${metricLabel}`,
    filters: Object.freeze([
      safeFilters.tool ? `工具：${cleanText(safeFilters.tool, 42)}` : "全部工具",
      safeFilters.model ? `模型：${cleanText(safeFilters.model, 42)}` : "全部模型",
    ]),
    rows: Object.freeze(top),
    focus: focusRow ? Object.freeze(focusRow) : null,
    publicUrl: new URL(publicUrl).href,
    footer: "扫码查看完整排行榜",
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

  let panelY = 280;
  if (model.focus) {
    context.fillStyle = "#fffdf7";
    roundedRect(context, 76, 270, 1048, 144, 22);
    context.strokeStyle = "rgba(29,119,79,.28)";
    context.lineWidth = 2;
    strokeRoundedRect(context, 77, 271, 1046, 142, 21);
    context.fillStyle = "#657068";
    context.font = "700 18px Avenir Next, PingFang SC, sans-serif";
    context.fillText("我的排名", 108, 308);
    context.fillStyle = "#17211c";
    context.font = "700 31px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, model.focus.nickname, 500), 108, 359);
    context.textAlign = "right";
    context.fillStyle = "#1d774f";
    context.font = "800 48px Avenir Next, sans-serif";
    context.fillText(model.focus.rank ? `#${model.focus.rank}` : "未上榜", 1080, 328);
    context.font = "750 29px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, model.focus.value, 340), 1080, 372);
    context.textAlign = "left";
    panelY = 442;
  }

  const rankingPanelHeight = Math.max(254, 82 + model.rows.length * 58);
  context.fillStyle = "rgba(255,253,247,.92)";
  roundedRect(context, 76, panelY, 1048, rankingPanelHeight, 24);
  context.fillStyle = "#657068";
  context.font = "700 19px Avenir Next, PingFang SC, sans-serif";
  context.fillText("名次", 112, panelY + 46);
  context.fillText("昵称", 226, panelY + 46);
  context.textAlign = "right";
  context.fillText("Token 用量", 1076, panelY + 46);

  let y = panelY + 100;
  const drawRow = (row) => {
    context.strokeStyle = "rgba(23,33,28,.09)";
    context.beginPath(); context.moveTo(108, y + 25); context.lineTo(1092, y + 25); context.stroke();
    context.textAlign = "left";
    context.fillStyle = row.rank && row.rank <= 3 ? "#1d774f" : "#657068";
    context.font = "700 27px Avenir Next, sans-serif";
    context.fillText(row.rank ? String(row.rank).padStart(2, "0") : "—", 112, y);
    context.fillStyle = "#17211c";
    context.font = "600 25px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, row.nickname, 565), 226, y);
    context.textAlign = "right";
    context.fillStyle = row.value === "未定价" ? "#d66336" : "#17211c";
    context.font = "650 25px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, row.value, 250), 1076, y);
    y += 58;
  };
  model.rows.forEach((row) => drawRow(row));

  context.fillStyle = "#fffdf7";
  roundedRect(context, 76, 1132, 1048, 388, 24);
  context.textAlign = "left";
  context.fillStyle = "#17211c";
  context.font = "750 31px Avenir Next, PingFang SC, sans-serif";
  context.fillText(model.footer, 500, 1225);
  context.fillStyle = "#657068";
  context.font = "600 20px Avenir Next, PingFang SC, sans-serif";
  context.fillText("Top 10 之外还有更多排名", 500, 1268);
  context.fillText(model.filters.join(" · "), 500, 1310);
  context.font = "500 17px Avenir Next, sans-serif";
  context.fillText(
    fitText(context, model.publicUrl, COMMUNITY_POSTER_LAYOUT.urlMaxWidth),
    COMMUNITY_POSTER_LAYOUT.urlX,
    1390,
  );
  drawQr(
    context,
    createQrMatrix(model.publicUrl),
    COMMUNITY_POSTER_LAYOUT.qrX,
    COMMUNITY_POSTER_LAYOUT.qrY,
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
