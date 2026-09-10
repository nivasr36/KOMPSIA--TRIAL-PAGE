create unique index if not exists inventory_adjustments_order_variant_once_idx
on private.inventory_adjustments(order_id, variant_id)
where adjustment_type = 'order' and order_id is not null;

do $$
declare
  v_def text;
  v_old text := $old$
  update public.product_variants v
  set stock_quantity = greatest(v.stock_quantity - ci.quantity, 0),
      updated_at = now()
  from public.cart_items ci
  where ci.cart_id = v_cart_id
    and ci.variant_id = v.id
    and v.track_inventory is true;
$old$;
  v_new text := $new$
  with requested as (
    select ci.variant_id, sum(ci.quantity)::integer as quantity_requested
    from public.cart_items ci
    where ci.cart_id = v_cart_id
      and ci.variant_id is not null
    group by ci.variant_id
  ), deductions as (
    select
      v.id as variant_id,
      v.product_id,
      v.stock_quantity as previous_quantity,
      greatest(v.stock_quantity - r.quantity_requested, 0) as new_quantity
    from public.product_variants v
    join requested r on r.variant_id = v.id
    where v.track_inventory is true
  ), updated as (
    update public.product_variants v
    set stock_quantity = d.new_quantity,
        updated_at = now()
    from deductions d
    where v.id = d.variant_id
    returning v.id
  )
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
  )
  select
    d.variant_id,
    d.product_id,
    null,
    'order',
    d.new_quantity - d.previous_quantity,
    d.previous_quantity,
    d.new_quantity,
    'Inventory deducted by secure checkout',
    v_order_id
  from deductions d
  join updated u on u.id = d.variant_id;
$new$;
begin
  select pg_get_functiondef('public.create_checkout_order_internal(uuid,uuid,jsonb,jsonb,text,text)'::regprocedure)
  into v_def;

  if position(v_old in v_def) = 0 then
    raise exception 'CHECKOUT_INVENTORY_BLOCK_NOT_FOUND';
  end if;

  execute replace(v_def, v_old, v_new);
end
$$;

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
  v_variant public.product_variants%rowtype;
  v_variant_count integer := 0;
  v_quantity_total integer := 0;
  v_restored_at timestamptz;
  v_has_tracked_items boolean := false;
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

  select exists (
    select 1
    from public.order_items oi
    join public.product_variants v on v.id = oi.variant_id
    where oi.order_id = p_order_id
      and v.track_inventory is true
  ) into v_has_tracked_items;

  if v_has_tracked_items and not exists (
    select 1
    from private.inventory_adjustments ia
    where ia.order_id = p_order_id
      and ia.adjustment_type = 'order'
  ) then
    raise exception 'INVENTORY_DEDUCTION_AUDIT_MISSING';
  end if;

  perform 1
  from public.product_variants v
  where v.id in (
    select ia.variant_id
    from private.inventory_adjustments ia
    where ia.order_id = p_order_id
      and ia.adjustment_type = 'order'
  )
  order by v.id
  for update;

  for v_item in
    select
      ia.variant_id,
      ia.product_id,
      sum(greatest(-ia.quantity_delta, 0))::integer as quantity_to_restore
    from private.inventory_adjustments ia
    where ia.order_id = p_order_id
      and ia.adjustment_type = 'order'
    group by ia.variant_id, ia.product_id
    order by ia.variant_id
  loop
    select * into v_variant
    from public.product_variants
    where id = v_item.variant_id
    for update;

    if not found then
      raise exception 'VARIANT_NOT_FOUND_DURING_RESTORE';
    end if;

    if v_item.quantity_to_restore > 0 then
      update public.product_variants
      set stock_quantity = v_variant.stock_quantity + v_item.quantity_to_restore,
          updated_at = now()
      where id = v_item.variant_id;
    end if;

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
      v_variant.stock_quantity,
      v_variant.stock_quantity + v_item.quantity_to_restore,
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

