import { readFileSync } from "node:fs";
import vm from "node:vm";
import { stripTypeScriptTypes } from "node:module";

export function storefront(backend = {}) {
  const html = readFileSync(new URL("../../index.html", import.meta.url), "utf8");
  const script = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)]
    .map((match) => match[1]).find((source) => source.trim());
  const storage = new Map();
  const notices = [];
  const context = vm.createContext({
    URL, crypto, console: { warn() {}, error() {} },
    setTimeout() { return 1; }, clearTimeout() {},
    confirm() { return true; },
    location: { hash: "", origin: "https://kompsia.com", pathname: "/" },
    history: { pushState() {}, back() {}, length: 1 },
    document: { getElementById() { return null; }, documentElement: { classList: { toggle() {} } } },
    localStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, String(value)),
      removeItem: (key) => storage.delete(key),
    },
    KompsiaBackend: backend,
    KOMPSIA_CONFIG: { features: { checkout: false } },
    addEventListener() {}, scrollTo() {}, notices,
  });
  context.window = context;
  vm.runInContext(script.split("/* ============================= INIT")[0], context);
  vm.runInContext("render = () => {}; renderCartPanel = () => {}; notify = (message) => notices.push(message);", context);
  return { context, storage, notices, run: (source) => vm.runInContext(source, context) };
}

export function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

export function edge(name, client = {}, env = {}) {
  const source = readFileSync(new URL(`../../supabase/functions/${name}/index.ts`, import.meta.url), "utf8")
    .replace(/^import .*;\r?\n/gm, "");
  let handler;
  const context = vm.createContext({
    Request, Response, Headers, URL, crypto, AbortSignal,
    console: { error() {}, warn() {} },
    createClient: () => client,
    fetch: () => { throw new Error("Unexpected network call in test"); },
    Deno: { env: { get: (key) => env[key] }, serve: (callback) => { handler = callback; } },
  });
  vm.runInContext(stripTypeScriptTypes(source), context);
  return { handler, context, run: (script) => vm.runInContext(script, context) };
}
