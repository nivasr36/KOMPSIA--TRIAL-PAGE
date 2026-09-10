begin;

-- One-time stock adjustment history kept outside the exposed API schema.
create table if not exists private.inventory_adjustments (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references public.product_variants(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  adjustment_type text not null check (adjustment_type in ('increase','decrease','set','order','return','correction')),
  quantity_delta integer not null,
  previous_quantity integer not null check (previous_quantity >= 0),
  new_quantity integer not null check (new_quantity >= 0),
  reason text,
  order_id uuid references public.orders(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists inventory_adjustments_variant_created_idx
  on private.inventory_adjustments(variant_id, created_at desc);
create index if not exists inventory_adjustments_product_created_idx
  on private.inventory_adjustments(product_id, created_at desc);
create index if not exists inventory_adjustments_actor_created_idx
  on private.inventory_adjustments(actor_user_id, created_at desc);
create index if not exists inventory_adjustments_order_idx
  on private.inventory_adjustments(order_id)
  where order_id is not null;

revoke all on table private.inventory_adjustments from public, anon, authenticated;

-- Staff can see full catalog including drafts/inactive records.
create policy "Staff can read all categories"
on public.categories for select
to authenticated
using ((select private.is_staff(array['owner','admin','order_manager','support']::text[])));

create policy "Staff can read all products"
on public.products for select
to authenticated
using ((select private.is_staff(array['owner','admin','order_manager','support']::text[])));

create policy "Staff can read all variants"
on public.product_variants for select
to authenticated
using ((select private.is_staff(array['owner','admin','order_manager','support']::text[])));

create policy "Staff can read all product images"
on public.product_images for select
to authenticated
using ((select private.is_staff(array['owner','admin','order_manager','support']::text[])));

create policy "Staff can read offers"
on public.offers for select
to authenticated
using ((select private.is_staff(array['owner','admin','order_manager','support']::text[])));

create policy "Staff can read offer products"
on public.offer_products for select
to authenticated
using ((select private.is_staff(array['owner','admin','order_manager','support']::text[])));

create policy "Staff can read offer categories"
on public.offer_categories for select
to authenticated
using ((select private.is_staff(array['owner','admin','order_manager','support']::text[])));

create policy "Staff can read coupons"
on public.coupons for select
to authenticated
using ((select private.is_staff(array['owner','admin','order_manager','support']::text[])));

create policy "Staff can read coupon products"
on public.coupon_products for select
to authenticated
using ((select private.is_staff(array['owner','admin','order_manager','support']::text[])));

create policy "Staff can read coupon categories"
on public.coupon_categories for select
to authenticated
using ((select private.is_staff(array['owner','admin','order_manager','support']::text[])));

-- Only Owner/Admin may create, edit or remove catalog/promotion configuration.
create policy "Owner admin manage categories"
on public.categories for all
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));

create policy "Owner admin manage products"
on public.products for all
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));

create policy "Owner admin manage variants"
on public.product_variants for all
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));

create policy "Owner admin manage product images"
on public.product_images for all
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));

create policy "Owner admin manage offers"
on public.offers for all
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));

create policy "Owner admin manage offer products"
on public.offer_products for all
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));

create policy "Owner admin manage offer categories"
on public.offer_categories for all
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));

create policy "Owner admin manage coupons"
on public.coupons for all
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));

create policy "Owner admin manage coupon products"
on public.coupon_products for all
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));

create policy "Owner admin manage coupon categories"
on public.coupon_categories for all
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));

-- Table privileges are still subject to the RLS policies above.
grant insert, update, delete on public.categories to authenticated;
grant insert, update, delete on public.products to authenticated;
grant insert, update, delete on public.product_variants to authenticated;
grant insert, update, delete on public.product_images to authenticated;
grant select, insert, update, delete on public.offers to authenticated;
grant select, insert, update, delete on public.offer_products to authenticated;
grant select, insert, update, delete on public.offer_categories to authenticated;
grant select, insert, update, delete on public.coupons to authenticated;
grant select, insert, update, delete on public.coupon_products to authenticated;
grant select, insert, update, delete on public.coupon_categories to authenticated;

