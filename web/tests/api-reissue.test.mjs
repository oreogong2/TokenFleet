import assert from "node:assert/strict";
import test from "node:test";
import { createApiClient } from "../api.js";
function response(payload, status) { return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } }); }

test("existing-member reissue defaults to 24 hours", async () => {
  let sent;
  const client = createApiClient({ getApiKey: () => "test", fetchImpl: async (_url, options) => {
    sent = JSON.parse(options.body);
    return response({ enrollment_token: "test-only", expires_at: "2030-01-01T00:00:00Z" }, 201);
  }});
  await client.createEnrollment({ user_id: "existing" });
  assert.deepEqual(sent, { user_id: "existing", expires_in_minutes: 1440 });
});
