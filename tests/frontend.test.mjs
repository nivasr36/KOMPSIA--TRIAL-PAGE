import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const [html, config, backend, themeBootstrap] = await Promise.all([
  readFile(new URL("../index.html", import.meta.url), "utf8"),
  readFile(new URL("../assets/js/supabase-config.js", import.meta.url), "utf8"),
  readFile(new URL("../assets/js/kompsia-supabase.js", import.meta.url), "utf8"),
  readFile(new URL("../assets/js/theme-bootstrap.js", import.meta.url), "utf8"),
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
  assert.match(backend, /shouldCreateUser:\s*Boolean\(shouldCreateUser\)/);
  assert.match(backend, /emailRedirectTo:\s*`\$\{global\.location\.origin\}\$\{global\.location\.pathname\}`/);
  assert.match(backend, /functions\.invoke\("create-checkout-order"/);
  assert.match(backend, /if \(!config\?\.features\?\.checkout\)/);
});

test("sign in and account creation are distinct passwordless flows", () => {
  assert.match(html, /setLoginTab\('login'\)/);
  assert.match(html, /setLoginTab\('signup'\)/);
  assert.match(html, /Create Your Account/);
  assert.match(html, /Email Me a Sign-Up Code/);
});

test("logout hides account cart and favourites and cart IDs are normalized", () => {
  assert.match(html, /function clearVisibleSelections\(\)/);
  assert.match(html, /clearVisibleSelections\(\);\s*\n\s*state\.user=null/);
  assert.match(html, /String\(i\.id\)===String\(id\)/);
  assert.match(html, /String\(i\.id\)!==String\(id\)/);
});

test("theme preference is restored before rendering", () => {
  assert.doesNotThrow(() => new Function(themeBootstrap));
  assert.match(html, /<script src="assets\/js\/theme-bootstrap\.js"><\/script>/);
  assert.match(themeBootstrap, /getItem\("kompsia_theme"\)/);
  assert.match(themeBootstrap, /document\.documentElement\.classList\.add\("light"\)/);
  assert.match(html, /localStorage\.setItem\("kompsia_theme", state\.theme\)/);
});

test("compact header keeps search visible and exposes both navigation drawers", () => {
  assert.doesNotMatch(html, /nav\.navbar \.nav-search\{ display:none/);
  assert.match(html, /aria-label="Search products"/);
  assert.match(html, /function siteDrawerHTML\(\)/);
  assert.match(html, /function categoryLauncherHTML\(\)/);
  assert.match(html, /Categories &amp; product types/);
  assert.doesNotMatch(html, /const navItems = \[\[t\('nav_shop'\)/);
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