-- One-time first-owner bootstrap. Never callable from a browser/user session.
create or replace function private.bootstrap_first_owner_by_email(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_email text;
begin
  if exists (select 1 from public.staff_members) then
    raise exception 'FIRST_OWNER_ALREADY_CONFIGURED';
  end if;

  select u.id, u.email
  into v_user_id, v_email
  from auth.users u
  where lower(u.email) = lower(btrim(p_email))
  limit 1;

  if v_user_id is null then
    raise exception 'AUTH_USER_NOT_FOUND';
  end if;

  insert into public.staff_members(user_id, role, display_name, is_active, created_by)
  values (v_user_id, 'owner', split_part(v_email,'@',1), true, v_user_id);

  insert into private.staff_audit_log(actor_user_id, action, entity_type, entity_id, details)
  values (v_user_id, 'first_owner_bootstrapped', 'staff_member', v_user_id, jsonb_build_object('email', v_email));

  return jsonb_build_object('user_id',v_user_id,'email',v_email,'role','owner');
end;
$$;

revoke execute on function private.bootstrap_first_owner_by_email(text) from public, anon, authenticated;
grant execute on function private.bootstrap_first_owner_by_email(text) to service_role;

-- Owner/Admin staff management for already-created Auth users.
create or replace function private.staff_set_member_internal(
  p_email text,
  p_role text,
  p_display_name text,
  p_is_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_role text;
  v_target_id uuid;
  v_target_email text;
  v_existing_role text;
  v_owner_count integer;
begin
  v_actor_role := private.current_staff_role();
  if v_actor_role not in ('owner','admin') then
    raise exception 'STAFF_MANAGEMENT_PERMISSION_REQUIRED';
  end if;

  if p_role not in ('owner','admin','order_manager','support') then
    raise exception 'INVALID_STAFF_ROLE';
  end if;

  if v_actor_role = 'admin' and p_role in ('owner','admin') then
    raise exception 'OWNER_PERMISSION_REQUIRED';
  end if;

  select u.id, u.email
  into v_target_id, v_target_email
  from auth.users u
  where lower(u.email) = lower(btrim(p_email))
  limit 1;

  if v_target_id is null then
    raise exception 'AUTH_USER_NOT_FOUND';
  end if;

  select sm.role into v_existing_role
  from public.staff_members sm
  where sm.user_id = v_target_id;

  if v_actor_role = 'admin' and v_existing_role in ('owner','admin') then
    raise exception 'OWNER_PERMISSION_REQUIRED';
  end if;

  if v_existing_role = 'owner' and (p_role <> 'owner' or coalesce(p_is_active,true) is false) then
    select count(*) into v_owner_count
    from public.staff_members sm
    where sm.role = 'owner' and sm.is_active is true;
    if v_owner_count <= 1 then
      raise exception 'CANNOT_REMOVE_LAST_OWNER';
    end if;
  end if;

  insert into public.staff_members(user_id, role, display_name, is_active, created_by)
  values (v_target_id, p_role, nullif(btrim(p_display_name),''), coalesce(p_is_active,true), (select auth.uid()))
  on conflict (user_id) do update
  set role = excluded.role,
      display_name = excluded.display_name,
      is_active = excluded.is_active,
      updated_at = now();

  perform private.log_staff_action(
    'staff_member_updated',
    'staff_member',
    v_target_id,
    jsonb_build_object('email',v_target_email,'role',p_role,'is_active',coalesce(p_is_active,true))
  );

  return jsonb_build_object(
    'user_id',v_target_id,
    'email',v_target_email,
    'role',p_role,
    'display_name',nullif(btrim(p_display_name),''),
    'is_active',coalesce(p_is_active,true)
  );
end;
$$;

revoke execute on function private.staff_set_member_internal(text,text,text,boolean) from public, anon, authenticated;
grant execute on function private.staff_set_member_internal(text,text,text,boolean) to authenticated;

create or replace function public.staff_set_member(
  p_email text,
  p_role text,
  p_display_name text default null,
  p_is_active boolean default true
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.staff_set_member_internal(p_email,p_role,p_display_name,p_is_active)
$$;

revoke execute on function public.staff_set_member(text,text,text,boolean) from public, anon;
grant execute on function public.staff_set_member(text,text,text,boolean) to authenticated;

-- Atomic stock adjustment with a mandatory audit trail.
create or replace function private.staff_adjust_inventory_internal(
  p_variant_id uuid,
  p_quantity_delta integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_variant public.product_variants%rowtype;
  v_new_quantity integer;
  v_type text;
begin
  if not (select private.is_staff(array['owner','admin','order_manager']::text[])) then
    raise exception 'INVENTORY_MANAGEMENT_PERMISSION_REQUIRED';
  end if;

  if p_quantity_delta = 0 then
    raise exception 'INVENTORY_DELTA_CANNOT_BE_ZERO';
  end if;

  if coalesce(char_length(btrim(p_reason)),0) < 3 then
    raise exception 'INVENTORY_REASON_REQUIRED';
  end if;

  select * into v_variant
  from public.product_variants
  where id = p_variant_id
  for update;

  if not found then
    raise exception 'VARIANT_NOT_FOUND';
  end if;

  v_new_quantity := v_variant.stock_quantity + p_quantity_delta;
  if v_new_quantity < 0 then
    raise exception 'INSUFFICIENT_STOCK';
  end if;

  v_type := case when p_quantity_delta > 0 then 'increase' else 'decrease' end;

  update public.product_variants
  set stock_quantity = v_new_quantity,
      updated_at = now()
  where id = p_variant_id;

  insert into private.inventory_adjustments(
    variant_id, product_id, actor_user_id, adjustment_type, quantity_delta,
    previous_quantity, new_quantity, reason
  ) values (
    v_variant.id, v_variant.product_id, (select auth.uid()), v_type, p_quantity_delta,
    v_variant.stock_quantity, v_new_quantity, btrim(p_reason)
  );

  perform private.log_staff_action(
    'inventory_adjusted',
    'product_variant',
    p_variant_id,
    jsonb_build_object('delta',p_quantity_delta,'previous',v_variant.stock_quantity,'new',v_new_quantity,'reason',btrim(p_reason))
  );

  return jsonb_build_object(
    'variant_id',p_variant_id,
    'product_id',v_variant.product_id,
    'sku',v_variant.sku,
    'previous_quantity',v_variant.stock_quantity,
    'quantity_delta',p_quantity_delta,
    'new_quantity',v_new_quantity
  );
end;
$$;

create or replace function private.staff_set_inventory_internal(
  p_variant_id uuid,
  p_new_quantity integer,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_variant public.product_variants%rowtype;
  v_delta integer;
begin
  if not (select private.is_staff(array['owner','admin','order_manager']::text[])) then
    raise exception 'INVENTORY_MANAGEMENT_PERMISSION_REQUIRED';
  end if;

  if p_new_quantity < 0 then
    raise exception 'INVALID_STOCK_QUANTITY';
  end if;

  if coalesce(char_length(btrim(p_reason)),0) < 3 then
    raise exception 'INVENTORY_REASON_REQUIRED';
  end if;

  select * into v_variant
  from public.product_variants
  where id = p_variant_id
  for update;

  if not found then
    raise exception 'VARIANT_NOT_FOUND';
  end if;

  v_delta := p_new_quantity - v_variant.stock_quantity;

  update public.product_variants
  set stock_quantity = p_new_quantity,
      updated_at = now()
  where id = p_variant_id;

  insert into private.inventory_adjustments(
    variant_id, product_id, actor_user_id, adjustment_type, quantity_delta,
    previous_quantity, new_quantity, reason
  ) values (
    v_variant.id, v_variant.product_id, (select auth.uid()), 'set', v_delta,
    v_variant.stock_quantity, p_new_quantity, btrim(p_reason)
  );

  perform private.log_staff_action(
    'inventory_set',
    'product_variant',
    p_variant_id,
    jsonb_build_object('previous',v_variant.stock_quantity,'new',p_new_quantity,'reason',btrim(p_reason))
  );

  return jsonb_build_object(
    'variant_id',p_variant_id,
    'product_id',v_variant.product_id,
    'sku',v_variant.sku,
    'previous_quantity',v_variant.stock_quantity,
    'quantity_delta',v_delta,
    'new_quantity',p_new_quantity
  );
end;
$$;

create or replace function private.staff_low_stock_internal(p_limit integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,100),1),250);
  v_result jsonb;
begin
  if not (select private.is_staff(array['owner','admin','order_manager','support']::text[])) then
    raise exception 'STAFF_ACCESS_REQUIRED';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.stock_quantity asc, q.product_name, q.sku), '[]'::jsonb)
  into v_result
  from (
    select
      v.id as variant_id,
      v.product_id,
      p.name as product_name,
      p.status as product_status,
      v.sku,
      v.color,
      v.size,
      v.stock_quantity,
      v.low_stock_threshold,
      v.allow_backorder,
      v.is_active
    from public.product_variants v
    join public.products p on p.id = v.product_id
    where v.track_inventory is true
      and v.stock_quantity <= v.low_stock_threshold
    order by v.stock_quantity asc, p.name, v.sku
    limit v_limit
  ) q;

  return v_result;
end;
$$;

create or replace function private.staff_inventory_history_internal(
  p_variant_id uuid,
  p_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,50),1),200);
  v_result jsonb;
