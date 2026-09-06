begin;

alter table public.orders
  add column if not exists checkout_token uuid;

create unique index if not exists orders_checkout_token_unique
  on public.orders(checkout_token)
  where checkout_token is not null;

create table if not exists private.checkout_settings (
  id smallint primary key default 1 check (id = 1),
  checkout_enabled boolean not null default false,
  default_currency char(3) not null default 'AED',
  shipping_enabled boolean not null default false,
  flat_shipping_fee numeric(12,2) not null default 0 check (flat_shipping_fee >= 0),
  free_shipping_threshold numeric(12,2) check (free_shipping_threshold is null or free_shipping_threshold >= 0),
  tax_enabled boolean not null default false,
  tax_rate numeric(5,2) not null default 0 check (tax_rate >= 0 and tax_rate <= 100),
  prices_include_tax boolean not null default false,
  tax_shipping boolean not null default false,
  enabled_payment_methods text[] not null default '{}',
  updated_at timestamptz not null default now()
);

insert into private.checkout_settings (id)
values (1)
on conflict (id) do nothing;

create table if not exists private.coupon_redemptions (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references public.coupons(id) on delete restrict,
  user_id uuid references auth.users(id) on delete set null,
  order_id uuid not null references public.orders(id) on delete restrict,
  discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  created_at timestamptz not null default now(),
  unique (coupon_id, order_id)
);

create index if not exists coupon_redemptions_coupon_user_idx
  on private.coupon_redemptions(coupon_id, user_id);

revoke all on table private.checkout_settings from public, anon, authenticated;
revoke all on table private.coupon_redemptions from public, anon, authenticated;

revoke select on table public.orders from authenticated;
grant select (
  id,
  order_number,
  user_id,
  customer_email,
  customer_phone,
  status,
  payment_status,
  payment_method,
  currency,
  subtotal,
  discount_total,
  shipping_total,
  tax_total,
  grand_total,
  coupon_code,
  shipping_address,
  billing_address,
  customer_notes,
  tracking_number,
  carrier,
  placed_at,
  confirmed_at,
  shipped_at,
  delivered_at,
  cancelled_at,
  created_at,
  updated_at
) on public.orders to authenticated;

