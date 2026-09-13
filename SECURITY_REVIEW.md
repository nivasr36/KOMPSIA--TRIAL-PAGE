> Deployment update: the two reviewed Supabase backend fixes were deployed on 12 September 2026. This repository release publishes the matching storefront and backend source without redeploying Supabase. See [DEPLOYMENT_STATUS.md](DEPLOYMENT_STATUS.md) for the deployment receipt.

# KOMPSIA security and code review

Reviewed 12 September 2026. Website: https://kompsia.com. Repository: `nivasr36/KOMPSIA--TRIAL-PAGE`. Baseline: `18c14a86c9a74ee6c8c0f32b3e8afc9930d2110d`.

## Result

Confirmed privacy, input-handling, and business-flow defects are fixed on `codex/kompsia-security-review-20260912`. The database and authentication settings were not changed by this review. The two Edge Function fixes were deployed separately on 12 September 2026; this release brings the repository source into agreement and publishes the storefront fixes through the existing GitHub Pages process.

No database authorization bypass or exposed server secret was identified in the checks performed. That is a scoped result, not a guarantee that the application has no vulnerabilities. Checkout is still deliberately disabled, and the storefront is a catalogue preview rather than an operational shop.

## Findings and fixes

| Finding | Assessment | Change |
| --- | --- | --- |
| Personal data survived logout; late account requests could populate the next account's view | Medium: shared-browser privacy exposure. Regression tests reproduce the in-memory disclosure and account-switch race; no production customer data was used. | Clear account models, orders, delivery forms, and related state on sign-out/identity change. Reject stale hydration and profile/address results. Require an authenticated matching order on the confirmation route. Token refresh remains separate from identity changes. |
| Cached objects and tracking data entered unsafe HTML/JavaScript/URL contexts | Medium hardening: cached payloads require control of local browser storage; tracking payloads require control of staff/imported order data. No arbitrary remote write path was demonstrated. | Restore only known preview products and valid quantities, take prices from reviewed catalogue data, store minimal selections, encode action arguments/text, and allow only HTTPS tracking URLs without credentials/control characters in both storefront and email. Legacy CMS drafts remain stored for recovery but are no longer automatically rendered. |
| Cart accepted fractional, nonfinite, empty, and overstock quantities | Functional/data-integrity defect; server checkout already independently validates stock and totals. | Enforce whole quantities within stock and the database limit of 99, reject empty manual entries, support explicit zero as removal, discard malformed caches, and label quantity controls. Serialize cloud changes and snapshot quantities so rapid edits preserve order. |
| First-cart creation raced; personal order history relied solely on RLS | Reliability and access-scope hardening. Staff legitimately have broader database access, which should not turn their personal order page into a list of other customers' orders. | Recover the existing cart after a unique-key conflict; explicitly filter personal orders by the verified user's ID; preserve distinct cart rows for product variants. |
| Repeated checkout submissions generated new idempotency tokens | Latent duplicate-request defect; checkout is currently disabled. | Block concurrent submissions and reuse the attempt token after ambiguous failures. Scope completions to the initiating identity. |
| Checkout preflight omitted `x-client-info`; malformed JSON returned 500 | Latent integration/validation defect. | Permit the Supabase client's header; return 400 for malformed JSON, invalid UUID tokens, incorrect address container types, and unsupported payment methods. Server-verified identity and database pricing remain authoritative. |
| Notification worker ignored outbox completion errors | Reliability/monitoring defect: a provider send could be reported as completed without a recorded acknowledgement. | Report `completion_failed` and HTTP 503; retain the existing outbox retry and provider idempotency key, without incorrectly recording an already-sent message as a provider failure. |
| Demo actions claimed refunds, wallet credit, sent messages, subscriptions, and invoices without performing them | Business-flow accuracy defect, not evidence of actual money movement. | Replace false successes with availability/support messages. Prevent local fake refunds, balances, rewards, and order-status changes. Disabled checkout no longer asks for delivery details. Mark the management panel as a preview and remove the public placeholder tax registration number. |

## Verification performed

