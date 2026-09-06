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
2. Configure the Auth email template to contain `{{ .Token }}` so `signInWithOtp` sends a six-digit code rather than only a magic link.
3. Leave `googleAuth: false` until Google is enabled in Supabase Auth and the production redirect flow has been tested.
4. Leave `checkout: false` until real catalogue/variant records exist, a payment provider is approved, and end-to-end checkout testing is complete. The server-side `checkout_enabled` switch must also remain false until launch approval.

## Notification worker rollout

The migration history under `supabase/migrations` is mirrored from the live project. The final hardening migration:

- retains the nine historical test outbox records and all delivery logs;
- assigns legacy suffixes only to pre-existing duplicate event keys;
- deduplicates every new order or system notification, including rows with no order ID;
- schedules a once-per-minute worker call with `pg_cron` and `pg_net`;
- leaves the scheduled call inert until its Vault configuration exists.

Before applying that migration and deploying the updated worker, create one long random worker token. Store the same value as the Edge Function secret `NOTIFICATION_WORKER_TOKEN` and the Vault secret `kompsia_notification_worker_token`. Also create a Vault entry named `kompsia_project_url`. The worker has gateway JWT verification disabled because scheduled calls use this dedicated constant-time-checked token; the customer checkout function continues to require a valid user JWT. Never commit the worker token, `RESEND_API_KEY`, a Supabase secret key, or a legacy service-role key.

Deployments should be reviewed from the development branch first. Applying migrations or deploying Edge Functions is intentionally separate from this source-control change.
