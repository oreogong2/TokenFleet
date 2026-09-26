const $ = (selector) => document.querySelector(selector);
const fragmentToken = window.location.hash.slice(1);
if (/^[A-Za-z0-9_-]{43,128}$/.test(fragmentToken)) {
  sessionStorage.setItem("tokenfleet-action-token", fragmentToken);
  history.replaceState(null, "", window.location.pathname);
}
const actionToken = sessionStorage.getItem("tokenfleet-action-token") || "";
const actionHeaders = {"X-TokenFleet-Action": "1", "X-TokenFleet-Token": actionToken};
const formatTokens = (value) => new Intl.NumberFormat("zh-CN", {notation: value >= 1000000 ? "compact" : "standard", maximumFractionDigits: 1}).format(value || 0);

function bars(target, values) {
  const entries = Object.entries(values || {});
  if (!entries.length) { target.innerHTML = '<p class="empty">暂无本周记录</p>'; return; }
  const max = Math.max(...entries.map(([, value]) => value));
  target.innerHTML = entries.slice(0, 8).map(([name, value]) => `<div class="bar"><div><span title="${escapeHTML(name)}">${escapeHTML(name)}</span><b>${formatTokens(value)}</b></div><i style="--value:${Math.max(3, value / max * 100)}%"></i></div>`).join("");
}

function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[char]));
}

async function load() {
  $("#status").textContent = "正在刷新…";
  const response = await fetch("/api/data", {cache: "no-store"});
  if (!response.ok) throw new Error("本机统计暂时不可用");
  const data = await response.json();
  $("#today-total").textContent = formatTokens(data.today.total_tokens);
  $("#week-total").textContent = formatTokens(data.week.total_tokens);
  if (data.rank?.rank) {
    $("#rank").textContent = `#${data.rank.rank}`;
    $("#rank-detail").textContent = `本期 ${formatTokens(Number(data.rank.metric_value || 0))} Token · 共 ${data.rank.total_entries} 人`;
  } else {
    $("#rank").textContent = "—";
    $("#rank-detail").textContent = data.rank_error || "尚未进入公开名次";
  }
  $("#sync-success").textContent = data.sync?.last_success_at ? `上次成功：${data.sync.last_success_at}` : "尚未成功同步";
  $("#sync-error").textContent = data.sync?.last_error || "自动同步每 6 小时运行；登录和错过任务时补跑";
  const skipped = Object.values(data.sync?.skipped_records || {}).reduce((sum, value) => sum + value, 0);
  $("#sync-skipped").textContent = [skipped ? `本轮跳过 ${skipped} 条无法确认完整用量的记录，正常记录仍计入` : "", data.sync?.omitted_buckets ? `上次同步隔离 ${data.sync.omitted_buckets} 个服务器拒收的桶，未计入上传量` : ""].filter(Boolean).join("；");
  bars($("#tools"), data.week.tools);
  bars($("#models"), data.week.models);
  $("#experimental").checked = data.experimental.enabled;
  $("#sources").innerHTML = Object.entries(data.experimental.scan_paths).map(([name, paths]) => `<details><summary><b>${escapeHTML(name)}</b><span>${escapeHTML(data.experimental.sources[name] || "disabled")}</span></summary>${paths.map((path) => `<code>${escapeHTML(path)}</code>`).join("")}</details>`).join("");
  $("#cursor-state").textContent = data.cursor.imported ? `已导入 · 当前窗口 ${data.cursor.records} 条` : "未导入";
  $("#cursor-delete").disabled = !data.cursor.imported;
  $("#status").textContent = data.privacy;
}

let deviceCodeExpiry = 0;
let deviceCodeTimer;
function clearDeviceCode() {
  $("#device-code").value = "";
  $("#copy-device-code").disabled = true;
  deviceCodeExpiry = 0;
  clearTimeout(deviceCodeTimer);
}
async function addDevice() {
  clearDeviceCode();
  $("#add-device").disabled = true;
  try {
    const response = await fetch("/api/devices/add-code", {method: "POST", headers: {...actionHeaders, "Content-Type": "application/json"}, body: "{}", cache: "no-store"});
    const code = await response.json();
    if (!response.ok) throw new Error(code.error || "无法生成设备码");
    deviceCodeExpiry = Date.parse(code.expires_at);
    if (!/^[A-Za-z0-9_-]{32,256}$/.test(code.enrollment_token) || !Number.isFinite(deviceCodeExpiry) || deviceCodeExpiry <= Date.now()) throw new Error("设备码无效或已过期");
    $("#device-code").value = code.enrollment_token;
    $("#copy-device-code").disabled = false;
    $("#device-code-expiry").textContent = `有效至 ${new Date(deviceCodeExpiry).toLocaleTimeString("zh-CN")}，只用一次`;
    deviceCodeTimer = setTimeout(clearDeviceCode, deviceCodeExpiry - Date.now());
  } finally { $("#add-device").disabled = false; }
}
async function copyDeviceCode() {
  if (deviceCodeExpiry <= Date.now()) { clearDeviceCode(); throw new Error("设备码已过期，请重新生成"); }
  await navigator.clipboard.writeText($("#device-code").value);
}
window.addEventListener("pagehide", clearDeviceCode);
$("#add-device").addEventListener("click", () => run(addDevice));
$("#copy-device-code").addEventListener("click", () => run(copyDeviceCode));

async function setExperimental(enabled) {
  const response = await fetch("/api/settings/experimental", {method: "POST", headers: {...actionHeaders, "Content-Type": "application/json"}, body: JSON.stringify({enabled})});
  if (!response.ok) throw new Error((await response.json()).error || "开关保存失败");
  await load();
}

async function importCursor() {
  const file = $("#cursor-file").files[0];
  if (!file) throw new Error("请先选择 Cursor Usage CSV");
  const response = await fetch("/api/cursor/import", {method: "POST", headers: {...actionHeaders, "Content-Type": "text/csv"}, body: file});
  const value = await response.json();
  if (!response.ok) throw new Error(value.error || "Cursor CSV 导入失败");
  $("#cursor-file").value = "";
  await load();
  $("#status").textContent = `Cursor CSV：新增 ${value.added_records} 条，归档共 ${value.total_records} 条。`;
}

async function deleteCursor() {
  const response = await fetch("/api/cursor/import", {method: "DELETE", headers: actionHeaders});
  const value = await response.json();
  if (!response.ok) throw new Error(value.error || "Cursor 导入删除失败");
  await load();
}

async function run(action) {
  try {
    await action();
  } catch (error) {
    try { await load(); } catch (_) {}
    $("#status").textContent = error.message;
  }
}
$("#refresh").addEventListener("click", () => run(load));
$("#experimental").addEventListener("change", (event) => run(() => setExperimental(event.target.checked)));
$("#cursor-import").addEventListener("click", () => run(importCursor));
$("#cursor-delete").addEventListener("click", () => run(deleteCursor));
load().catch((error) => { $("#status").textContent = error.message; });
