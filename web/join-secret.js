// This module is intentionally side-effectful: it is the first dependency of
// app.js and removes a join code fragment before the app renders, fetches, logs, or
// registers any other event handler. The raw code never enters DOM or storage.
let joinCode = "";
let batchInvitationToken = "";

function joinLocationKind(locationRef) {
  const path = String(locationRef?.pathname || "").replace(/\/+$/, "") || "/";
  const search = new URLSearchParams(String(locationRef?.search || "").replace(/^\?/, ""));
  const hash = String(locationRef?.hash || "");
  const hashRoute = hash.startsWith("#/") ? hash.slice(1) : "";
  const candidate = hashRoute || path;
  const queryIndex = candidate.indexOf("?");
  const routePath = queryIndex === -1 ? candidate : candidate.slice(0, queryIndex);
  const routeQuery = queryIndex === -1 ? "" : candidate.slice(queryIndex + 1);
  const routeParams = new URLSearchParams(routeQuery || search);
  const view = routeParams.get("view");
  if (["/rank", "/community"].includes(routePath) || ["rank", "community"].includes(view)) {
    return "";
  }
  if (/^\/(?:rank|community)\/p\/[A-Za-z0-9_-]{1,128}$/.test(routePath)) return "";
  if (routePath === "/join/batch") return "batch";
  if (routePath === "/join" || view === "join") return "device";
  return "";
}

function decodeCode(value) {
  const code = String(value || "");
  return /^[A-Za-z0-9_-]{32,256}$/.test(code) ? code : "";
}

function scrubPath(pathname) {
  const original = String(pathname || "") || "/";
  if (/^\/join\/batch\/?$/i.test(original)) {
    return { hadCode: false, safePath: "/join/batch" };
  }
  if (/^\/join\/batch\/(?:invite\/)?[^/?#]{1,512}\/?$/i.test(original)) {
    return { hadCode: true, safePath: "/join/batch" };
  }
  // The product never generates path-carried enrollment codes. Still erase any
  // extra path below /join before rendering so a manually constructed URL
  // cannot leave a valid or malformed code in browser history or screenshots.
  if (/^\/join\/(?:code\/)?[^/?#]{1,512}\/?$/i.test(original)) {
    return { hadCode: true, safePath: "/join" };
  }
  return { hadCode: false, safePath: original };
}

function scrubHash(hash) {
  const original = String(hash || "");
  const fragment = original.replace(/^#/, "");
  if (!fragment) return { code: "", invitation: "", hadCode: false, safeHash: original };

  try {
    const queryIndex = fragment.indexOf("?");
    const parameterFragment = queryIndex === -1 ? fragment : fragment.slice(queryIndex + 1);
    const prefix = queryIndex === -1 ? "" : fragment.slice(0, queryIndex);
    const params = new URLSearchParams(parameterFragment);
    const hadCode = params.has("code") || params.has("invite");
    const code = String(params.get("code") || "");
    const invitation = String(params.get("invite") || "");
    if (!hadCode) return { code: "", invitation: "", hadCode: false, safeHash: original };
    params.delete("code");
    params.delete("invite");
    const safeParams = params.toString();
    const safeFragment = queryIndex === -1
      ? safeParams
      : `${prefix}${safeParams ? `?${safeParams}` : ""}`;
    return {
      code,
      invitation,
      hadCode: true,
      safeHash: safeFragment ? `#${safeFragment}` : "",
    };
  } catch {
    return { code: "", invitation: "", hadCode: false, safeHash: original };
  }
}

export function scrubJoinSecrets(locationRef, historyRef) {
  if (!locationRef) return { joinCode: "", batchInvitationToken: "" };
  const path = scrubPath(locationRef.pathname);
  const kind = joinLocationKind({ ...locationRef, pathname: path.safePath });
  const search = new URLSearchParams(String(locationRef.search || "").replace(/^\?/, ""));
  const refusedQueryCode = search.has("code") || search.has("invite");
  search.delete("code");
  search.delete("invite");
  const hash = scrubHash(locationRef.hash);
  if (path.hadCode || hash.hadCode || refusedQueryCode) {
    const safeSearch = search.toString();
    historyRef?.replaceState(
      null,
      "",
      `${path.safePath}${safeSearch ? `?${safeSearch}` : ""}${hash.safeHash}`,
    );
  }
  return {
    joinCode: kind === "device" ? decodeCode(hash.code) : "",
    batchInvitationToken: kind === "batch" ? decodeCode(hash.invitation) : "",
  };
}

export function scrubJoinFragment(locationRef, historyRef) {
  return scrubJoinSecrets(locationRef, historyRef).joinCode;
}

export function captureJoinCode(
  locationRef = globalThis.location,
  historyRef = globalThis.history,
) {
  const captured = scrubJoinSecrets(locationRef, historyRef);
  joinCode = captured.joinCode;
  batchInvitationToken = captured.batchInvitationToken;
  return joinCode;
}

if (globalThis.location) captureJoinCode();

export function takeJoinCode() {
  const value = joinCode;
  joinCode = "";
  return value;
}

export function takeBatchInvitationToken() {
  const value = batchInvitationToken;
  batchInvitationToken = "";
  return value;
}

export function clearJoinCode() {
  joinCode = "";
  batchInvitationToken = "";
}

globalThis.addEventListener?.("pagehide", clearJoinCode, { once: true });
