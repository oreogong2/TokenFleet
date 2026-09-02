import assert from "node:assert/strict";
import test from "node:test";
import {
  SUPPORTED_TOOL_CATALOG,
  communityCapabilitiesState,
  loadCommunityCapabilities,
  resetCommunityCapabilities,
} from "../community-capabilities.js";

test("supported tool catalog freezes the twenty beta.11 data labels", () => {
  assert.deepEqual(
    SUPPORTED_TOOL_CATALOG.map(({ label }) => label),
    [
      "Codex",
      "Claude Code",
      "ZCode",
      "Hermes Agent",
      "WorkBuddy",
      "CodeBuddy",
      "Qoder",
      "Kimi",
      "OpenCode",
      "Grok",
      "Qwen Code",
      "Cursor",
      "Cline",
      "Copilot CLI",
      "Copilot Chat",
      "Antigravity",
      "Droid",
      "dsh",
      "Pi",
      "OpenClaw",
    ],
  );
  assert.equal(new Set(SUPPORTED_TOOL_CATALOG.map(({ label }) => label)).size, 20);
  assert.equal(
    SUPPORTED_TOOL_CATALOG.find(({ label }) => label === "Kimi").displayName,
    "Kimi Code",
  );
  assert.equal(
    SUPPORTED_TOOL_CATALOG.find(({ label }) => label === "Grok").displayName,
    "Grok Build",
  );
  assert.match(
    SUPPORTED_TOOL_CATALOG.find(({ label }) => label === "Cursor").note,
    /手动导入/,
  );
});

test("capability loader shares an in-flight request and reuses its session result", async () => {
  const key = "test-shared-request";
  resetCommunityCapabilities(key);
  let calls = 0;
  let resolveRequest;
  const request = () => {
    calls += 1;
    return new Promise((resolve) => { resolveRequest = resolve; });
  };

  const first = loadCommunityCapabilities({ key, request, timeoutMs: 1000 });
  const second = loadCommunityCapabilities({ key, request, timeoutMs: 1000 });
  const third = loadCommunityCapabilities({ key, request, timeoutMs: 1000 });
  assert.equal(first, second);
  assert.equal(second, third);
  assert.equal(calls, 1);
  assert.equal(communityCapabilitiesState(key).status, "loading");

  resolveRequest({ models_total: 90 });
  assert.deepEqual(await first, { models_total: 90 });
  assert.equal(communityCapabilitiesState(key).status, "success");
  assert.deepEqual(
    await loadCommunityCapabilities({ key, request, timeoutMs: 1000 }),
    { models_total: 90 },
  );
  assert.equal(calls, 1);
});

test("capability loader never auto-retries a failure but allows an explicit retry", async () => {
  const key = "test-manual-retry";
  resetCommunityCapabilities(key);
  let calls = 0;
  const failing = async () => {
    calls += 1;
    throw new Error("offline");
  };

  await assert.rejects(
    loadCommunityCapabilities({ key, request: failing, timeoutMs: 1000 }),
    /offline/,
  );
  await assert.rejects(
    loadCommunityCapabilities({ key, request: failing, timeoutMs: 1000 }),
    /offline/,
  );
  assert.equal(calls, 1);

  const recovered = await loadCommunityCapabilities({
    key,
    request: async () => {
      calls += 1;
      return { models_total: 91 };
    },
    timeoutMs: 1000,
    force: true,
  });
  assert.deepEqual(recovered, { models_total: 91 });
  assert.equal(calls, 2);
});

test("capability timeout aborts the underlying request instead of leaving a ghost fetch", async () => {
  const key = "test-real-abort";
  resetCommunityCapabilities(key);
  let aborted = false;
  const request = (signal) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => {
      aborted = true;
      const error = new Error("aborted");
      error.name = "AbortError";
      reject(error);
    }, { once: true });
  });

  await assert.rejects(
    loadCommunityCapabilities({ key, request, timeoutMs: 5 }),
    /aborted/,
  );
  assert.equal(aborted, true);
  assert.equal(communityCapabilitiesState(key).status, "failure");
});
