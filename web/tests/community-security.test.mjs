import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createCommunityDemoApi } from "../community-demo-data.js";
import { normalizePublicLeaderboard, normalizePublicMemberDetail } from "../community-contract.js";
import { buildCommunityPosterModel, COMMUNITY_POSTER_LAYOUT } from "../community-poster.js";
import { createQrMatrix } from "../qr-code.js";
import {
  captureJoinCode,
  clearJoinCode,
  scrubJoinSecrets,
  scrubJoinFragment,
  takeBatchInvitationToken,
  takeJoinCode,
} from "../join-secret.js";
import { breakdownList, publicShareUrl, publicTrend } from "../community-app.js";

const validCode = "Abcd_0123456789-abcdefghijklmnop";

test("all navigation shapes scrub codes while only join fragments are captured", () => {
  const cases = [
    ["/", { pathname: "/", search: "", hash: "" }, "", null],
    ["/join", { pathname: "/join", search: "", hash: "" }, "", null],
    ["/JOIN#code=", { pathname: "/JOIN", search: "", hash: `#code=${validCode}` }, "", "/JOIN"],
    ["/#/join?code=", { pathname: "/", search: "", hash: `#/join?code=${validCode}` }, validCode, "/#/join"],
    ["/index.html#/join?code=", { pathname: "/index.html", search: "", hash: `#/join?code=${validCode}` }, validCode, "/index.html#/join"],
    ["/join?code=", { pathname: "/join", search: `?code=${validCode}`, hash: "" }, "", "/join"],
    ["/#/rank?code=", { pathname: "/", search: "", hash: `#/rank?code=${validCode}` }, "", "/#/rank"],
    ["/join/#code=", { pathname: "/join/", search: "", hash: `#code=${validCode}` }, validCode, "/join/"],
    ["/join/<code>", { pathname: `/join/${validCode}`, search: "", hash: "" }, "", "/join"],
    ["/join/code/<code>", { pathname: `/join/code/${validCode}`, search: "?campaign=beta", hash: "" }, "", "/join?campaign=beta"],
    ["/join/<encoded>", { pathname: "/join/%41%42%43secret", search: "", hash: "" }, "", "/join"],
    ["/?view=join#/rank?code=", { pathname: "/", search: "?view=join", hash: `#/rank?code=${validCode}` }, "", "/?view=join#/rank"],
    ["/?code=", { pathname: "/", search: `?code=${validCode}`, hash: "" }, "", "/"],
  ];

  cases.forEach(([label, locationRef, expectedCode, expectedUrl]) => {
    const calls = [];
    const accepted = scrubJoinFragment(locationRef, {
      replaceState: (...args) => calls.push(args),
    });
    assert.equal(accepted, expectedCode, `${label} capture`);
    assert.equal(calls.length, expectedUrl === null ? 0 : 1, `${label} scrub count`);
    if (expectedUrl !== null) {
      assert.equal(calls[0][2], expectedUrl, `${label} safe URL`);
      assert.equal(JSON.stringify(calls).includes(validCode), false, `${label} history leak`);
    }
  });
});

test("join fragment is validated while query tokens are refused", () => {
  const calls = [];
  const history = { replaceState: (...args) => calls.push(args) };
  assert.equal(scrubJoinFragment({ pathname: "/join", search: "", hash: "#code=short" }, history), "");
  assert.equal(scrubJoinFragment({ pathname: "/join", search: "", hash: `#code=${"a".repeat(257)}` }, history), "");
  assert.equal(scrubJoinFragment({ pathname: "/join", search: "", hash: `#code=${validCode}%0A` }, history), "");
  assert.equal(scrubJoinFragment({ pathname: "/index.html", search: "", hash: "#/join" }, history), "");

  const routeCalls = [];
  const routeHistory = { replaceState: (...args) => routeCalls.push(args) };
  assert.equal(scrubJoinFragment(
    { pathname: "/join", search: "?demo=1", hash: "#/rank" },
    routeHistory,
  ), "");
  assert.deepEqual(routeCalls, []);
  assert.equal(scrubJoinFragment(
    { pathname: "/join", search: `?demo=1&code=${validCode}`, hash: "#/rank" },
    routeHistory,
  ), "");
  assert.equal(routeCalls.at(-1)[2], "/join?demo=1#/rank");
});

