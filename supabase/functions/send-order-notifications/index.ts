import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.102.0";

const allowedOrigin = "https://kompsia.com";

function tokensMatch(left: string, right: string) {
  const encoder = new TextEncoder();
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) mismatch |= a[i] ^ b[i];
  return mismatch === 0;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": allowedOrigin,
    },
  });
}

function money(value: unknown, currency = "AED") {
  const n = Number(value ?? 0);
  return `${currency} ${Number.isFinite(n) ? n.toFixed(2) : "0.00"}`;
}

function esc(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function renderEmail(item: any) {
  const p = item.payload ?? {};
  const orderNumber = esc(p.order_number ?? "your order");
  const customer = esc(item.recipient_name ?? "Customer");
  const currency = esc(p.currency ?? "AED");
  const total = money(p.grand_total, currency);
  const tracking = p.tracking_number
    ? `<p><strong>Tracking:</strong> ${esc(p.tracking_number)}</p>`
    : "";
  const trackingLink = p.tracking_url
    ? `<p><a href="${esc(p.tracking_url)}">Track your order</a></p>`
    : "";
  const note = p.note ? `<p>${esc(p.note)}</p>` : "";

  const copy: Record<string, { title: string; body: string }> = {
    order_received: { title: "Order received", body: `Thanks ${customer}. We received order <strong>${orderNumber}</strong>.` },
    order_confirmed: { title: "Order confirmed", body: `Your KOMPSIA order <strong>${orderNumber}</strong> is confirmed.` },
    order_processing: { title: "Order processing", body: `We are preparing order <strong>${orderNumber}</strong>.` },
    order_packed: { title: "Order packed", body: `Order <strong>${orderNumber}</strong> is packed and getting ready to ship.` },
    order_shipped: { title: "Order shipped", body: `Order <strong>${orderNumber}</strong> has shipped.` },
    order_delivered: { title: "Order delivered", body: `Order <strong>${orderNumber}</strong> has been marked delivered.` },
    order_cancelled: { title: "Order cancelled", body: `Order <strong>${orderNumber}</strong> has been cancelled.` },
    order_returned: { title: "Return completed", body: `The return for order <strong>${orderNumber}</strong> has been completed.` },
    order_refunded: { title: "Refund completed", body: `The refund for order <strong>${orderNumber}</strong> has been completed.` },
    payment_received: { title: "Payment received", body: `Payment for order <strong>${orderNumber}</strong> has been received.` },
    payment_refunded: { title: "Payment refunded", body: `Payment for order <strong>${orderNumber}</strong> has been refunded.` },
    cancellation_request_received: { title: "Cancellation request received", body: `We received your cancellation request for order <strong>${orderNumber}</strong>.` },
    cancellation_request_approved: { title: "Cancellation approved", body: `Your cancellation request for order <strong>${orderNumber}</strong> was approved.` },
    cancellation_request_rejected: { title: "Cancellation update", body: `Your cancellation request for order <strong>${orderNumber}</strong> was not approved.` },
    cancellation_completed: { title: "Cancellation completed", body: `Cancellation of order <strong>${orderNumber}</strong> is complete.` },
    return_request_received: { title: "Return request received", body: `We received your return request for order <strong>${orderNumber}</strong>.` },
    return_request_approved: { title: "Return approved", body: `Your return request for order <strong>${orderNumber}</strong> was approved.` },
    return_request_rejected: { title: "Return update", body: `Your return request for order <strong>${orderNumber}</strong> was not approved.` },
    return_completed: { title: "Return completed", body: `Your return for order <strong>${orderNumber}</strong> is complete.` },
    system_test: { title: "Email system test", body: `KOMPSIA transactional email delivery is connected successfully.` },
  };

  const c = copy[item.template_key] ?? { title: "KOMPSIA order update", body: `There is an update for order <strong>${orderNumber}</strong>.` };

  return `<!doctype html><html><body style="font-family:Arial,sans-serif;background:#f6f3ef;margin:0;padding:24px"><div style="max-width:620px;margin:auto;background:#fff;padding:28px;border-radius:12px"><div style="font-size:22px;font-weight:700;margin-bottom:22px">KOMPSIA</div><h2>${esc(c.title)}</h2><p>${c.body}</p>${note}${tracking}${trackingLink}<hr style="border:0;border-top:1px solid #ddd;margin:24px 0"><p><strong>Reference:</strong> ${orderNumber}</p><p><strong>Total:</strong> ${esc(total)}</p><p style="font-size:12px;color:#666">This is a transactional email from KOMPSIA.</p></div></body></html>`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const expectedWorkerToken = Deno.env.get("NOTIFICATION_WORKER_TOKEN") ?? "";
  const providedWorkerToken = req.headers.get("X-Kompsia-Worker-Token") ?? "";
  if (!expectedWorkerToken) return json({ error: "WORKER_TOKEN_MISSING" }, 500);
  if (!providedWorkerToken || !tokensMatch(providedWorkerToken, expectedWorkerToken)) {
    return json({ error: "WORKER_FORBIDDEN" }, 403);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const legacyServiceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const secretMapRaw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!url) return json({ error: "SERVER_CONFIG_MISSING" }, 500);

  let serverKey = legacyServiceRole ?? "";
  if (!serverKey && secretMapRaw) {
    try {
      const secretMap = JSON.parse(secretMapRaw) as Record<string, string>;
      serverKey = secretMap.default ?? "";
    } catch {
      return json({ error: "SERVER_CONFIG_INVALID" }, 500);
    }
  }
  if (!serverKey) return json({ error: "SERVER_SECRET_MISSING" }, 500);

  const supabase = createClient(url, serverKey, { auth: { persistSession: false, autoRefreshToken: false } });

  const { data: settings, error: settingsError } = await supabase.rpc("notification_worker_status");
  if (settingsError) return json({ error: "SETTINGS_READ_FAILED", detail: settingsError.message }, 500);
  if (!settings?.email_enabled) return json({ processed: 0, email_enabled: false });
  if (settings.provider !== "resend") return json({ error: "UNSUPPORTED_EMAIL_PROVIDER" }, 500);
  if (!resendKey) return json({ error: "RESEND_API_KEY_MISSING" }, 500);
  if (!settings.sender_email) return json({ error: "SENDER_EMAIL_MISSING" }, 500);

  const { data: claimed, error: claimError } = await supabase.rpc("notification_worker_claim", { p_limit: 20 });
  if (claimError) return json({ error: "CLAIM_FAILED", detail: claimError.message }, 500);

  const jobs = Array.isArray(claimed) ? claimed : [];
  const invocationId = crypto.randomUUID();
  let sent = 0;
  let failed = 0;

  for (const item of jobs) {
    try {
      const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${resendKey}`,
          "Content-Type": "application/json",
          "Idempotency-Key": `kompsia/${item.id}`,
        },
        body: JSON.stringify({
          from: `${settings.sender_name ?? "KOMPSIA"} <${settings.sender_email}>`,
          to: [item.recipient_email],
          subject: item.subject,
          html: renderEmail(item),
          ...(settings.reply_to_email ? { reply_to: settings.reply_to_email } : {}),
        }),
      });

      const body = await response.json().catch(() => ({}));
      const ok = response.ok && !!body?.id;

      await supabase.rpc("notification_worker_complete", {
        p_outbox_id: item.id,
        p_success: ok,
        p_provider: "resend",
        p_provider_message_id: body?.id ?? null,
        p_error_message: ok ? null : (body?.message ?? `HTTP_${response.status}`),
        p_response_metadata: { status: response.status, invocation_id: invocationId },
      });

      if (ok) sent++; else failed++;
    } catch (e) {
      failed++;
      await supabase.rpc("notification_worker_complete", {
        p_outbox_id: item.id,
        p_success: false,
        p_provider: "resend",
        p_provider_message_id: null,
        p_error_message: e instanceof Error ? e.message : "UNKNOWN_SEND_ERROR",
        p_response_metadata: { invocation_id: invocationId },
      });
    }
  }

  return json({ processed: jobs.length, sent, failed, email_enabled: true, invocation_id: invocationId });
});