- Baseline: all 16 existing tests passed. Of the first 17 new behavioral checks, 14 failed against the original code and passed after the fixes.
- Final suite: **41 tests pass**, including authentication races, logout privacy, malicious cached values, cart bounds and synchronization, tracking rendering, checkout retries, backend owner filters, Edge request validation, worker authorization, and acknowledgement failures. JavaScript syntax checks and `git diff --check` also pass.
- Tests run the actual storefront/backend source in isolated Node contexts. Edge handlers are exercised with mocked authentication, database, and email responses; test fixtures make no outbound requests.
- A full `deno check` was attempted with Deno 2.9.6, but its existing `@supabase/functions-js` JSR manifest could not be downloaded. Full dependency-aware Edge type checking therefore remains unverified; the Node handler tests and TypeScript syntax transformation passed. Retry `deno check` in an environment with JSR access before deploying the functions.
- Live SQL metadata: **20 of 20 public tables have RLS**, with 61 policies reviewed. Customer update policies constrain ownership; private settings/outbox tables have no customer grants. Service checkout/worker RPC execution is denied to anonymous and authenticated customer roles. Staff authorization uses the private role model, not editable user metadata.
- Live anonymous profile SELECT was rejected with PostgreSQL `42501` (permission denied). Under a synthetic authenticated UUID, visible profiles, addresses, orders, order items, carts, and staff records were all zero. These checks used read-only transactions, retrieved no customer records, and were rolled back.
- Supabase security advisor returned one warning: leaked-password protection is disabled. The current UI uses email OTP, not passwords; see the remaining work below.
- `npm audit` of `@supabase/supabase-js@2.102.0` and its resolved dependency tree reported **zero known advisories**. The root application has no npm dependencies, so the SDK was audited separately. The downloaded browser bundle matches its declared SHA-384 integrity value.
- A pattern scan of **55 historical Git blobs** found no private keys, Supabase server-secret/service-role tokens, GitHub tokens, Resend API keys, or database-password URLs matching the scanned patterns. This is not exhaustive credential detection.
- Live HTML exactly matched the baseline repository file (SHA-256 `7c8876c95a72dc17ae5ba10cdd4f5bd6eb23a5c8e90f7be6fd5c884d7c02ab45`). All 10 embedded image values remain unchanged in this branch; no theme, logo, or CSS redesign was made.
- The corrected local storefront was inspected in a controlled browser at 1440×1000 and 390×844. Dark and light themes, theme persistence, category browsing, responsive width, sign-in open/close, cart add/increase/decrease/remove, manual quantities, invalid and empty quantities, reload persistence, and the disabled-checkout page all passed. No console errors or framework error overlays were recorded. No OTP emails, orders, payments, or notification deliveries were triggered.

## Remaining work before release

1. **Hosting protection:** the observed response lacks a CSP header, `X-Frame-Options`, HSTS, and `X-Content-Type-Options`. Its meta CSP includes `frame-ancestors`, but browsers do not enforce that directive in a meta element. Configure a serving layer capable of returning a response policy such as `Content-Security-Policy: frame-ancestors 'self'`, plus appropriate HTTPS/content-type headers. Adding a meta tag or an unused headers file to GitHub Pages does not implement this protection. The current script policy also permits inline handlers; removing that permission needs a dedicated event-handler refactor and browser testing. [MDN documentation](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/frame-ancestors).
2. **Auth warning:** review leaked-password protection if password authentication is offered. Supabase's setting concerns passwords and is plan-dependent; the current OTP flow alone does not prove the underlying service disallows password accounts. No paid plan or authentication configuration was changed. [Supabase password security](https://supabase.com/docs/guides/auth/password-security).
3. **Launch content and integration:** verify the displayed review counts, client/warranty claims, prices, policies, payment badges, and contact details. Real catalogue, checkout, payments, returns, subscriptions, and management workflows still need completion and end-to-end validation. The branch prevents misleading success messages; it does not implement those services.

## Reproduction and rollout

Use Node 22.13 or later; this review ran Node 24.19.0:

```sh
npm run check
git diff --check
python3 -m http.server 8000 --bind 127.0.0.1
```

In a local browser, verify cart add/remove and quantities 1, 8, 9, fractional and empty values; reload the cart; check the disabled-checkout message; and verify dark/light themes. In a separate test environment, use two test accounts to verify logout, account switching, profile/address changes, and token refresh. Test checkout/notification delivery against sandbox services before enabling either production launch gate.

After review, the frontend can be released through the existing GitHub Pages process. The two changed Edge Functions are already deployed and must not be redeployed as part of this storefront release. This branch adds no SQL migrations and must not replay the mirrored migration history. Keep both checkout switches disabled until the launch work is complete.
