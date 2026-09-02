export const SUPPORTED_TOOL_CATALOG = Object.freeze([
  { label: "Codex", displayName: "Codex", note: "默认只读识别" },
  { label: "Claude Code", displayName: "Claude Code", note: "默认只读识别" },
  { label: "ZCode", displayName: "ZCode", note: "Windows 默认统计" },
  { label: "Hermes Agent", displayName: "Hermes Agent", note: "实验来源" },
  { label: "WorkBuddy", displayName: "WorkBuddy", note: "实验来源" },
  { label: "CodeBuddy", displayName: "CodeBuddy", note: "实验来源" },
  { label: "Qoder", displayName: "Qoder", note: "实验来源" },
  { label: "Kimi", displayName: "Kimi Code", note: "实验来源" },
  { label: "OpenCode", displayName: "OpenCode", note: "实验来源" },
  { label: "Grok", displayName: "Grok Build", note: "实验来源" },
  { label: "Qwen Code", displayName: "Qwen Code", note: "实验来源" },
  { label: "Cursor", displayName: "Cursor", note: "需手动导入 CSV" },
  { label: "Cline", displayName: "Cline", note: "实验来源" },
  { label: "Copilot CLI", displayName: "GitHub Copilot CLI", note: "部分版本需开启 OTel" },
  { label: "Copilot Chat", displayName: "GitHub Copilot Chat", note: "需自行开启 OTel exporter" },
  { label: "Antigravity", displayName: "Antigravity", note: "实验来源" },
  { label: "Droid", displayName: "Droid", note: "实验来源" },
  { label: "dsh", displayName: "dsh", note: "实验来源" },
  { label: "Pi", displayName: "Pi", note: "实验来源" },
  { label: "OpenClaw", displayName: "OpenClaw", note: "实验来源" },
]);

const slots = new Map();

function emptySlot() {
  return {
    status: "idle",
    value: null,
    error: null,
    promise: null,
    controller: null,
  };
}

function slotFor(key) {
  if (!slots.has(key)) slots.set(key, emptySlot());
  return slots.get(key);
}

export function communityCapabilitiesState(key = "live") {
  const slot = slotFor(key);
  return {
    status: slot.status,
    value: slot.value,
    error: slot.error,
  };
}

export function resetCommunityCapabilities(key = "live") {
  const current = slotFor(key);
  current.controller?.abort();
  slots.set(key, emptySlot());
}

export function loadCommunityCapabilities({
  key = "live",
  request,
  timeoutMs = 10_000,
  force = false,
} = {}) {
  if (typeof request !== "function") {
    return Promise.reject(new TypeError("capability request must be a function"));
  }
  if (force) resetCommunityCapabilities(key);
  const slot = slotFor(key);
  if (slot.status === "success") return Promise.resolve(slot.value);
  if (slot.status === "loading") return slot.promise;
  if (slot.status === "failure") return Promise.reject(slot.error);

  const controller = new AbortController();
  let timer = null;
  slot.status = "loading";
  slot.controller = controller;
  slot.error = null;
  slot.promise = (async () => {
    try {
      timer = setTimeout(() => controller.abort(), timeoutMs);
      const value = await request(controller.signal);
      slot.status = "success";
      slot.value = value;
      return value;
    } catch (error) {
      slot.status = "failure";
      slot.error = error;
      throw error;
    } finally {
      if (timer !== null) clearTimeout(timer);
      slot.controller = null;
      slot.promise = null;
    }
  })();
  return slot.promise;
}
