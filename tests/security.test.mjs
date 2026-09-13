import assert from "node:assert/strict";
import test from "node:test";
import { storefront, deferred } from "./helpers/runtime.mjs";

const session = (id) => ({ user: { id, email: `${id}@example.com`, user_metadata: {} } });
const emptyBackend = {
  loadProfile: async () => ({ profile: {}, addresses: [] }),
  loadOrders: async () => [], loadCart: async () => ({ items: [] }),
  getStaffRole: async () => null, signOut: async () => {},
};

test("sign-out clears personal data and confirmation cannot reveal the previous order", async () => {
  const app = storefront(emptyBackend);
  await app.context.hydrateAuthenticatedCustomer(session("alice"), "SIGNED_IN");
  app.run(`state.orders = [{id:"PRIVATE-ORDER", customerEmail:"alice@example.com", items:[], total:15}];
    state.form.address = "PRIVATE-ADDRESS"; getAccount(state.user.email).profile.phone = "PRIVATE-PHONE";`);
  await app.context.logout();
  assert.equal(app.run("state.orders.length"), 0);
  assert.equal(app.run("state.form.address"), "");
  assert.equal(app.run("Object.keys(accounts).length"), 0);
  app.run('state.page = "confirmed"');
  assert.doesNotMatch(app.run("checkoutPageHTML()"), /PRIVATE-|Order Confirmed!/);
});

test("a late account hydration cannot overwrite a different account", async () => {
  const slow = deferred();
  let calls = 0;
  const app = storefront({ ...emptyBackend, loadProfile: () => ++calls === 1 ? slow.promise : emptyBackend.loadProfile() });
  const first = app.context.hydrateAuthenticatedCustomer(session("alice"), "SIGNED_IN");
  await app.context.hydrateAuthenticatedCustomer(session("bob"), "SIGNED_IN");
  slow.resolve({ profile: { first_name: "Alice", phone: "PRIVATE-PHONE" }, addresses: [] });
  await first;
  assert.equal(app.run("state.user.email"), "bob@example.com");
  assert.equal(app.run("state.user.name"), "bob");
  assert.equal(app.run("state.form.phone"), "");
  assert.equal(app.run("Object.keys(accounts).join(',')"), "bob@example.com");
});

test("sign-out invalidates a pending account request", async () => {
  const slow = deferred();
  const app = storefront({ ...emptyBackend, loadProfile: () => slow.promise });
  const first = app.context.hydrateAuthenticatedCustomer(session("alice"), "SIGNED_IN");
  await app.context.hydrateAuthenticatedCustomer(null, "SIGNED_OUT");
  slow.resolve({ profile: { first_name: "Alice" }, addresses: [] });
  await first;
  assert.equal(app.run("state.user"), null);
  assert.equal(app.run("state.backend.lastError"), null);
  assert.equal(app.run("Object.keys(accounts).length"), 0);
});

test("account change clears staff privileges and address before new requests finish", async () => {
  const slow = deferred();
  const app = storefront({ ...emptyBackend, loadProfile: () => slow.promise });
  app.run('state.user = {id:"alice",email:"alice@example.com"}; state.isAdmin = true; state.isStaff = true; state.form.address = "PRIVATE";');
  const pending = app.context.hydrateAuthenticatedCustomer(session("bob"), "SIGNED_IN");
  assert.equal(app.run("state.isAdmin || state.isStaff"), false);
  assert.equal(app.run("state.form.address"), "");
  slow.resolve({ profile: {}, addresses: [] });
  await pending;
});

test("profile save completion is scoped to the account that started it", async () => {
  const slow = deferred();
  const app = storefront({ ...emptyBackend, saveProfile: () => slow.promise });
  await app.context.hydrateAuthenticatedCustomer(session("alice"), "SIGNED_IN");
  const pending = app.context.saveProfileTab("Profile");
  await app.context.hydrateAuthenticatedCustomer(session("bob"), "SIGNED_IN");
  slow.resolve({ first_name: "Alice" });
  await pending;
  assert.equal(app.run("state.user.name"), "bob");
});

test("cart cache restores only known products and valid bounded quantities", () => {
  const app = storefront();
  app.storage.set("kompsia_cart_v2_guest", JSON.stringify([
    { id: 1, qty: 2, name: '<img src=x onerror="alert(1)">', price: 0.01, stock: 999999 },
    { id: "x');alert(1);//", qty: 1 }, { id: 2, qty: '" autofocus onfocus="alert(1)' },
    { id: 3, qty: 1000000 }, { id: 4, qty: 1 }, { id: 1, qty: 2 },
  ]));
  app.run("loadCart()");
  assert.equal(app.run("state.cart.length"), 1);
  assert.equal(app.run("state.cart[0].name"), "Oxford Classico");
  assert.equal(app.run("state.cart[0].price"), 1299);
  assert.equal(app.run("state.cart[0].qty"), 2);
  assert.doesNotMatch(app.run("cartItemsAreaHTML()"), /alert\(1\)|autofocus/);
  app.storage.set("kompsia_cart_v2_guest", "invalid JSON");
  app.run("loadCart()");
  assert.equal(app.run("state.cart.length"), 0);
});

test("cart controls reject nonfinite, fractional and overstock quantities", () => {
  const app = storefront();
  assert.equal(app.run('Number.isNaN(parseCartQuantityInput(""))'), true);
  assert.equal(app.run('Number.isNaN(parseCartQuantityInput("   "))'), true);
  assert.equal(app.run('parseCartQuantityInput(" 8 ")'), 8);
  app.run("addToCart(1)");
  for (const value of [NaN, Infinity, -1, 1.5, 9, 999999, '2x']) {
    app.context.updateQty(1, value);
    assert.equal(app.run("state.cart[0].qty"), 1, String(value));
  }
  app.run("updateQty(1,8); addToCart(1)");
  assert.equal(app.run("state.cart[0].qty"), 8);
  app.run("updateQty(1,0)");
  assert.equal(app.run("state.cart.length"), 0);
});

