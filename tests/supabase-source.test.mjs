import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import test from "node:test";

const migrationsUrl = new URL("../supabase/migrations/", import.meta.url);
const migrationFiles = (await readdir(migrationsUrl)).filter((name) => name.endsWith(".sql")).sort();
const expectedRemoteMigrations = [
  "20260905095932_create_kompsia_catalog_foundation.sql",
  "20260905100711_create_customer_profiles_and_addresses.sql",
  "20260905100825_add_profile_trigger_and_order_foundation.sql",
  "20260905101618_add_customer_cart_and_wishlist.sql",
  "20260905105904_add_secure_checkout_engine.sql",
  "20260905111030_configure_uae_shipping_and_payment_rules.sql",
  "20260905113016_add_order_tracking_and_status_management.sql",
  "20260905114144_add_staff_roles_and_admin_order_management.sql",
  "20260905115121_add_admin_catalog_inventory_and_promotions_management.sql",
  "20260905115219_optimize_admin_rls_policies.sql",
  "20260905115313_merge_public_and_staff_catalog_read_policies.sql",
  "20260905120658_complete_auth_account_provisioning.sql",
  "20260905123839_add_transactional_notification_outbox.sql",
  "20260905124645_prepare_notification_worker_rpc.sql",
  "20260906135944_enable_pg_net_for_internal_workers.sql",
  "20260906143737_secure_notification_worker_rpc_wrappers.sql",
];

test("all remote migration history is mirrored before the new hardening migration", () => {
  assert.deepEqual(migrationFiles.slice(0, expectedRemoteMigrations.length), expectedRemoteMigrations);
  assert.equal(migrationFiles.length, expectedRemoteMigrations.length + 1);
  assert.match(migrationFiles.at(-1), /harden_notification_idempotency_and_schedule_worker\.sql$/);
});

test("notification migration preserves history and closes null-order deduplication", async () => {
  const hardeningName = migrationFiles.at(-1);
  const sql = await readFile(new URL(hardeningName, migrationsUrl), "utf8");
  assert.match(sql, /idempotency_key/);
  assert.match(sql, /:legacy:/);
  assert.match(sql, /on conflict \(idempotency_key\) do update/i);
  assert.doesNotMatch(sql, /delete\s+from\s+private\.notification_(?:outbox|delivery_log)/i);
  assert.match(sql, /create extension if not exists pg_cron/i);
  assert.match(sql, /vault\.decrypted_secrets/);
  assert.match(sql, /cron\.schedule/);
});

test("worker requires its private invocation token and uses Resend idempotency", async () => {
  const worker = await readFile(new URL("../supabase/functions/send-order-notifications/index.ts", import.meta.url), "utf8");
  const config = await readFile(new URL("../supabase/config.toml", import.meta.url), "utf8");
  assert.match(worker, /NOTIFICATION_WORKER_TOKEN/);
  assert.match(worker, /X-Kompsia-Worker-Token/);
  assert.match(worker, /"Idempotency-Key": `kompsia\/\$\{item\.id\}`/);
  assert.doesNotMatch(worker, /RESEND_API_KEY\s*=\s*["'][^"']+["']/);
  assert.match(config, /\[functions\.create-checkout-order\]\s+verify_jwt = true/);
  assert.match(config, /\[functions\.send-order-notifications\]\s+verify_jwt = false/);
});

test("profile preferences and default-address updates match the database contract", async () => {
  const hardeningName = migrationFiles.at(-1);
  const sql = await readFile(new URL(hardeningName, migrationsUrl), "utf8");
  assert.match(sql, /set_default_customer_address/);
  assert.match(sql, /preferred_language in \('en', 'ar', 'es', 'el'\)/);
  assert.match(sql, /where id = p_address_id\s+and user_id = v_user_id/);
});

test("checkout remains disabled in the mirrored database configuration", async () => {
  const sql = await readFile(new URL("20260905105904_add_secure_checkout_engine.sql", migrationsUrl), "utf8");
  assert.match(sql, /checkout_enabled\s+boolean\s+not null\s+default false/i);
  assert.match(sql, /v_settings\.checkout_enabled is not true/i);
});
