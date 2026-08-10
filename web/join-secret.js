// This module is intentionally side-effectful: it is the first dependency of
// app.js and removes a join code fragment before the app renders, fetches, logs, or
// registers any other event handler. The raw code never enters DOM or storage.
let joinCode = "";

function isJoinLocation(locationRef) {
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
    return false;
  }
  if (/^\/(?:rank|community)\/p\/[A-Za-z0-9_-]{1,128}$/.test(routePath)) return false;
  return routePath === "/join" || view === "join";
}

function decodeCode(value) {
  const code = String(value || "");
  return /^[A-Za-z0-9_-]{32,256}$/.test(code) ? code : "";
}

function scrubPath(pathname) {
  const original = String(pathname || "") || "/";
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
  if (!fragment) return { code: "", hadCode: false, safeHash: original };

  try {
    const queryIndex = fragment.indexOf("?");
    const parameterFragment = queryIndex === -1 ? fragment : fragment.slice(queryIndex + 1);
    const prefix = queryIndex === -1 ? "" : fragment.slice(0, queryIndex);
    const params = new URLSearchParams(parameterFragment);
    const hadCode = params.has("code");
    const code = String(params.get("code") || "");
    if (!hadCode) return { code: "", hadCode: false, safeHash: original };
    params.delete("code");
    const safeParams = params.toString();
    const safeFragment = queryIndex === -1
      ? safeParams
      : `${prefix}${safeParams ? `?${safeParams}` : ""}`;
    return {
      code,
      hadCode: true,
      safeHash: safeFragment ? `#${safeFragment}` : "",
    };
  } catch {
    return { code: "", hadCode: false, safeHash: original };
  }
}

export function scrubJoinFragment(locationRef, historyRef) {
  if (!locationRef) return "";
  const path = scrubPath(locationRef.pathname);
  const joinLocation = isJoinLocation({ ...locationRef, pathname: path.safePath });
  const search = new URLSearchParams(String(locationRef.search || "").replace(/^\?/, ""));
  const refusedQueryCode = search.has("code");
  search.delete("code");
  const hash = scrubHash(locationRef.hash);
  if (path.hadCode || hash.hadCode || refusedQueryCode) {
    const safeSearch = search.toString();
    historyRef?.replaceState(
      null,
      "",
      `${path.safePath}${safeSearch ? `?${safeSearch}` : ""}${hash.safeHash}`,
    );
  }
  return joinLocation ? decodeCode(hash.code) : "";
}

export function captureJoinCode(
  locationRef = globalThis.location,
  historyRef = globalThis.history,
) {
  joinCode = scrubJoinFragment(locationRef, historyRef);
  return joinCode;
}

if (globalThis.location) captureJoinCode();

export function takeJoinCode() {
  const value = joinCode;
  joinCode = "";
  return value;
}

export function clearJoinCode() {
  joinCode = "";
}

globalThis.addEventListener?.("pagehide", clearJoinCode, { once: true });
