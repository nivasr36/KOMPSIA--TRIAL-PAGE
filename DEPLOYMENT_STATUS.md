# KOMPSIA deployment status

Backend deployment receipt from 12 September 2026. This repository version contains the matching reviewed storefront and Edge Function source. Publishing the static storefront remains subject to the normal pull-request, GitHub Pages, and live-site verification process; merging these files does not redeploy Supabase.

## Deployed backend

Project: `dkdebolrgpufryasvsvs` (KOMPSIA).

| Function | Previous version | Live version | Deployment time (UTC) | Authentication |
| --- | --- | --- | --- | --- |
| `create-checkout-order` | 3 | 4, ACTIVE | 2026-09-12 19:11:39 | Gateway JWT verification remains enabled; handler verifies the user |
| `send-order-notifications` | 5 | 6, ACTIVE | 2026-09-12 19:13:21 | Existing private worker-token authentication retained; gateway JWT verification remains disabled |

Before deployment, each live function's source exactly matched the baseline in commit `18c14a86c9a74ee6c8c0f32b3e8afc9930d2110d`. After deployment, each function was retrieved again and exactly matched the tested handoff source.

Source SHA-256 hashes:

- Checkout: `2716701cfb30a20be295274fc1a4b4bdd7dff5467f986e6163630c2b64302f34`
- Notification worker: `0d59fe93c935228dd9122a6d4b29e696d2d9cf8de64fbc0239ce62e0a8ddeece`

Checkout now permits the Supabase client's `x-client-info` preflight header and rejects malformed request data consistently. The notification worker restricts tracking links to HTTPS and reports outbox acknowledgement failures instead of falsely reporting completed delivery. These changes are compatible with the existing storefront and database.

## Backend verification recorded at deployment

- The source passed all 41 automated tests before the backend release. Edge behavior tests use mocked authentication, database, and email services.
- Live checkout `OPTIONS` returned HTTP 200, allowed origin `https://kompsia.com`, and included `x-client-info` in allowed headers.
- Live checkout `POST` without authentication returned HTTP 401 (`UNAUTHORIZED_NO_AUTH_HEADER`).
- Live worker `POST` without a worker token returned HTTP 403 (`WORKER_FORBIDDEN`) before database or email work.
- A read-only database query confirmed `private.checkout_settings.checkout_enabled = false`.
- No database migrations, authentication configuration changes, secret changes, customer orders, payments, OTP emails, or test notification deliveries were performed.

Supabase accepted and activated both deployments. Full dependency-aware `deno check` remained unverified because the prior review environment could not download the existing JSR manifest. Live rejection checks confirm the deployment boundary; they do not establish successful authenticated checkout or email delivery. Those flows require sandbox testing before launch.

## Storefront release boundary

The reviewed storefront fixes are included in this repository version. They address session privacy, cart integrity, output encoding, tracking-link validation, idempotent checkout attempts, and misleading preview actions. Release them only through the protected review branch and normal GitHub Pages process, then verify the generated deployment and `https://kompsia.com` separately.

This release adds no SQL migrations. Do not replay the mirrored migration history, change secrets or authentication settings, invoke production functions, or enable checkout. Both checkout switches must remain disabled until the remaining catalogue, payment, and end-to-end launch work is approved.

## Rollback reference

For the storefront, revert the release merge through normal Git history and allow the resulting `main` commit to deploy through GitHub Pages. Do not force-push or rewrite `main`.

The previous Edge Function sources are preserved in repository commit `18c14a86c9a74ee6c8c0f32b3e8afc9930d2110d`, under `supabase/functions/<function-name>/index.ts`. If a backend regression separately requires rollback, redeploy the corresponding baseline source with the authentication setting shown above, then repeat the access checks. Redeployment creates a new version; the version number does not revert. No backend rollback was needed or performed for this storefront release.