create or replace function public.create_checkout_order_internal(
  p_user_id uuid,
  p_checkout_token uuid,
  p_shipping_address jsonb,
  p_billing_address jsonb,
  p_coupon_code text,
  p_payment_method text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_settings private.checkout_settings%rowtype;
  v_coupon public.coupons%rowtype;
  v_cart_id uuid;
  v_order_id uuid;
  v_order_number text;
  v_email text;
  v_phone text;
  v_subtotal numeric(12,2) := 0;
  v_eligible_subtotal numeric(12,2) := 0;
  v_discount numeric(12,2) := 0;
  v_shipping numeric(12,2) := 0;
  v_tax numeric(12,2) := 0;
  v_tax_base numeric(12,2) := 0;
  v_grand_total numeric(12,2) := 0;
  v_net numeric(12,2) := 0;
  v_free_shipping boolean := false;
  v_coupon_code text := null;
  v_existing jsonb;
begin
  if p_user_id is null or p_checkout_token is null then
    raise exception 'INVALID_CHECKOUT_REQUEST';
  end if;

  select jsonb_build_object(
    'order_id', o.id,
    'order_number', o.order_number,
    'status', o.status,
    'payment_status', o.payment_status,
    'currency', o.currency,
    'subtotal', o.subtotal,
    'discount_total', o.discount_total,
    'shipping_total', o.shipping_total,
    'tax_total', o.tax_total,
    'grand_total', o.grand_total,
    'duplicate', true
  )
  into v_existing
  from public.orders o
  where o.checkout_token = p_checkout_token
    and o.user_id = p_user_id
  limit 1;

  if v_existing is not null then
    return v_existing;
  end if;

  select *
  into v_settings
  from private.checkout_settings
  where id = 1
  for update;

  if not found or v_settings.checkout_enabled is not true then
    raise exception 'CHECKOUT_DISABLED';
  end if;

  if p_payment_method is null
     or not (p_payment_method = any(v_settings.enabled_payment_methods)) then
    raise exception 'PAYMENT_METHOD_NOT_ENABLED';
  end if;

  if p_shipping_address is null
     or jsonb_typeof(p_shipping_address) <> 'object'
     or coalesce(btrim(p_shipping_address->>'full_name'), '') = ''
     or coalesce(btrim(p_shipping_address->>'address_line1'), '') = ''
     or coalesce(btrim(p_shipping_address->>'city'), '') = ''
     or length(coalesce(btrim(p_shipping_address->>'country_code'), '')) <> 2 then
    raise exception 'INVALID_SHIPPING_ADDRESS';
  end if;

  if p_billing_address is not null and jsonb_typeof(p_billing_address) <> 'object' then
    raise exception 'INVALID_BILLING_ADDRESS';
  end if;

  select u.email
  into v_email
  from auth.users u
  where u.id = p_user_id;

  if v_email is null then
    raise exception 'CUSTOMER_NOT_FOUND';
  end if;

  select cp.phone
  into v_phone
  from public.customer_profiles cp
  where cp.id = p_user_id;

  select c.id
  into v_cart_id
  from public.shopping_carts c
  where c.user_id = p_user_id
  for update;

  if v_cart_id is null then
    raise exception 'CART_EMPTY';
  end if;

  if not exists (
    select 1 from public.cart_items ci where ci.cart_id = v_cart_id
  ) then
    raise exception 'CART_EMPTY';
  end if;

  perform 1
  from public.product_variants v
  join public.cart_items ci on ci.variant_id = v.id
  where ci.cart_id = v_cart_id
  order by v.id
  for update of v;

  if exists (
    select 1
    from public.cart_items ci
    left join public.products p on p.id = ci.product_id
    left join public.product_variants v on v.id = ci.variant_id
    where ci.cart_id = v_cart_id
      and (
        p.id is null
        or p.status <> 'active'
        or p.currency <> v_settings.default_currency
        or (
          ci.variant_id is not null
          and (
            v.id is null
            or v.product_id <> p.id
            or v.is_active is not true
          )
        )
      )
  ) then
    raise exception 'CART_CONTAINS_UNAVAILABLE_ITEM';
  end if;

  if exists (
    select 1
    from public.cart_items ci
    join public.product_variants v on v.id = ci.variant_id
    where ci.cart_id = v_cart_id
      and v.track_inventory is true
      and v.allow_backorder is false
      and v.stock_quantity < ci.quantity
  ) then
    raise exception 'INSUFFICIENT_STOCK';
  end if;

  select round(coalesce(sum(
    ci.quantity * coalesce(v.price_override, p.base_price)
  ), 0), 2)
  into v_subtotal
  from public.cart_items ci
  join public.products p on p.id = ci.product_id
  left join public.product_variants v on v.id = ci.variant_id
  where ci.cart_id = v_cart_id;

  if v_subtotal <= 0 then
    raise exception 'INVALID_CART_TOTAL';
  end if;

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    select *
    into v_coupon
    from public.coupons c
    where c.code = upper(btrim(p_coupon_code))
    for update;

    if not found
       or v_coupon.is_active is not true
       or (v_coupon.starts_at is not null and v_coupon.starts_at > now())
       or (v_coupon.ends_at is not null and v_coupon.ends_at <= now())
       or v_coupon.currency <> v_settings.default_currency then
      raise exception 'COUPON_INVALID';
    end if;

    if v_coupon.min_order_amount is not null
       and v_subtotal < v_coupon.min_order_amount then
      raise exception 'COUPON_MINIMUM_NOT_MET';
    end if;

    if v_coupon.usage_limit_total is not null
       and v_coupon.usage_count >= v_coupon.usage_limit_total then
      raise exception 'COUPON_USAGE_LIMIT_REACHED';
    end if;

    if v_coupon.usage_limit_per_customer is not null
       and (
         select count(*)
         from private.coupon_redemptions cr
         where cr.coupon_id = v_coupon.id
           and cr.user_id = p_user_id
       ) >= v_coupon.usage_limit_per_customer then
      raise exception 'COUPON_CUSTOMER_LIMIT_REACHED';
    end if;

    if v_coupon.scope = 'all' then
      v_eligible_subtotal := v_subtotal;
    elsif v_coupon.scope = 'products' then
      select round(coalesce(sum(
        ci.quantity * coalesce(v.price_override, p.base_price)
      ), 0), 2)
      into v_eligible_subtotal
      from public.cart_items ci
      join public.products p on p.id = ci.product_id
      left join public.product_variants v on v.id = ci.variant_id
      where ci.cart_id = v_cart_id
        and exists (
          select 1
          from public.coupon_products cp
          where cp.coupon_id = v_coupon.id
            and cp.product_id = p.id
        );
    elsif v_coupon.scope = 'categories' then
      select round(coalesce(sum(
        ci.quantity * coalesce(v.price_override, p.base_price)
      ), 0), 2)
      into v_eligible_subtotal
      from public.cart_items ci
      join public.products p on p.id = ci.product_id
      left join public.product_variants v on v.id = ci.variant_id
      where ci.cart_id = v_cart_id
        and exists (
          select 1
          from public.coupon_categories cc
          where cc.coupon_id = v_coupon.id
            and cc.category_id = p.category_id
        );
    end if;

    if v_eligible_subtotal <= 0 then
      raise exception 'COUPON_NOT_APPLICABLE';
    end if;

    if v_coupon.discount_type = 'percentage' then
      v_discount := round(v_eligible_subtotal * v_coupon.discount_value / 100, 2);
    elsif v_coupon.discount_type = 'fixed' then
      v_discount := least(v_coupon.discount_value, v_eligible_subtotal);
    elsif v_coupon.discount_type = 'free_shipping' then
      v_free_shipping := true;
      v_discount := 0;
    end if;

    if v_coupon.max_discount is not null then
      v_discount := least(v_discount, v_coupon.max_discount);
    end if;

    v_discount := least(v_discount, v_subtotal);
    v_coupon_code := v_coupon.code;
  end if;

  v_net := greatest(v_subtotal - v_discount, 0);

  if v_settings.shipping_enabled is true then
    v_shipping := v_settings.flat_shipping_fee;
    if v_settings.free_shipping_threshold is not null
       and v_net >= v_settings.free_shipping_threshold then
      v_shipping := 0;
    end if;
  else
    v_shipping := 0;
  end if;

  if v_free_shipping then
    v_shipping := 0;
  end if;

  if v_settings.tax_enabled is true and v_settings.tax_rate > 0 then
    v_tax_base := v_net + case when v_settings.tax_shipping then v_shipping else 0 end;
    if v_settings.prices_include_tax is true then
      v_tax := round(v_tax_base - (v_tax_base / (1 + v_settings.tax_rate / 100)), 2);
      v_grand_total := round(v_net + v_shipping, 2);
    else
      v_tax := round(v_tax_base * v_settings.tax_rate / 100, 2);
      v_grand_total := round(v_net + v_shipping + v_tax, 2);
    end if;
  else
    v_tax := 0;
    v_grand_total := round(v_net + v_shipping, 2);
  end if;

  insert into public.orders (
    checkout_token,
    user_id,
    customer_email,
    customer_phone,
    status,
    payment_status,
    payment_method,
    currency,
    subtotal,
    discount_total,
    shipping_total,
    tax_total,
    grand_total,
    coupon_code,
    shipping_address,
    billing_address
  ) values (
    p_checkout_token,
    p_user_id,
    v_email,
    v_phone,
    'pending',
    'unpaid',
    p_payment_method,
    v_settings.default_currency,
    v_subtotal,
    v_discount,
    v_shipping,
    v_tax,
    v_grand_total,
    v_coupon_code,
    p_shipping_address,
    p_billing_address
  )
  returning id, order_number into v_order_id, v_order_number;

  insert into public.order_items (
    order_id,
    product_id,
    variant_id,
    sku,
    product_name,
    variant_description,
    quantity,
    unit_price,
    discount_total,
    tax_total,
    line_total
  )
  select
    v_order_id,
    p.id,
    v.id,
    coalesce(v.sku, p.sku),
    p.name,
    nullif(concat_ws(' / ', v.color, v.size), ''),
    ci.quantity,
    coalesce(v.price_override, p.base_price),
    0,
    0,
    round(ci.quantity * coalesce(v.price_override, p.base_price), 2)
  from public.cart_items ci
  join public.products p on p.id = ci.product_id
  left join public.product_variants v on v.id = ci.variant_id
  where ci.cart_id = v_cart_id;

  update public.product_variants v
  set stock_quantity = greatest(v.stock_quantity - ci.quantity, 0),
      updated_at = now()
  from public.cart_items ci
  where ci.cart_id = v_cart_id
    and ci.variant_id = v.id
    and v.track_inventory is true;

  insert into public.order_status_history (order_id, status, note)
  values (v_order_id, 'pending', 'Order created by secure checkout engine');

  if v_coupon_code is not null then
    update public.coupons
    set usage_count = usage_count + 1,
        updated_at = now()
    where id = v_coupon.id;

    insert into private.coupon_redemptions (
      coupon_id,
      user_id,
      order_id,
      discount_amount
    ) values (
      v_coupon.id,
      p_user_id,
      v_order_id,
      v_discount
    );
  end if;

  delete from public.cart_items where cart_id = v_cart_id;

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_order_number,
    'status', 'pending',
    'payment_status', 'unpaid',
    'currency', v_settings.default_currency,
    'subtotal', v_subtotal,
    'discount_total', v_discount,
    'shipping_total', v_shipping,
    'tax_total', v_tax,
    'grand_total', v_grand_total,
    'duplicate', false
  );
end;
$$;

revoke execute on function public.create_checkout_order_internal(uuid, uuid, jsonb, jsonb, text, text)
from public, anon, authenticated;

grant execute on function public.create_checkout_order_internal(uuid, uuid, jsonb, jsonb, text, text)
to service_role;

commit;
