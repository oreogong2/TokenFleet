import {
  captureJoinCode,
  clearJoinCode,
  takeBatchInvitationToken,
  takeJoinCode,
} from "./join-secret.js";
import { parseCommunityRoute } from "./community-contract.js?v=beta11-capability-ledger-2";
import { mountCommunityApp } from "./community-app.js?v=beta11-capability-ledger-2";

const app = document.querySelector("#app");
const demoMode = new URLSearchParams(location.search).get("demo") === "1";
let cleanup = null;
let navigationGeneration = 0;

function routeFromMemberLocation() {
  const route = parseCommunityRoute(location) || { kind: "install" };
  if (route.kind === "install" && location.pathname !== "/install") {
    history.replaceState(null, "", `/install${location.search}`);
  }
  return route;
}

function mountMemberRoute() {
  navigationGeneration += 1;
  const generation = navigationGeneration;
  cleanup?.();
  cleanup = null;
  const route = routeFromMemberLocation();
  const joinCode = route.kind === "join" ? takeJoinCode() : "";
  const batchInvitationToken = route.kind === "batch"
    ? takeBatchInvitationToken()
    : "";
  if (!["join", "batch"].includes(route.kind)) clearJoinCode();
  cleanup = mountCommunityApp({
    root: app,
    route,
    demoMode,
    joinCode,
    batchInvitationToken,
    isCurrent: () => generation === navigationGeneration,
  });
}

window.addEventListener("hashchange", () => {
  captureJoinCode();
  mountMemberRoute();
});

mountMemberRoute();
