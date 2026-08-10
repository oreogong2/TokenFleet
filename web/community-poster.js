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
  urlX: 82,
  urlMaxWidth: 640,
  qrX: 750,
  qrY: 1210,
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
  const focusAlreadyIncluded = focus && topPeople.some((item) => item.publicId === focus.publicId);
  const focusRow = focus && !focusAlreadyIncluded ? {
    rank: focus.rank,
    nickname: cleanText(focus.displayName, 42) || "匿名参赛者",
    value: primaryValue(focus, safeFilters.metric),
  } : null;

  return Object.freeze({
    title: "TokenFleet 社群榜",
    subtitle: `${periodLabel} · ${metricLabel}`,
    filters: Object.freeze([
      safeFilters.tool ? `工具：${cleanText(safeFilters.tool, 42)}` : "全部工具",
      safeFilters.model ? `模型：${cleanText(safeFilters.model, 42)}` : "全部模型",
    ]),
    rows: Object.freeze(top),
    focus: focusRow ? Object.freeze(focusRow) : null,
    publicUrl: new URL(publicUrl).href,
    footer: "仅展示公开昵称与聚合用量 · Token 不代表绩效",
    demoLabel: demo === true ? "演示数据 · 非真实排名" : "",
  });
}

function roundedRect(context, x, y, width, height, radius) {
  context.beginPath();
  context.roundRect(x, y, width, height, radius);
  context.fill();
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
  context.fillStyle = "#08264f";
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

  const gradient = context.createLinearGradient(0, 0, 1200, 1600);
  gradient.addColorStop(0, "#0b3771");
  gradient.addColorStop(0.62, "#071f44");
  gradient.addColorStop(1, "#06162f");
  context.fillStyle = gradient;
  context.fillRect(0, 0, 1200, 1600);
  context.fillStyle = "rgba(81,168,255,.13)";
  context.beginPath();
  context.arc(1030, 90, 330, 0, Math.PI * 2);
  context.fill();

  if (model.demoLabel) {
    context.fillStyle = "#f6c768";
    context.fillRect(0, 0, 1200, 50);
    context.fillStyle = "#402900";
    context.font = "800 21px Avenir Next, PingFang SC, sans-serif";
    context.textAlign = "center";
    context.fillText(model.demoLabel, 600, 33);
    context.save();
    context.translate(600, 760);
    context.rotate(-0.18);
    context.fillStyle = "rgba(205,225,245,.11)";
    context.font = "800 78px Avenir Next, PingFang SC, sans-serif";
    context.fillText("DEMO · 非真实排名", 0, 0);
    context.restore();
  }

  context.textAlign = "left";
  context.fillStyle = "#9ed0ff";
  context.font = "700 24px Avenir Next, sans-serif";
  context.fillText("TOKENFLEET / COMMUNITY", 82, 98);
  context.fillStyle = "#ffffff";
  context.font = "650 68px Iowan Old Style, Songti SC, serif";
  context.fillText(model.title, 82, 182);
  context.fillStyle = "#c5def8";
  context.font = "600 27px Avenir Next, PingFang SC, sans-serif";
  context.fillText(model.subtitle, 84, 230);

  context.fillStyle = "rgba(255,255,255,.08)";
  roundedRect(context, 76, 270, 1048, 930, 30);
  context.fillStyle = "#83bee9";
  context.font = "700 19px Avenir Next, PingFang SC, sans-serif";
  context.fillText("名次", 112, 322);
  context.fillText("公开昵称", 226, 322);
  context.textAlign = "right";
  context.fillText("当前口径", 1076, 322);

  let y = 374;
  const drawRow = (row, highlighted = false) => {
    if (highlighted) {
      context.fillStyle = "rgba(115,190,255,.16)";
      roundedRect(context, 94, y - 40, 1012, 70, 18);
    }
    context.textAlign = "left";
    context.fillStyle = row.rank && row.rank <= 3 ? "#9ed0ff" : "#d5e9fa";
    context.font = "700 27px Avenir Next, sans-serif";
    context.fillText(row.rank ? String(row.rank).padStart(2, "0") : "—", 112, y);
    context.fillStyle = "#ffffff";
    context.font = "600 25px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, row.nickname, 565), 226, y);
    context.textAlign = "right";
    context.fillStyle = row.value === "未定价" ? "#f2c88c" : "#ffffff";
    context.font = "650 25px Avenir Next, PingFang SC, sans-serif";
    context.fillText(fitText(context, row.value, 250), 1076, y);
    y += 70;
  };
  model.rows.forEach((row) => drawRow(row));
  if (model.focus) {
    context.fillStyle = "rgba(158,208,255,.36)";
    context.fillRect(112, y - 31, 964, 1);
    y += 42;
    drawRow(model.focus, true);
  }

  context.textAlign = "left";
  context.fillStyle = "#d6e9fa";
  context.font = "600 21px Avenir Next, PingFang SC, sans-serif";
  context.fillText(model.filters.join("  ·  "), 82, 1335);
  context.fillStyle = "#90b8db";
  context.font = "500 18px Avenir Next, PingFang SC, sans-serif";
  context.fillText(model.footer, 82, 1380);
  context.fillStyle = "#ffffff";
  context.font = "500 17px Avenir Next, sans-serif";
  // The QR panel starts at x=750. Keep the human-readable URL entirely in
  // the left column; the QR still encodes the full canonical URL.
  context.fillText(
    fitText(context, model.publicUrl, COMMUNITY_POSTER_LAYOUT.urlMaxWidth),
    COMMUNITY_POSTER_LAYOUT.urlX,
    1468,
  );
  context.fillStyle = "#8dbce4";
  context.font = "600 16px Avenir Next, PingFang SC, sans-serif";
  context.fillText("扫码查看公开页", 620, 1570);
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

export async function downloadCommunityPoster(model, {
  documentRef = document,
  urlRef = URL,
  isActive = () => true,
} = {}) {
  if (!isActive()) return null;
  const canvas = renderCommunityPosterCanvas(model, documentRef);
  const blob = await canvasBlob(canvas);
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
