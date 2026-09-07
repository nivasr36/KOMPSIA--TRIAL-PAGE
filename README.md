# KOMPSIA storefront

This repository keeps the current KOMPSIA visual storefront intact while connecting customer account features to the existing Supabase project. The catalogue shown in `index.html` remains preview content; the production `products` and related tables are intentionally empty and this change does not seed them.

## Current launch gates

- Customer sign-in is implemented with Supabase email OTP.
- Google OAuth is scaffolded but disabled until the provider, consent screen, and redirect URLs are verified.
- Checkout is disabled in both `assets/js/supabase-config.js` and `private.checkout_settings`.
- Card details are not collected or stored by the preview frontend.
- The browser receives only the Supabase publishable key. Resend and Supabase server credentials remain Edge Function secrets.

## Local review

Serve the repository over HTTP rather than opening the file directly:

```sh
python3 -m http.server 8000
```

Then open `http://127.0.0.1:8000` and run the source checks with:

```sh
npm run check
```

## Supabase setup before enabling features

1. In Auth URL Configuration, keep `https://kompsia.com` as the Site URL and allow the exact local/review redirect URLs that will be used.
2. Configure both **Confirm sign up** and **Magic link or OTP** to contain `{{ .Token }}` and no `{{ .ConfirmationURL }}` so first-time confirmation and returning sign-in both use six-digit codes rather than links.
3. Leave `googleAuth: false` until Google is enabled in Supabase Auth and the production redirect flow has been tested.
4. Leave `checkout: false` until real catalogue/variant records exist, a payment provider is approved, and end-to-end checkout testing is complete. The server-side `checkout_enabled` switch must also remain false until launch approval.

## Notification worker rollout

The migration history under `supabase/migrations` is mirrored from the live project. The final hardening migration:

- retains the nine historical test outbox records and all delivery logs;
- assigns legacy suffixes only to pre-existing duplicate event keys;
- deduplicates every new order or system notification, including rows with no order ID;
- schedules a once-per-minute worker call with `pg_cron` and `pg_net`;
- generates a private 256-bit worker credential inside Vault and schedules the worker without exposing that credential to source control or deployment logs.

The worker has gateway JWT verification disabled because scheduled calls use the Vault-generated token and a service-only authorization RPC; the customer checkout function continues to require a valid user JWT. Supabase still injects its server credential into the Edge Function environment, and Resend remains an Edge Function secret. Never commit the worker token, `RESEND_API_KEY`, a Supabase secret key, or a legacy service-role key.

Deployments should be reviewed from the development branch first. Applying migrations or deploying Edge Functions is intentionally separate from this source-control change.
