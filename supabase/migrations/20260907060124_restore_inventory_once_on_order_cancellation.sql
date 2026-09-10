alter table public.orders
  add column if not exists stock_restored_at timestamptz;

create or replace function private.restore_order_inventory_once(
  p_order_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_item record;
  v_variant_count integer := 0;
  v_quantity_total integer := 0;
  v_restored_at timestamptz;
begin
  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  if v_order.status <> 'cancelled' then
    raise exception 'ORDER_NOT_CANCELLED';
  end if;

  if v_order.stock_restored_at is not null then
    return jsonb_build_object(
      'order_id', p_order_id,
      'restored', false,
      'already_restored', true,
      'stock_restored_at', v_order.stock_restored_at,
      'variant_count', 0,
      'quantity_total', 0
    );
  end if;

  -- Lock every tracked variant in deterministic order before changing stock.
  perform 1
  from public.product_variants v
  where v.id in (
    select distinct oi.variant_id
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.variant_id is not null
  )
    and v.track_inventory is true
  order by v.id
  for update;

  for v_item in
    select
      v.id as variant_id,
      v.product_id,
      v.stock_quantity as previous_quantity,
      sum(oi.quantity)::integer as quantity_to_restore
    from public.order_items oi
    join public.product_variants v on v.id = oi.variant_id
    where oi.order_id = p_order_id
      and v.track_inventory is true
    group by v.id, v.product_id, v.stock_quantity
    order by v.id
  loop
    update public.product_variants
    set stock_quantity = v_item.previous_quantity + v_item.quantity_to_restore,
        updated_at = now()
    where id = v_item.variant_id;

    insert into private.inventory_adjustments(
      variant_id,
      product_id,
      actor_user_id,
      adjustment_type,
      quantity_delta,
      previous_quantity,
      new_quantity,
      reason,
      order_id
    ) values (
      v_item.variant_id,
      v_item.product_id,
      (select auth.uid()),
      'return',
      v_item.quantity_to_restore,
      v_item.previous_quantity,
      v_item.previous_quantity + v_item.quantity_to_restore,
      coalesce(nullif(btrim(p_reason), ''), 'Inventory restored after order cancellation'),
      p_order_id
    );

    v_variant_count := v_variant_count + 1;
    v_quantity_total := v_quantity_total + v_item.quantity_to_restore;
  end loop;

  v_restored_at := now();

  update public.orders
  set stock_restored_at = v_restored_at,
      updated_at = now()
  where id = p_order_id;

  return jsonb_build_object(
    'order_id', p_order_id,
    'restored', true,
    'already_restored', false,
    'stock_restored_at', v_restored_at,
    'variant_count', v_variant_count,
    'quantity_total', v_quantity_total
  );
end;
$$;

revoke all on function private.restore_order_inventory_once(uuid, text) from public, anon, authenticated;
grant execute on function private.restore_order_inventory_once(uuid, text) to service_role;

create or replace function public.set_order_status_internal(
  p_order_id uuid,
  p_new_status text,
  p_note text default null,
  p_source text default 'admin',
  p_customer_visible boolean default true
)
returns public.orders
language plpgsql
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_allowed boolean := false;
begin
  if p_source is null or p_source <> all (array['system'::text,'admin'::text,'carrier'::text,'payment'::text]) then
    raise exception 'INVALID_STATUS_SOURCE';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  if p_new_status = v_order.status then
    return v_order;
  end if;

  v_allowed := case v_order.status
    when 'pending' then p_new_status = any(array['confirmed'::text,'cancelled'::text])
    when 'confirmed' then p_new_status = any(array['processing'::text,'cancelled'::text])
    when 'processing' then p_new_status = any(array['packed'::text,'cancelled'::text])
    when 'packed' then p_new_status = any(array['shipped'::text,'cancelled'::text])
    when 'shipped' then p_new_status = 'delivered'
    when 'delivered' then p_new_status = 'returned'
    when 'returned' then p_new_status = 'refunded'
    else false
  end;

  if not v_allowed then
    raise exception 'INVALID_ORDER_STATUS_TRANSITION: % -> %', v_order.status, p_new_status;
  end if;

  update public.orders
  set status = p_new_status,
      confirmed_at = case when p_new_status = 'confirmed' and confirmed_at is null then now() else confirmed_at end,
      shipped_at = case when p_new_status = 'shipped' and shipped_at is null then now() else shipped_at end,
      delivered_at = case when p_new_status = 'delivered' and delivered_at is null then now() else delivered_at end,
      cancelled_at = case when p_new_status = 'cancelled' and cancelled_at is null then now() else cancelled_at end,
      returned_at = case when p_new_status = 'returned' and returned_at is null then now() else returned_at end,
      refunded_at = case when p_new_status = 'refunded' and refunded_at is null then now() else refunded_at end,
      updated_at = now()
  where id = p_order_id
  returning * into v_order;

  if p_new_status = 'cancelled' then
    perform private.restore_order_inventory_once(
      p_order_id,
      coalesce(nullif(btrim(p_note), ''), 'Inventory restored after order cancellation')
    );

    select * into v_order
    from public.orders
    where id = p_order_id;
  end if;

  insert into public.order_status_history (
    order_id, status, note, source, is_customer_visible
  ) values (
    p_order_id, p_new_status, p_note, p_source, p_customer_visible
  );

  return v_order;
end;
$$;