test("same-document join re-entry replaces the in-memory code and scrubs every history URL", () => {
  const secondCode = "Zyxw_9876543210-ponmlkjihgfedcba";
  const calls = [];
  const history = { replaceState: (...args) => calls.push(args) };

  clearJoinCode();
  assert.equal(captureJoinCode(
    { pathname: "/join", search: "?campaign=first", hash: `#code=${validCode}` },
    history,
  ), validCode);
  assert.equal(takeJoinCode(), validCode);

  assert.equal(captureJoinCode(
    { pathname: "/join", search: "?campaign=second", hash: `#code=${secondCode}` },
    history,
  ), secondCode);
  assert.equal(takeJoinCode(), secondCode);
  assert.equal(takeJoinCode(), "");
  assert.deepEqual(calls.map((call) => call[2]), [
    "/join?campaign=first",
    "/join?campaign=second",
  ]);
  assert.equal(JSON.stringify(calls).includes(validCode), false);
  assert.equal(JSON.stringify(calls).includes(secondCode), false);
});

test("batch invitation is accepted only from a join-batch fragment and never from path or query", () => {
  const batchToken = "Batch_0123456789-abcdefghijklmnop";
  const calls = [];
  const history = { replaceState: (...args) => calls.push(args) };

  clearJoinCode();
  const captured = scrubJoinSecrets(
    { pathname: "/join/batch", search: "", hash: `#invite=${batchToken}` },
    history,
  );
  assert.deepEqual(captured, { joinCode: "", batchInvitationToken: batchToken });
  assert.equal(calls.at(-1)[2], "/join/batch");
  assert.equal(JSON.stringify(calls).includes(batchToken), false);

  assert.deepEqual(scrubJoinSecrets(
    { pathname: "/join/batch", search: `?invite=${batchToken}&campaign=beta`, hash: "" },
    history,
  ), { joinCode: "", batchInvitationToken: "" });
  assert.equal(calls.at(-1)[2], "/join/batch?campaign=beta");

  assert.deepEqual(scrubJoinSecrets(
    { pathname: `/join/batch/invite/${batchToken}`, search: "", hash: "" },
    history,
  ), { joinCode: "", batchInvitationToken: "" });
  assert.equal(calls.at(-1)[2], "/join/batch");

  captureJoinCode(
    { pathname: "/join/batch", search: "", hash: `#invite=${batchToken}` },
    history,
  );
  assert.equal(takeBatchInvitationToken(), batchToken);
  assert.equal(takeBatchInvitationToken(), "");
});

test("poster model contains only public display fields and appends a rank beyond API limit", async () => {
  const api = createCommunityDemoApi();
  const board = normalizePublicLeaderboard(await api.leaderboard({ period: "7d", metric: "tokens" }));
  const outside = normalizePublicMemberDetail(await api.member("outside-100", { metric: "tokens" }));
  const model = buildCommunityPosterModel({
    leaderboard: board,
    focus: outside,
    filters: { period: "7d", metric: "tokens", tool: "Codex" },
    publicUrl: "https://tokenfleet.example/rank",
    demo: true,
  });
  const serialized = JSON.stringify(model);

  assert.equal(model.rows.length, 10);
  assert.equal(model.focus.rank, 137);
  assert.equal(model.publicUrl, "https://tokenfleet.example/rank");
  assert.equal(model.demoLabel, "演示数据 · 非真实排名");
  for (const forbidden of ["email", "internal", "device", "session", "message", "publicId", "outside-100"]) {
    assert.equal(serialized.includes(forbidden), false);
  }
  assert.throws(() => buildCommunityPosterModel({ leaderboard: board, publicUrl: "http://localhost/rank" }), /HTTPS/);
});

