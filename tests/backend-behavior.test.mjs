import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import test from "node:test";

const source = readFileSync(new URL("../assets/js/kompsia-supabase.js", import.meta.url), "utf8");
function backend(client) {
  const context = vm.createContext({ crypto, setTimeout, clearTimeout });
  context.window = { KOMPSIA_CONFIG: { supabaseUrl: "https://example.supabase.co", supabasePublishableKey: "test-only" }, supabase: { createClient: () => client } };
  vm.runInContext(source, context);
  return context.window.KompsiaBackend;
}
const productId = "cfbe3ca1-28c5-41a7-a6e0-167a775d92a1";

test("backend rejects malformed quantities before any authenticated request or write", async () => {
  const api = backend({ auth: { getUser() { throw new Error("Unexpected I/O"); } } });
  for (const quantity of [NaN, Infinity, -1, 0.5, 100, "2", null]) {
    await assert.rejects(api.setCartItem(productId, null, quantity), /INVALID_CART_QUANTITY/);
  }
});

test("concurrent first-cart creation recovers the account's existing cart", async () => {
  const cart = { id: "existing-cart", currency: "AED" };
  const operations = [];
  const api = backend({
    auth: { getUser: async () => ({ data: { user: { id: "alice" } } }) },
    from(table) {
      const query = {
        inserting: false,
        select() { return this; },
        eq(key, value) { operations.push([table, key, value]); return this; },
        order: async () => ({ data: [] }),
        maybeSingle: async () => ({ data: null }),
        insert() { this.inserting = true; return this; },
        single() { return Promise.resolve(this.inserting ? { error: { code: "23505" } } : { data: cart }); },
      };
      return query;
    },
  });
  const result = await api.loadCart();
  assert.equal(result.cart.id, cart.id);
  assert.equal(operations.filter(([table, key, value]) => table === "shopping_carts" && key === "user_id" && value === "alice").length, 2);
});

test("personal order history explicitly filters the verified owner even for staff accounts", async () => {
  const operations = [];
  const api = backend({
    auth: { getUser: async () => ({ data: { user: { id: "verified-owner" } } }) },
    from(table) {
      assert.equal(table, "orders");
      return { select() { return this; }, eq(key, value) { operations.push([key, value]); return this; }, order: async () => ({ data: [] }) };
    },
  });
  await api.loadOrders();
  assert.deepEqual(operations, [["user_id", "verified-owner"]]);
});
