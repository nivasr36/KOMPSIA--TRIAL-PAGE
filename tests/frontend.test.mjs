import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const [html, config, backend] = await Promise.all([
  readFile(new URL("../index.html", import.meta.url), "utf8"),
  readFile(new URL("../assets/js/supabase-config.js", import.meta.url), "utf8"),
  readFile(new URL("../assets/js/kompsia-supabase.js", import.meta.url), "utf8"),
]);

test("CSP allows only the KOMPSIA Supabase project for application connections", () => {
  assert.match(html, /connect-src https:\/\/dkdebolrgpufryasvsvs\.supabase\.co wss:\/\/dkdebolrgpufryasvsvs\.supabase\.co/);
  assert.doesNotMatch(html, /connect-src[^;]*\*/);
});

test("Supabase browser client is pinned and integrity protected", () => {
  assert.match(html, /@supabase\/supabase-js@2\.102\.0\/dist\/umd\/supabase\.min\.js/);
  assert.match(html, /integrity="sha384-[^"]+"/);
});

test("frontend configuration exposes only a publishable key and keeps launch gates off", () => {
  assert.match(config, /sb_publishable_/);
  assert.match(config, /checkout:\s*false/);
  assert.match(config, /googleAuth:\s*false/);
  assert.doesNotMatch(config, /service_role|secret[_-]?key|RESEND_API_KEY|re_[A-Za-z0-9]/i);
});

test("email OTP auth and prepared checkout use the Supabase client", () => {
  assert.match(backend, /auth\.signInWithOtp/);
  assert.match(backend, /auth\.verifyOtp/);
  assert.match(backend, /type:\s*"email"/);
  assert.match(backend, /emailRedirectTo:\s*`\$\{global\.location\.origin\}\$\{global\.location\.pathname\}`/);
  assert.match(backend, /functions\.invoke\("create-checkout-order"/);
  assert.match(backend, /if \(!config\?\.features\?\.checkout\)/);
});

test("legacy mock credentials and browser card collection are gone", () => {
  assert.doesNotMatch(html, /STAFF_ACCOUNTS|sha256Hex|simulated Google sign-in|id="card-number"|id="ck-card"/);
  assert.match(html, /Card collection is not enabled yet/);
});

test("the main inline script remains valid JavaScript", () => {
  const inlineScripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)]
    .map((match) => match[1])
    .filter((source) => source.trim());
  assert.equal(inlineScripts.length, 1);
  assert.doesNotThrow(() => new Function(inlineScripts[0]));
});