test("unpriced entries stay explicit in posters and QR generation is deterministic", async () => {
  const api = createCommunityDemoApi();
  const board = normalizePublicLeaderboard(await api.leaderboard({ metric: "cost" }), { metric: "cost" });
  const unpriced = board.participants.find((person) => person.cost.unpriced);
  assert.equal(unpriced.rank, null);
  const model = buildCommunityPosterModel({
    leaderboard: board,
    focus: unpriced,
    filters: { metric: "cost" },
    publicUrl: "https://tokenfleet.example/rank",
  });
  assert.equal(model.focus.value, "未定价");
  const first = createQrMatrix(model.publicUrl);
  const second = createQrMatrix(model.publicUrl);
  assert.equal(first.length, 41);
  assert.ok(first.every((row) => row.length === 41));
  assert.deepEqual(first, second);
  assert.equal(first[0][0], true);
  const long = createQrMatrix(`https://example.com/rank/p/${"a".repeat(128)}?tool=${"b".repeat(128)}`);
  assert.equal(long.length, 77);
  const maximum = createQrMatrix(`https://example.com/rank?tool=${"模".repeat(128)}&model=${"型".repeat(128)}`);
  assert.equal(maximum.length, 177);
  assert.throws(() => createQrMatrix(`https://example.com/${"a".repeat(2954)}`), /过长/);
  assert.ok(
    COMMUNITY_POSTER_LAYOUT.qrX + COMMUNITY_POSTER_LAYOUT.qrSize < COMMUNITY_POSTER_LAYOUT.urlX
      || COMMUNITY_POSTER_LAYOUT.urlX + COMMUNITY_POSTER_LAYOUT.urlMaxWidth < COMMUNITY_POSTER_LAYOUT.qrX,
    "human-readable URL and QR columns must not overlap",
  );
});

test("cost trends and breakdowns never compare unpriced or mixed-currency microunits", async () => {
  const api = createCommunityDemoApi();
  const partiallyUnpriced = normalizePublicMemberDetail(
    await api.member("mixed-cost", { metric: "cost" }),
  );
  const unpricedTrend = publicTrend(partiallyUnpriced.dailyTrend, "cost", partiallyUnpriced.cost);
  const unpricedBreakdown = breakdownList(partiallyUnpriced.tools, "cost", partiallyUnpriced.cost);
  assert.match(unpricedTrend, /存在未定价日期/);
  assert.equal(unpricedTrend.includes("<polyline"), false);
  assert.equal(unpricedTrend.includes("<circle"), false);
  assert.match(unpricedBreakdown, /is-unpriced/);
  assert.equal(unpricedBreakdown.includes("style=\"width:"), false);

  const mixedCurrency = normalizePublicMemberDetail(
    await api.member("mixed-currency", { metric: "cost" }),
  );
  const currencyTrend = publicTrend(mixedCurrency.dailyTrend, "cost", mixedCurrency.cost);
  const currencyBreakdown = breakdownList(mixedCurrency.tools, "cost", mixedCurrency.cost);
  assert.match(currencyTrend, /多种币种/);
  assert.equal(currencyTrend.includes("<polyline"), false);
  assert.match(currencyBreakdown, /is-not-comparable/);
  assert.equal(currencyBreakdown.includes("style=\"width:"), false);
  assert.match(currencyBreakdown, /US\$/);
  assert.match(currencyBreakdown, /¥2\.00/);
});

test("QR v6/v15/v40 matrices match independently generated Project Nayuki fixtures", () => {
  const cases = [
    [
      "https://demo.tokenfleet.example/rank/p/outside-100",
      "7403f15bc603ca69c0141ba8fbf97c1e14ec18e848d656e02b1f4c0682e3c24f",
    ],
    [
      `https://example.com/rank/p/${"a".repeat(128)}?tool=${"b".repeat(128)}`,
      "4aabfb7c8b20af4f205d398f4c79f47f6303b42f2a43d570e5e6eaa55152b61a",
    ],
    [
      `https://example.com/rank?tool=${"模".repeat(128)}&model=${"型".repeat(128)}`,
      "fc63812b91f72b838a1519fe4c0d5496b584261ce3bb3d5e6e0117688331e55a",
    ],
  ];
  cases.forEach(([value, expected]) => {
    const matrix = createQrMatrix(value);
    const digest = createHash("sha256")
      .update(matrix.map((row) => row.map(Number).join("")).join("\n"))
      .digest("hex");
    assert.equal(digest, expected);
  });
});

