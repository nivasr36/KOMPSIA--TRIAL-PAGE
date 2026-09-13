import assert from "node:assert/strict";
import test from "node:test";
import { edge } from "./helpers/runtime.mjs";

const env = { SUPABASE_URL: "https://example.supabase.co", SUPABASE_SECRET_KEYS: JSON.stringify({ default: "test-only" }) };
const request = (body, headers = {}) => new Request("https://example.test", {
  method: "POST", body,
  headers: { Origin: "https://kompsia.com", Authorization: "Bearer test-token", "Content-Type": "application/json", ...headers },
});
const validBody = {
  checkout_token: "cfbe3ca1-28c5-41a7-a6e0-167a775d92a1",
  shipping_address: { full_name: "Test", address_line1: "Test", city: "Dubai", country_code: "AE" },
  payment_method: "cod",
};

test("checkout preflight permits the Supabase client headers", async () => {
  const { handler } = edge("create-checkout-order");
  const result = await handler(new Request("https://example.test", { method: "OPTIONS", headers: { Origin: "https://www.kompsia.com" } }));
  assert.equal(result.status, 200);
  assert.equal(result.headers.get("access-control-allow-origin"), "https://www.kompsia.com");
  assert.match(result.headers.get("access-control-allow-headers"), /x-client-info/i);
});

test("checkout rejects invalid origins and missing authentication before creating a client", async () => {
  const { handler } = edge("create-checkout-order");
  assert.equal((await handler(request("{}", { Origin: "https://evil.example" }))).status, 403);
  assert.equal((await handler(request("{}", { Authorization: "" }))).status, 401);
});

test("malformed checkout JSON returns a client error and never calls the order RPC", async () => {
  let calls = 0;
  const { handler } = edge("create-checkout-order", {
    auth: { getUser: async () => ({ data: { user: { id: "verified-user" } } }) },
    rpc: async () => { calls++; return { data: {} }; },
  }, env);
  for (const body of ["{", "null", "[]", JSON.stringify({ ...validBody, checkout_token: "invalid" }), JSON.stringify({ ...validBody, shipping_address: "wrong" })]) {
    assert.equal((await handler(request(body))).status, 400, body);
  }
  assert.equal(calls, 0);
});

test("checkout uses the verified user and ignores client supplied prices and identity", async () => {
  let payload;
  const { handler } = edge("create-checkout-order", {
    auth: { getUser: async () => ({ data: { user: { id: "verified-user" } } }) },
    rpc: async (name, value) => { assert.equal(name, "create_checkout_order_internal"); payload = value; return { data: { order_id: "test-order" } }; },
  }, env);
  const result = await handler(request(JSON.stringify({ ...validBody, user_id: "attacker", grand_total: 0.01 })));
  assert.equal(result.status, 200);
  assert.equal(payload.p_user_id, "verified-user");
  assert.equal(payload.grand_total, undefined);
});

test("notification worker rejects missing and incorrect private tokens before claiming jobs", async () => {
  const calls = [];
  const { handler } = edge("send-order-notifications", {
    rpc: async (name) => { calls.push(name); return { data: false }; },
  }, env);
  assert.equal((await handler(request("{}"))).status, 403);
  assert.equal(calls.length, 0);
  assert.equal((await handler(request("{}", { "X-Kompsia-Worker-Token": "wrong" }))).status, 403);
  assert.deepEqual(calls, ["notification_worker_authorize"]);
});

test("notification email escapes content and permits only HTTPS tracking links", () => {
  const worker = edge("send-order-notifications");
  worker.context.item = { recipient_name: "<img src=x>", template_key: "order_received", payload: { order_number: "<b>test</b>", tracking_number: "<script>bad</script>", tracking_url: "javascript:alert(1)" } };
  assert.doesNotMatch(worker.run("renderEmail(item)"), /href="javascript:|<script>bad|<img src=x>|<b>test<\/b>/);
  worker.context.item.payload.tracking_url = "https://courier.example/?id=1&x=2";
  assert.match(worker.run("renderEmail(item)"), /href="https:\/\/courier.example\/\?id=1&amp;x=2"/);
});

test("worker reports an outbox acknowledgement failure without reporting a completed send", async () => {
  const completions = [];
  const worker = edge("send-order-notifications", {
    rpc: async (name, payload) => {
      if(name === "notification_worker_authorize") return { data: true };
      if(name === "notification_worker_status") return { data: { email_enabled:true, provider:"resend", sender_email:"test@example.com" } };
      if(name === "notification_worker_claim") return { data: [{ id:"test-job", recipient_email:"test@example.com", payload:{} }] };
      completions.push(payload);
      return { error: { message: "database unavailable" } };
    },
  }, { ...env, RESEND_API_KEY:"test-only" });
  worker.context.fetch = async (_url, options) => {
    assert.equal(options.headers["Idempotency-Key"], "kompsia/test-job");
    return new Response(JSON.stringify({ id:"provider-id" }), { status:200 });
  };
  const result = await worker.handler(request("{}", { "X-Kompsia-Worker-Token":"test-token" }));
  assert.equal(result.status, 503);
  const body = await result.json();
  assert.equal(body.completion_failed, 1);
  assert.equal(body.sent, 0);
  assert.equal(completions.length, 1);
  assert.equal(completions[0].p_success, true);
});