begin
  if not (select private.is_staff(array['owner','admin','order_manager','support']::text[])) then
    raise exception 'STAFF_ACCESS_REQUIRED';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc), '[]'::jsonb)
  into v_result
  from (
    select ia.id, ia.variant_id, ia.product_id, ia.actor_user_id, ia.adjustment_type,
           ia.quantity_delta, ia.previous_quantity, ia.new_quantity, ia.reason,
           ia.order_id, ia.created_at
    from private.inventory_adjustments ia
    where p_variant_id is null or ia.variant_id = p_variant_id
    order by ia.created_at desc
    limit v_limit
  ) q;

  return v_result;
end;
$$;

revoke execute on function private.staff_adjust_inventory_internal(uuid,integer,text) from public, anon, authenticated;
revoke execute on function private.staff_set_inventory_internal(uuid,integer,text) from public, anon, authenticated;
revoke execute on function private.staff_low_stock_internal(integer) from public, anon, authenticated;
revoke execute on function private.staff_inventory_history_internal(uuid,integer) from public, anon, authenticated;
grant execute on function private.staff_adjust_inventory_internal(uuid,integer,text) to authenticated;
grant execute on function private.staff_set_inventory_internal(uuid,integer,text) to authenticated;
grant execute on function private.staff_low_stock_internal(integer) to authenticated;
grant execute on function private.staff_inventory_history_internal(uuid,integer) to authenticated;