test("share canonical stays same-origin and carries only route plus four public filters", () => {
  const documentRef = {
    querySelector: () => ({ getAttribute: () => "https://tokenfleet.example/" }),
  };
  const locationRef = { href: "https://tokenfleet.example/rank" };
  const value = publicShareUrl({
    route: { kind: "profile", publicId: "member-1" },
    filters: {
      period: "30d",
      metric: "cost",
      tool: "Kimi CLI",
      model: "kimi-k2",
      token: validCode,
      email: "private@example.com",
    },
    documentRef,
    locationRef,
  });
  assert.equal(
    value,
    "https://tokenfleet.example/rank/p/member-1?period=30d&metric=cost&tool=Kimi+CLI&model=kimi-k2",
  );
  assert.equal(value.includes("token="), false);
  assert.equal(value.includes("email="), false);

  const crossOriginDocument = {
    querySelector: () => ({ getAttribute: () => "https://phishing.example/" }),
  };
  assert.equal(publicShareUrl({ documentRef: crossOriginDocument, locationRef }), "");
  assert.equal(publicShareUrl({ documentRef, locationRef: { href: "http://tokenfleet.example/rank" } }), "");
});

test("join security order, deep-link assets, demo labels and license boundaries remain visible", async () => {
  const [appSource, joinSource, communitySource, posterSource, indexSource, qrSource] = await Promise.all([
    readFile(new URL("../app.js", import.meta.url), "utf8"),
    readFile(new URL("../join-secret.js", import.meta.url), "utf8"),
    readFile(new URL("../community-app.js", import.meta.url), "utf8"),
    readFile(new URL("../community-poster.js", import.meta.url), "utf8"),
    readFile(new URL("../index.html", import.meta.url), "utf8"),
    readFile(new URL("../qr-code.js", import.meta.url), "utf8"),
  ]);
  const combined = `${joinSource}\n${communitySource}\n${posterSource}`;
  assert.ok(appSource.startsWith('import {\n  captureJoinCode,\n  clearJoinCode,\n  takeBatchInvitationToken,\n  takeJoinCode,\n} from "./join-secret.js";'));
  assert.match(appSource, /hashchange[\s\S]*captureJoinCode\(\);[\s\S]*parseCommunityRoute/);
  assert.ok(joinSource.indexOf("if (globalThis.location) captureJoinCode();") < joinSource.indexOf('addEventListener?.("pagehide"'));
  assert.match(joinSource, /historyRef\?\.replaceState/);
  assert.match(joinSource, /\^\[A-Za-z0-9_-\]\{32,256\}\$/);
  assert.match(communitySource, /data-community-action="claim-batch"/);
  assert.match(communitySource, /issuedEnrollmentCode = ""/);
  assert.equal(communitySource.includes("innerHTML = issuedEnrollmentCode"), false);
  assert.equal(combined.includes("localStorage"), false);
  assert.equal(combined.includes("sessionStorage"), false);
  assert.equal(combined.includes("console."), false);
  assert.equal(communitySource.includes("window.open"), false);
  assert.equal(communitySource.includes("location.origin +"), false);
  assert.match(communitySource, /立即上传当前可验证的历史日聚合/);
  assert.match(communitySource, /持续在后台同步/);
  assert.match(communitySource, /演示数据 · 不是真实排名或真实成员数据/);
  assert.match(communitySource, /未跨时区重新归日/);
  assert.match(indexSource, /href="\/styles\.css"/);
  assert.match(indexSource, /src="\/app\.js"/);
  assert.match(qrSource, /The above copyright notice and this permission notice/);
  assert.match(qrSource, /AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM/);
});
