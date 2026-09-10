import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.102.0";

const allowedOrigins = new Set([
  "https://kompsia.com",
  "https://www.kompsia.com",
]);

function corsHeaders(origin: string | null) {
  const allowOrigin = origin && allowedOrigins.has(origin) ? origin : "https://kompsia.com";
  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function json(body: unknown, status: number, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(origin),
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(origin) });
  }

  if (req.method !== "POST") {
    return json({ error: "METHOD_NOT_ALLOWED" }, 405, origin);
  }

  if (origin && !allowedOrigins.has(origin)) {
    return json({ error: "ORIGIN_NOT_ALLOWED" }, 403, origin);
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return json({ error: "AUTH_REQUIRED" }, 401, origin);
    }

    const token = authHeader.slice("Bearer ".length);
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const secretKeysRaw = Deno.env.get("SUPABASE_SECRET_KEYS");

    if (!supabaseUrl || !secretKeysRaw) {
      console.error("Missing Supabase function environment variables");
      return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500, origin);
    }

    const secretKey = JSON.parse(secretKeysRaw)["default"];
    if (!secretKey) {
      console.error("Default Supabase secret key is unavailable");
      return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500, origin);
    }

    const admin = createClient(supabaseUrl, secretKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    });

    const { data: userData, error: userError } = await admin.auth.getUser(token);
    if (userError || !userData.user) {
      return json({ error: "INVALID_SESSION" }, 401, origin);
    }

    const body = await req.json();
    const checkoutToken = typeof body?.checkout_token === "string" ? body.checkout_token : null;
    const shippingAddress = body?.shipping_address ?? null;
    const billingAddress = body?.billing_address ?? null;
    const couponCode = typeof body?.coupon_code === "string" ? body.coupon_code : null;
    const paymentMethod = typeof body?.payment_method === "string" ? body.payment_method : null;

    if (!checkoutToken || !shippingAddress || !paymentMethod) {
      return json({ error: "INVALID_REQUEST" }, 400, origin);
    }

    const { data, error } = await admin.rpc("create_checkout_order_internal", {
      p_user_id: userData.user.id,
      p_checkout_token: checkoutToken,
      p_shipping_address: shippingAddress,
      p_billing_address: billingAddress,
      p_coupon_code: couponCode,
      p_payment_method: paymentMethod,
    });

    if (error) {
      const message = error.message ?? "CHECKOUT_FAILED";
      const known = [
        "CHECKOUT_DISABLED",
        "PAYMENT_METHOD_NOT_ENABLED",
        "INVALID_SHIPPING_ADDRESS",
        "INVALID_BILLING_ADDRESS",
        "CUSTOMER_NOT_FOUND",
        "CART_EMPTY",
        "CART_CONTAINS_UNAVAILABLE_ITEM",
        "INSUFFICIENT_STOCK",
        "INVALID_CART_TOTAL",
        "COUPON_INVALID",
        "COUPON_MINIMUM_NOT_MET",
        "COUPON_USAGE_LIMIT_REACHED",
        "COUPON_CUSTOMER_LIMIT_REACHED",
        "COUPON_NOT_APPLICABLE",
      ];
      const code = known.find((candidate) => message.includes(candidate)) ?? "CHECKOUT_FAILED";
      console.error("Checkout RPC failed", { code, dbCode: error.code });
      return json({ error: code }, 400, origin);
    }

    return json({ order: data }, 200, origin);
  } catch (error) {
    console.error("Unhandled checkout error", error instanceof Error ? error.message : String(error));
    return json({ error: "CHECKOUT_FAILED" }, 500, origin);
  }
});
