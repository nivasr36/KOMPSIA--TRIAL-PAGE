(function createKompsiaBackend(global) {
  "use strict";

  const config = global.KOMPSIA_CONFIG;
  let client = null;
  let authSubscription = null;

  function requireClient() {
    if (client) return client;
    if (!config?.supabaseUrl || !config?.supabasePublishableKey) {
      throw new Error("SUPABASE_PUBLIC_CONFIG_MISSING");
    }
    if (!global.supabase?.createClient) {
      throw new Error("SUPABASE_CLIENT_UNAVAILABLE");
    }

    client = global.supabase.createClient(
      config.supabaseUrl,
      config.supabasePublishableKey,
      {
        auth: {
          persistSession: true,
          autoRefreshToken: true,
          detectSessionInUrl: true,
        },
      },
    );
    return client;
  }

  function normalizeEmail(email) {
    return String(email || "").trim().toLowerCase();
  }

  function assertUuid(value, code) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value || ""))) {
      throw new Error(code || "INVALID_UUID");
    }
  }

  async function requireUser() {
    const supabase = requireClient();
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user) throw new Error("AUTH_REQUIRED");
    return data.user;
  }

  async function init(onAuthChange) {
    const supabase = requireClient();
    const { data, error } = await supabase.auth.getSession();
    if (error) throw error;

    authSubscription?.unsubscribe?.();
    const listener = supabase.auth.onAuthStateChange((event, session) => {
      // Keep the auth callback synchronous; Supabase calls are made after it returns.
      setTimeout(() => onAuthChange?.(session, event), 0);
    });
    authSubscription = listener.data.subscription;
    return data.session;
  }

  async function requestEmailOtp(email, fullName) {
    const supabase = requireClient();
    const cleanEmail = normalizeEmail(email);
    if (!cleanEmail || !cleanEmail.includes("@")) throw new Error("INVALID_EMAIL");

    const options = {
      shouldCreateUser: true,
      emailRedirectTo: `${global.location.origin}${global.location.pathname}`,
    };
    if (String(fullName || "").trim()) {
      options.data = { full_name: String(fullName).trim() };
    }

    const { error } = await supabase.auth.signInWithOtp({
      email: cleanEmail,
      options,
    });
    if (error) throw error;
  }

  async function verifyEmailOtp(email, token) {
    const supabase = requireClient();
    const cleanEmail = normalizeEmail(email);
    const cleanToken = String(token || "").replace(/\s/g, "");
    if (!/^\d{6}$/.test(cleanToken)) throw new Error("INVALID_OTP");

    const { data, error } = await supabase.auth.verifyOtp({
      email: cleanEmail,
      token: cleanToken,
      type: "email",
    });
    if (error) throw error;
    return data.session;
  }

  async function signInWithGoogle() {
    if (!config?.features?.googleAuth) throw new Error("GOOGLE_AUTH_NOT_ENABLED");
    const supabase = requireClient();
    const redirectTo = `${global.location.origin}${global.location.pathname}`;
    const { data, error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo },
    });
    if (error) throw error;
    return data;
  }

  async function signOut() {
    const { error } = await requireClient().auth.signOut();
    if (error) throw error;
  }

  async function getStaffRole() {
    const { data, error } = await requireClient().rpc("staff_my_role");
    if (error) return null;
    return data || null;
  }

  async function loadProfile() {
    const user = await requireUser();
    const supabase = requireClient();
    const [{ data: profile, error: profileError }, { data: addresses, error: addressError }] = await Promise.all([
      supabase
        .from("customer_profiles")
        .select("id,first_name,last_name,phone,date_of_birth,avatar_url,preferred_language,marketing_opt_in")
        .eq("id", user.id)
        .maybeSingle(),
      supabase
        .from("customer_addresses")
        .select("id,label,full_name,phone,company,address_line1,address_line2,city,state_region,postal_code,country_code,is_default_shipping,is_default_billing,created_at")
        .eq("user_id", user.id)
        .order("created_at", { ascending: true }),
    ]);
    if (profileError) throw profileError;
    if (addressError) throw addressError;
    return { profile, addresses: addresses || [] };
  }

  async function saveProfile(values) {
    const user = await requireUser();
    const allowedLanguages = new Set(["en", "ar", "es", "el"]);
    const payload = {
      id: user.id,
      first_name: String(values.firstName || "").trim() || null,
      last_name: String(values.lastName || "").trim() || null,
      phone: String(values.phone || "").trim() || null,
      date_of_birth: values.dateOfBirth || null,
      preferred_language: allowedLanguages.has(values.preferredLanguage) ? values.preferredLanguage : "en",
      marketing_opt_in: Boolean(values.marketingOptIn),
    };
    const { data, error } = await requireClient()
      .from("customer_profiles")
      .upsert(payload, { onConflict: "id" })
      .select("id,first_name,last_name,phone,date_of_birth,preferred_language,marketing_opt_in")
      .single();
    if (error) throw error;
    return data;
  }

  async function saveAddress(values) {
    const user = await requireUser();
    const payload = {
      user_id: user.id,
      label: String(values.label || "").trim() || null,
      full_name: String(values.fullName || "").trim(),
      phone: String(values.phone || "").trim() || null,
      address_line1: String(values.addressLine1 || "").trim(),
      address_line2: String(values.addressLine2 || "").trim() || null,
      city: String(values.city || "").trim(),
      country_code: String(values.countryCode || "AE").trim().toUpperCase(),
      is_default_shipping: Boolean(values.isDefaultShipping),
      is_default_billing: Boolean(values.isDefaultBilling),
    };
    if (!payload.full_name || !payload.address_line1 || !payload.city) throw new Error("ADDRESS_REQUIRED_FIELDS");

    const query = requireClient().from("customer_addresses");
    const result = values.id
      ? await query.update(payload).eq("id", values.id).select().single()
      : await query.insert(payload).select().single();
    if (result.error) throw result.error;
    return result.data;
  }

  async function deleteAddress(addressId) {
    assertUuid(addressId, "INVALID_ADDRESS_ID");
    const { error } = await requireClient().from("customer_addresses").delete().eq("id", addressId);
    if (error) throw error;
  }

  async function setDefaultAddress(addressId) {
    await requireUser();
    assertUuid(addressId, "INVALID_ADDRESS_ID");
    const { error } = await requireClient().rpc("set_default_customer_address", {
      p_address_id: addressId,
      p_kind: "shipping",
    });
    if (error) throw error;
  }

  async function ensureCart() {
    const user = await requireUser();
    const supabase = requireClient();
    const existing = await supabase
      .from("shopping_carts")
      .select("id,currency")
      .eq("user_id", user.id)
      .maybeSingle();
    if (existing.error) throw existing.error;
    if (existing.data) return existing.data;

    const created = await supabase
      .from("shopping_carts")
      .insert({ user_id: user.id, currency: "AED" })
      .select("id,currency")
      .single();
    if (created.error) throw created.error;
    return created.data;
  }

  async function loadCart() {
    const cart = await ensureCart();
    const { data, error } = await requireClient()
      .from("cart_items")
      .select("id,product_id,variant_id,quantity,products(id,name,base_price,currency,status),product_variants(id,size,color,price_override,stock_quantity,is_active)")
      .eq("cart_id", cart.id)
      .order("created_at", { ascending: true });
    if (error) throw error;
    return { cart, items: data || [] };
  }

  async function setCartItem(productId, variantId, quantity) {
    assertUuid(productId, "INVALID_PRODUCT_ID");
    if (variantId) assertUuid(variantId, "INVALID_VARIANT_ID");
    const cart = await ensureCart();
    const supabase = requireClient();
    let existingQuery = supabase
      .from("cart_items")
      .select("id")
      .eq("cart_id", cart.id)
      .eq("product_id", productId);
    existingQuery = variantId
      ? existingQuery.eq("variant_id", variantId)
      : existingQuery.is("variant_id", null);
    const existing = await existingQuery.maybeSingle();
    if (existing.error) throw existing.error;

    if (Number(quantity) <= 0) {
      if (!existing.data) return null;
      const removed = await supabase.from("cart_items").delete().eq("id", existing.data.id);
      if (removed.error) throw removed.error;
      return null;
    }

    const payload = {
      cart_id: cart.id,
      product_id: productId,
      variant_id: variantId || null,
      quantity: Math.max(1, Math.trunc(Number(quantity))),
    };
    const result = existing.data
      ? await supabase.from("cart_items").update(payload).eq("id", existing.data.id).select().single()
      : await supabase.from("cart_items").insert(payload).select().single();
    if (result.error) throw result.error;
    return result.data;
  }

  async function loadOrders() {
    await requireUser();
    const { data, error } = await requireClient()
      .from("orders")
      .select("id,order_number,status,payment_status,payment_method,currency,subtotal,discount_total,shipping_total,tax_total,grand_total,shipping_address,tracking_number,tracking_url,estimated_delivery_at,placed_at,order_items(id,product_name,variant_description,quantity,unit_price,line_total),order_status_history(id,status,note,created_at,source,metadata)")
      .order("placed_at", { ascending: false });
    if (error) throw error;
    return data || [];
  }

  async function createCheckoutOrder(payload) {
    if (!config?.features?.checkout) throw new Error("CHECKOUT_DISABLED");
    await requireUser();
    const safePayload = {
      checkout_token: payload.checkoutToken || crypto.randomUUID(),
      shipping_address: payload.shippingAddress,
      billing_address: payload.billingAddress || null,
      coupon_code: payload.couponCode || null,
      payment_method: payload.paymentMethod,
    };
    const { data, error } = await requireClient().functions.invoke("create-checkout-order", {
      body: safePayload,
    });
    if (error) throw error;
    if (data?.error) throw new Error(data.error);
    return data.order;
  }

  global.KompsiaBackend = Object.freeze({
    init,
    requestEmailOtp,
    verifyEmailOtp,
    signInWithGoogle,
    signOut,
    getStaffRole,
    loadProfile,
    saveProfile,
    saveAddress,
    deleteAddress,
    setDefaultAddress,
    loadCart,
    setCartItem,
    loadOrders,
    createCheckoutOrder,
  });
})(window);