test("order tracking URLs reject active schemes and order text is escaped", () => {
  const app = storefront();
  app.run(`state.user = {id:"alice",email:"alice@example.com"}; state.page = "confirmed";`);
  for (const tracking_url of ["javascript:alert(1)", "data:text/html,x", "//evil.example", "https://user:pass@example.com", "java\nscript:alert(1)"]) {
    app.context.rawOrder = { order_number: '<img src=x onerror="alert(1)">', tracking_number: "<script>bad</script>", tracking_url, order_items: [], grand_total: 1 };
    app.run("state.orders = [remoteOrderToState(rawOrder)]; state.trackerOpenIds[state.orders[0].id] = true;");
    assert.equal(app.run("state.orders[0].trackingUrl"), "");
    assert.doesNotMatch(app.run("checkoutPageHTML()"), /<img src=x|<script>bad/);
    assert.doesNotMatch(app.run("ordersPageHTML()"), /<img src=x|href="(?:javascript:|data:)/);
  }
  app.context.rawOrder.tracking_url = "https://courier.example/track?id=1&lang=en";
  assert.equal(app.run("remoteOrderToState(rawOrder).trackingUrl"), app.context.rawOrder.tracking_url);
});

test("unconnected demo return and wallet actions cannot report or apply a refund", () => {
  const app = storefront();
  app.run(`state.user={id:"alice",email:"alice@example.com"}; state.orders=[{id:"A",status:"Delivered",total:500,customerEmail:state.user.email}];
    topUpWallet(500); initiateReturn("A");`);
  assert.equal(app.run("getAccount(state.user.email).wallet.balance"), 0);
  assert.equal(app.run("state.orders[0].status"), "Delivered");
  assert.doesNotMatch(app.notices.join(" "), /credited|added to your wallet|Return started/);
});

test("disabled checkout collects no delivery information", () => {
  const app = storefront();
  app.run('state.page="checkout"');
  const html = app.run("checkoutPageHTML()");
  assert.match(html, /Checkout.*not.*live/i);
  assert.doesNotMatch(html, /id="ck-(?:name|phone|address)"/);
});

test("legacy CMS cache cannot inject catalogue or contact markup on startup", () => {
  const app = storefront();
  app.storage.set("kompsia_cms_v1", JSON.stringify({ products: [{ id: '1);alert(1)//' }], siteContent: { contact: { whatsapp: "');alert(1)//" } } }));
  app.run("loadCMS()");
  assert.equal(app.run("getProduct(1).name"), "Oxford Classico");
  assert.doesNotMatch(app.run("siteContent.contact.whatsapp"), /alert/);
  assert.ok(app.storage.has("kompsia_cms_v1"), "Legacy drafts are preserved for recovery");
});

test("unconnected forms do not mark messages or feedback as submitted", () => {
  const app = storefront();
  app.run('state.feedbackForm.rating=5; subscribeNewsletter(); sendContactMessage(); submitFeedback(); registerStockNotify(1,"test@example.com");');
  assert.equal(app.run("state.feedbackSubmitted"), false);
  assert.equal(app.run("Object.keys(state.stockNotifications).length"), 0);
  assert.doesNotMatch(app.notices.join(" "), /Message sent|on the list|We'll email/);
});

test("checkout double-clicks share one request and retries retain the idempotency token", async () => {
  const slow = deferred();
  const payloads = [];
  const app = storefront({ ...emptyBackend, createCheckoutOrder: (payload) => { payloads.push(payload); return slow.promise; } });
  app.run('KOMPSIA_CONFIG.features.checkout=true; state.user={id:"alice",email:"alice@example.com"}; state.form.address="Test address";');
  const first = app.context.placeOrder();
  const second = app.context.placeOrder();
  assert.equal(payloads.length, 1);
  slow.reject(new Error("Network interrupted"));
  await Promise.all([first, second]);
  await app.context.placeOrder();
  assert.equal(payloads.length, 2);
  assert.equal(payloads[0].checkoutToken, payloads[1].checkoutToken);
});

test("token refresh during checkout does not leave the submit guard stuck", async () => {
  const slow = deferred();
  const app = storefront({ ...emptyBackend, createCheckoutOrder: () => slow.promise });
  await app.context.hydrateAuthenticatedCustomer(session("alice"), "SIGNED_IN");
  app.run('KOMPSIA_CONFIG.features.checkout=true; state.form.address="Test address";');
  const pending = app.context.placeOrder();
  await app.context.hydrateAuthenticatedCustomer(session("alice"), "TOKEN_REFRESHED");
  slow.reject(new Error("Network interrupted"));
  await pending;
  assert.equal(app.run("state.checkoutBusy"), false);
});

test("cart sync serializes rapid changes and snapshots each requested quantity", async () => {
  const slow = deferred();
  const calls = [];
  const app = storefront({ setCartItem: async (_product, _variant, qty) => { calls.push(qty); if(calls.length===1) await slow.promise; } });
  app.run('state.user={id:"alice",email:"alice@example.com"}; state.cart=[{id:"row",backendId:"product",qty:1,stock:10}];');
  const first = app.run("persistCartItem(state.cart[0])");
  app.run("state.cart[0].qty=3");
  const second = app.run("persistCartItem(state.cart[0])");
  await Promise.resolve();
  assert.deepEqual(calls, [1]);
  slow.resolve();
  await Promise.all([first, second]);
  assert.deepEqual(calls, [1,3]);
});
