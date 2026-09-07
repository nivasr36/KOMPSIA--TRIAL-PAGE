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
  "20260906175710_harden_notification_idempotency_and_schedule_worker.sql",
  "20260907060124_restore_inventory_once_on_order_cancellation.sql",
  "20260907061632_audit_checkout_inventory_deductions.sql",
  "20260907180352_fix_auth_profile_language_default.sql",
];

test("all remote migration history is mirrored", () => {
  assert.deepEqual(migrationFiles, expectedRemoteMigrations);
});

test("notification migration preserves history and closes null-order deduplication", async () => {
  const sql = await readFile(new URL("20260906175710_harden_notification_idempotency_and_schedule_worker.sql", migrationsUrl), "utf8");
  assert.match(sql, /idempotency_key/);
  assert.match(sql, /:legacy:/);
  assert.match(sql, /on conflict \(idempotency_key\) do update/i);
  assert.doesNotMatch(sql, /delete\s+from\s+private\.notification_(?:outbox|delivery_log)/i);
  assert.match(sql, /create extension if not exists pg_cron/i);
  assert.match(sql, /vault\.decrypted_secrets/);
  assert.match(sql, /extensions\.gen_random_bytes\(32\)/);
  assert.match(sql, /notification_worker_authorize/);
  assert.match(sql, /grant execute on function public\.notification_worker_authorize\(text\) to service_role/);
  assert.match(sql, /cron\.schedule/);
});

test("worker requires its private invocation token and uses Resend idempotency", async () => {
  const worker = await readFile(new URL("../supabase/functions/send-order-notifications/index.ts", import.meta.url), "utf8");
  const config = await readFile(new URL("../supabase/config.toml", import.meta.url), "utf8");
  assert.match(worker, /X-Kompsia-Worker-Token/);
  assert.match(worker, /notification_worker_authorize/);
  assert.match(worker, /"Idempotency-Key": `kompsia\/\$\{item\.id\}`/);
  assert.doesNotMatch(worker, /RESEND_API_KEY\s*=\s*["'][^"']+["']/);
  assert.doesNotMatch(worker, /NOTIFICATION_WORKER_TOKEN/);
  assert.match(config, /\[functions\.create-checkout-order\]\s+verify_jwt = true/);
  assert.match(config, /\[functions\.send-order-notifications\]\s+verify_jwt = false/);
});

test("profile preferences and default-address updates match the database contract", async () => {
  const sql = await readFile(new URL("20260906175710_harden_notification_idempotency_and_schedule_worker.sql", migrationsUrl), "utf8");
  assert.match(sql, /set_default_customer_address/);
  assert.match(sql, /preferred_language in \('en', 'ar', 'es', 'el'\)/);
  assert.match(sql, /where id = p_address_id\s+and user_id = v_user_id/);
});

test("new Auth users receive a valid default language", async () => {
  const sql = await readFile(new URL("20260907180352_fix_auth_profile_language_default.sql", migrationsUrl), "utf8");
  assert.match(sql, /split_part\(coalesce\(v_language, 'en'\), '-', 1\)/);
  assert.match(sql, /v_language not in \('en', 'ar', 'es', 'el'\)/);
  assert.match(sql, /revoke execute on function private\.create_customer_profile_for_new_user\(\)/);
});

test("checkout remains disabled in the mirrored database configuration", async () => {
  const sql = await readFile(new URL("20260905105904_add_secure_checkout_engine.sql", migrationsUrl), "utf8");
  assert.match(sql, /checkout_enabled\s+boolean\s+not null\s+default false/i);
  assert.match(sql, /v_settings\.checkout_enabled is not true/i);
});