create or replace function public.staff_adjust_inventory(
  p_variant_id uuid,
  p_quantity_delta integer,
  p_reason text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_adjust_inventory_internal(p_variant_id,p_quantity_delta,p_reason) $$;

create or replace function public.staff_set_inventory(
  p_variant_id uuid,
  p_new_quantity integer,
  p_reason text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_set_inventory_internal(p_variant_id,p_new_quantity,p_reason) $$;

create or replace function public.staff_low_stock(p_limit integer default 100)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_low_stock_internal(p_limit) $$;

create or replace function public.staff_inventory_history(
  p_variant_id uuid default null,
  p_limit integer default 50
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_inventory_history_internal(p_variant_id,p_limit) $$;

revoke execute on function public.staff_adjust_inventory(uuid,integer,text) from public, anon;
revoke execute on function public.staff_set_inventory(uuid,integer,text) from public, anon;
revoke execute on function public.staff_low_stock(integer) from public, anon;
revoke execute on function public.staff_inventory_history(uuid,integer) from public, anon;
grant execute on function public.staff_adjust_inventory(uuid,integer,text) to authenticated;
grant execute on function public.staff_set_inventory(uuid,integer,text) to authenticated;
grant execute on function public.staff_low_stock(integer) to authenticated;
grant execute on function public.staff_inventory_history(uuid,integer) to authenticated;

-- Lightweight catalog/promotion audit trail for authenticated staff edits.
create or replace function private.audit_staff_catalog_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
  v_entity_id uuid;
  v_details jsonb;
begin
  if v_actor is null or not private.is_staff(array['owner','admin','order_manager']::text[]) then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    v_entity_id := case when to_jsonb(old) ? 'id' then nullif(to_jsonb(old)->>'id','')::uuid else null end;
    v_details := jsonb_build_object('operation',tg_op,'table',tg_table_name);
  else
    v_entity_id := case when to_jsonb(new) ? 'id' then nullif(to_jsonb(new)->>'id','')::uuid else null end;
    v_details := jsonb_build_object('operation',tg_op,'table',tg_table_name);
  end if;

  insert into private.staff_audit_log(actor_user_id,action,entity_type,entity_id,details)
  values (v_actor,'catalog_change',tg_table_name,v_entity_id,v_details);

  return coalesce(new, old);
end;
$$;

revoke execute on function private.audit_staff_catalog_change() from public, anon, authenticated;

create trigger audit_categories_staff_change after insert or update or delete on public.categories
for each row execute function private.audit_staff_catalog_change();
create trigger audit_products_staff_change after insert or update or delete on public.products
for each row execute function private.audit_staff_catalog_change();
create trigger audit_variants_staff_change after insert or update or delete on public.product_variants
for each row execute function private.audit_staff_catalog_change();
create trigger audit_product_images_staff_change after insert or update or delete on public.product_images
for each row execute function private.audit_staff_catalog_change();
create trigger audit_offers_staff_change after insert or update or delete on public.offers
for each row execute function private.audit_staff_catalog_change();
create trigger audit_coupons_staff_change after insert or update or delete on public.coupons
for each row execute function private.audit_staff_catalog_change();

commit;
