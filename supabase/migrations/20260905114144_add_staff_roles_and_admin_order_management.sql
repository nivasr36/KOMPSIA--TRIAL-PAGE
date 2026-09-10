begin;

create table if not exists public.staff_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','admin','order_manager','support')),
  display_name text,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.staff_members enable row level security;

revoke all on table public.staff_members from anon, authenticated;
grant select on table public.staff_members to authenticated;

create trigger staff_members_set_updated_at
before update on public.staff_members
for each row execute function private.set_updated_at();

create table if not exists private.staff_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists staff_audit_log_actor_created_idx
  on private.staff_audit_log(actor_user_id, created_at desc);
create index if not exists staff_audit_log_entity_idx
  on private.staff_audit_log(entity_type, entity_id, created_at desc);

revoke all on table private.staff_audit_log from public, anon, authenticated;

grant usage on schema private to authenticated;

create or replace function private.current_staff_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select sm.role
  from public.staff_members sm
  where sm.user_id = (select auth.uid())
    and sm.is_active is true
  limit 1
$$;

create or replace function private.is_staff(p_allowed_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_members sm
    where sm.user_id = (select auth.uid())
      and sm.is_active is true
      and (p_allowed_roles is null or sm.role = any(p_allowed_roles))
  )
$$;

create or replace function private.log_staff_action(
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_details jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.staff_audit_log(actor_user_id, action, entity_type, entity_id, details)
  values ((select auth.uid()), p_action, p_entity_type, p_entity_id, coalesce(p_details, '{}'::jsonb));
end;
$$;

revoke execute on function private.current_staff_role() from public, anon;
revoke execute on function private.is_staff(text[]) from public, anon;
revoke execute on function private.log_staff_action(text,text,uuid,jsonb) from public, anon, authenticated;
grant execute on function private.current_staff_role() to authenticated;
grant execute on function private.is_staff(text[]) to authenticated;

create policy "Staff can read own staff record"
on public.staff_members for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Owners and admins can read staff directory"
on public.staff_members for select
to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

create or replace function private.staff_list_orders_internal(
  p_status text,
  p_limit integer,
  p_offset integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,50),1),100);
  v_offset integer := greatest(coalesce(p_offset,0),0);
  v_result jsonb;
begin
  if not (select private.is_staff(array['owner','admin','order_manager','support']::text[])) then
    raise exception 'STAFF_ACCESS_REQUIRED';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.placed_at desc), '[]'::jsonb)
  into v_result
  from (
    select
      o.id,
      o.order_number,
      o.customer_email,
      o.customer_phone,
      o.status,
      o.payment_status,
      o.payment_method,
      o.currency,
      o.subtotal,
      o.discount_total,
      o.shipping_total,
      o.tax_total,
      o.grand_total,
      o.coupon_code,
      o.carrier,
      o.tracking_number,
      o.tracking_url,
      o.estimated_delivery_at,
      o.placed_at,
      o.confirmed_at,
      o.shipped_at,
      o.delivered_at,
      o.cancelled_at,
      o.returned_at,
      o.refunded_at,
      o.updated_at
    from public.orders o
    where p_status is null or o.status = p_status
    order by o.placed_at desc
    limit v_limit offset v_offset
  ) q;

  return v_result;
end;
$$;

create or replace function private.staff_get_order_details_internal(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if not (select private.is_staff(array['owner','admin','order_manager','support']::text[])) then
    raise exception 'STAFF_ACCESS_REQUIRED';
  end if;

  select jsonb_build_object(
    'order', jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'user_id', o.user_id,
      'customer_email', o.customer_email,
      'customer_phone', o.customer_phone,
      'status', o.status,
      'payment_status', o.payment_status,
      'payment_method', o.payment_method,
      'currency', o.currency,
      'subtotal', o.subtotal,
      'discount_total', o.discount_total,
      'shipping_total', o.shipping_total,
      'tax_total', o.tax_total,
      'grand_total', o.grand_total,
      'coupon_code', o.coupon_code,
      'shipping_address', o.shipping_address,
      'billing_address', o.billing_address,
      'customer_notes', o.customer_notes,
      'admin_notes', o.admin_notes,
      'carrier', o.carrier,
      'tracking_number', o.tracking_number,
      'tracking_url', o.tracking_url,
      'estimated_delivery_at', o.estimated_delivery_at,
      'placed_at', o.placed_at,
      'confirmed_at', o.confirmed_at,
      'shipped_at', o.shipped_at,
      'delivered_at', o.delivered_at,
      'cancelled_at', o.cancelled_at,
      'returned_at', o.returned_at,
      'refunded_at', o.refunded_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at
    ),
    'items', coalesce((
      select jsonb_agg(to_jsonb(oi) order by oi.created_at)
      from public.order_items oi
      where oi.order_id = o.id
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(to_jsonb(h) order by h.created_at)
      from public.order_status_history h
      where h.order_id = o.id
    ), '[]'::jsonb),
    'change_requests', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.requested_at desc)
      from public.order_change_requests r
      where r.order_id = o.id
    ), '[]'::jsonb)
  )
  into v_result
  from public.orders o
  where o.id = p_order_id;

  if v_result is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  return v_result;
end;
$$;

create or replace function private.staff_list_change_requests_internal(
  p_status text,
  p_limit integer,
  p_offset integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,50),1),100);
  v_offset integer := greatest(coalesce(p_offset,0),0);
  v_result jsonb;
begin
  if not (select private.is_staff(array['owner','admin','order_manager','support']::text[])) then
    raise exception 'STAFF_ACCESS_REQUIRED';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.requested_at desc), '[]'::jsonb)
  into v_result
  from (
    select
      r.id,
      r.order_id,
      o.order_number,
      r.user_id,
      o.customer_email,
      r.request_type,
      r.status,
      r.reason,
      r.customer_note,
      r.admin_response,
      r.requested_at,
      r.reviewed_at,
      r.completed_at,
      r.updated_at
    from public.order_change_requests r
    join public.orders o on o.id = r.order_id
    where p_status is null or r.status = p_status
    order by r.requested_at desc
    limit v_limit offset v_offset
  ) q;

  return v_result;
end;
$$;

create or replace function private.staff_update_order_status_internal(
  p_order_id uuid,
  p_new_status text,
  p_note text,
  p_customer_visible boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if not (select private.is_staff(array['owner','admin','order_manager']::text[])) then
    raise exception 'ORDER_MANAGEMENT_PERMISSION_REQUIRED';
  end if;

  perform public.set_order_status_internal(
    p_order_id,
    p_new_status,
    p_note,
    'admin',
    coalesce(p_customer_visible,true)
  );

  perform private.log_staff_action(
    'order_status_changed',
    'order',
    p_order_id,
    jsonb_build_object('new_status', p_new_status, 'note', p_note)
  );

  select jsonb_build_object(
    'id', o.id,
    'order_number', o.order_number,
    'status', o.status,
    'confirmed_at', o.confirmed_at,
    'shipped_at', o.shipped_at,
    'delivered_at', o.delivered_at,
    'cancelled_at', o.cancelled_at,
    'returned_at', o.returned_at,
    'refunded_at', o.refunded_at,
    'updated_at', o.updated_at
  ) into v_result
  from public.orders o
  where o.id = p_order_id;

  return v_result;
end;
$$;

create or replace function private.staff_update_order_tracking_internal(
  p_order_id uuid,
  p_carrier text,
  p_tracking_number text,
  p_tracking_url text,
  p_estimated_delivery_at timestamptz,
  p_customer_visible boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if not (select private.is_staff(array['owner','admin','order_manager']::text[])) then
    raise exception 'ORDER_MANAGEMENT_PERMISSION_REQUIRED';
  end if;

  perform public.update_order_tracking_internal(
    p_order_id,
    p_carrier,
    p_tracking_number,
    p_tracking_url,
    p_estimated_delivery_at,
    coalesce(p_customer_visible,true)
  );

  perform private.log_staff_action(
    'order_tracking_updated',
    'order',
    p_order_id,
    jsonb_build_object(
      'carrier', p_carrier,
      'tracking_number', p_tracking_number,
      'estimated_delivery_at', p_estimated_delivery_at
    )
  );

  select jsonb_build_object(
    'id', o.id,
    'order_number', o.order_number,
    'carrier', o.carrier,
    'tracking_number', o.tracking_number,
    'tracking_url', o.tracking_url,
    'estimated_delivery_at', o.estimated_delivery_at,
    'updated_at', o.updated_at
  ) into v_result
  from public.orders o
  where o.id = p_order_id;

  return v_result;
end;
$$;

create or replace function private.staff_update_payment_status_internal(
  p_order_id uuid,
  p_new_payment_status text,
  p_note text,
  p_customer_visible boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_status text;
  v_order_status text;
  v_order_number text;
begin
  if not (select private.is_staff(array['owner','admin','order_manager']::text[])) then
    raise exception 'ORDER_MANAGEMENT_PERMISSION_REQUIRED';
  end if;

  select o.payment_status, o.status, o.order_number
  into v_old_status, v_order_status, v_order_number
  from public.orders o
  where o.id = p_order_id
  for update;

  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  if p_new_payment_status not in ('unpaid','pending','paid','partially_refunded','refunded','failed','cancelled') then
    raise exception 'INVALID_PAYMENT_STATUS';
  end if;

  if v_old_status <> p_new_payment_status and not (
       (v_old_status = 'unpaid' and p_new_payment_status in ('pending','paid','failed','cancelled'))
    or (v_old_status = 'pending' and p_new_payment_status in ('paid','failed','cancelled'))
    or (v_old_status = 'failed' and p_new_payment_status in ('pending','paid','cancelled'))
    or (v_old_status = 'paid' and p_new_payment_status in ('partially_refunded','refunded'))
    or (v_old_status = 'partially_refunded' and p_new_payment_status = 'refunded')
  ) then
    raise exception 'INVALID_PAYMENT_STATUS_TRANSITION';
  end if;

  update public.orders
  set payment_status = p_new_payment_status,
      refunded_at = case when p_new_payment_status = 'refunded' then coalesce(refunded_at, now()) else refunded_at end,
      updated_at = now()
  where id = p_order_id;

  if v_old_status <> p_new_payment_status then
    insert into public.order_status_history(order_id,status,note,source,is_customer_visible,metadata)
    values (
      p_order_id,
      v_order_status,
      coalesce(nullif(btrim(p_note),''), 'Payment status updated'),
      'admin',
      coalesce(p_customer_visible,true),
      jsonb_build_object('event','payment_status_changed','from',v_old_status,'to',p_new_payment_status)
    );
  end if;

  perform private.log_staff_action(
    'payment_status_changed',
    'order',
    p_order_id,
    jsonb_build_object('from', v_old_status, 'to', p_new_payment_status, 'note', p_note)
  );

  return jsonb_build_object(
    'id', p_order_id,
    'order_number', v_order_number,
    'payment_status', p_new_payment_status
  );
end;
$$;

create or replace function private.staff_set_order_admin_notes_internal(
  p_order_id uuid,
  p_admin_notes text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_number text;
begin
  if not (select private.is_staff(array['owner','admin','order_manager','support']::text[])) then
    raise exception 'STAFF_ACCESS_REQUIRED';
  end if;

  update public.orders
  set admin_notes = nullif(btrim(p_admin_notes),''),
      updated_at = now()
  where id = p_order_id
  returning order_number into v_order_number;

  if v_order_number is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  perform private.log_staff_action(
    'order_admin_notes_updated',
    'order',
    p_order_id,
    '{}'::jsonb
  );

  return jsonb_build_object('id', p_order_id, 'order_number', v_order_number, 'updated', true);
end;
$$;

create or replace function private.staff_review_change_request_internal(
  p_request_id uuid,
  p_decision text,
  p_admin_response text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.order_change_requests%rowtype;
begin
  if not (select private.is_staff(array['owner','admin','order_manager']::text[])) then
    raise exception 'ORDER_MANAGEMENT_PERMISSION_REQUIRED';
  end if;

  if p_decision not in ('approved','rejected') then
    raise exception 'INVALID_REQUEST_DECISION';
  end if;

  select * into v_request
  from public.order_change_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'REQUEST_NOT_FOUND';
  end if;

  if v_request.status <> 'pending' then
    raise exception 'REQUEST_ALREADY_REVIEWED';
  end if;

  update public.order_change_requests
  set status = p_decision,
      admin_response = nullif(btrim(p_admin_response),''),
      reviewed_at = now(),
      updated_at = now()
  where id = p_request_id;

  perform private.log_staff_action(
    'order_change_request_reviewed',
    'order_change_request',
    p_request_id,
    jsonb_build_object('decision', p_decision, 'order_id', v_request.order_id)
  );

  return jsonb_build_object(
    'id', p_request_id,
    'order_id', v_request.order_id,
    'request_type', v_request.request_type,
    'status', p_decision
  );
end;
$$;

create or replace function private.staff_complete_change_request_internal(
  p_request_id uuid,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.order_change_requests%rowtype;
begin
  if not (select private.is_staff(array['owner','admin','order_manager']::text[])) then
    raise exception 'ORDER_MANAGEMENT_PERMISSION_REQUIRED';
  end if;

  select * into v_request
  from public.order_change_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'REQUEST_NOT_FOUND';
  end if;

  if v_request.status <> 'approved' then
    raise exception 'REQUEST_NOT_APPROVED';
  end if;

  if v_request.request_type = 'cancellation' then
    perform public.set_order_status_internal(
      v_request.order_id,
      'cancelled',
      coalesce(nullif(btrim(p_note),''),'Approved cancellation completed'),
      'admin',
      true
    );
  elsif v_request.request_type = 'return' then
    perform public.set_order_status_internal(
      v_request.order_id,
      'returned',
      coalesce(nullif(btrim(p_note),''),'Approved return completed'),
      'admin',
      true
    );
  else
    raise exception 'INVALID_REQUEST_TYPE';
  end if;

  update public.order_change_requests
  set status = 'completed',
      completed_at = now(),
      updated_at = now()
  where id = p_request_id;

  perform private.log_staff_action(
    'order_change_request_completed',
    'order_change_request',
    p_request_id,
    jsonb_build_object('request_type', v_request.request_type, 'order_id', v_request.order_id)
  );

  return jsonb_build_object(
    'id', p_request_id,
    'order_id', v_request.order_id,
    'request_type', v_request.request_type,
    'status', 'completed'
  );
end;
$$;

revoke execute on function private.staff_list_orders_internal(text,integer,integer) from public, anon, authenticated;
revoke execute on function private.staff_get_order_details_internal(uuid) from public, anon, authenticated;
revoke execute on function private.staff_list_change_requests_internal(text,integer,integer) from public, anon, authenticated;
revoke execute on function private.staff_update_order_status_internal(uuid,text,text,boolean) from public, anon, authenticated;
revoke execute on function private.staff_update_order_tracking_internal(uuid,text,text,text,timestamptz,boolean) from public, anon, authenticated;
revoke execute on function private.staff_update_payment_status_internal(uuid,text,text,boolean) from public, anon, authenticated;
revoke execute on function private.staff_set_order_admin_notes_internal(uuid,text) from public, anon, authenticated;
revoke execute on function private.staff_review_change_request_internal(uuid,text,text) from public, anon, authenticated;
revoke execute on function private.staff_complete_change_request_internal(uuid,text) from public, anon, authenticated;

grant execute on function private.staff_list_orders_internal(text,integer,integer) to authenticated;
grant execute on function private.staff_get_order_details_internal(uuid) to authenticated;
grant execute on function private.staff_list_change_requests_internal(text,integer,integer) to authenticated;
grant execute on function private.staff_update_order_status_internal(uuid,text,text,boolean) to authenticated;
grant execute on function private.staff_update_order_tracking_internal(uuid,text,text,text,timestamptz,boolean) to authenticated;
grant execute on function private.staff_update_payment_status_internal(uuid,text,text,boolean) to authenticated;
grant execute on function private.staff_set_order_admin_notes_internal(uuid,text) to authenticated;
grant execute on function private.staff_review_change_request_internal(uuid,text,text) to authenticated;
grant execute on function private.staff_complete_change_request_internal(uuid,text) to authenticated;

create or replace function public.staff_my_role()
returns text
language sql
security invoker
set search_path = ''
as $$ select private.current_staff_role() $$;

create or replace function public.staff_list_orders(
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_list_orders_internal(p_status,p_limit,p_offset) $$;

create or replace function public.staff_get_order_details(p_order_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_get_order_details_internal(p_order_id) $$;

create or replace function public.staff_list_change_requests(
  p_status text default 'pending',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_list_change_requests_internal(p_status,p_limit,p_offset) $$;

create or replace function public.staff_update_order_status(
  p_order_id uuid,
  p_new_status text,
  p_note text default null,
  p_customer_visible boolean default true
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_update_order_status_internal(p_order_id,p_new_status,p_note,p_customer_visible) $$;

create or replace function public.staff_update_order_tracking(
  p_order_id uuid,
  p_carrier text,
  p_tracking_number text,
  p_tracking_url text default null,
  p_estimated_delivery_at timestamptz default null,
  p_customer_visible boolean default true
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_update_order_tracking_internal(p_order_id,p_carrier,p_tracking_number,p_tracking_url,p_estimated_delivery_at,p_customer_visible) $$;

create or replace function public.staff_update_payment_status(
  p_order_id uuid,
  p_new_payment_status text,
  p_note text default null,
  p_customer_visible boolean default true
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_update_payment_status_internal(p_order_id,p_new_payment_status,p_note,p_customer_visible) $$;

create or replace function public.staff_set_order_admin_notes(
  p_order_id uuid,
  p_admin_notes text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_set_order_admin_notes_internal(p_order_id,p_admin_notes) $$;

create or replace function public.staff_review_change_request(
  p_request_id uuid,
  p_decision text,
  p_admin_response text default null
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_review_change_request_internal(p_request_id,p_decision,p_admin_response) $$;

create or replace function public.staff_complete_change_request(
  p_request_id uuid,
  p_note text default null
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.staff_complete_change_request_internal(p_request_id,p_note) $$;

revoke execute on function public.staff_my_role() from public, anon;
revoke execute on function public.staff_list_orders(text,integer,integer) from public, anon;
revoke execute on function public.staff_get_order_details(uuid) from public, anon;
revoke execute on function public.staff_list_change_requests(text,integer,integer) from public, anon;
revoke execute on function public.staff_update_order_status(uuid,text,text,boolean) from public, anon;
revoke execute on function public.staff_update_order_tracking(uuid,text,text,text,timestamptz,boolean) from public, anon;
revoke execute on function public.staff_update_payment_status(uuid,text,text,boolean) from public, anon;
revoke execute on function public.staff_set_order_admin_notes(uuid,text) from public, anon;
revoke execute on function public.staff_review_change_request(uuid,text,text) from public, anon;
revoke execute on function public.staff_complete_change_request(uuid,text) from public, anon;

grant execute on function public.staff_my_role() to authenticated;
grant execute on function public.staff_list_orders(text,integer,integer) to authenticated;
grant execute on function public.staff_get_order_details(uuid) to authenticated;
grant execute on function public.staff_list_change_requests(text,integer,integer) to authenticated;
grant execute on function public.staff_update_order_status(uuid,text,text,boolean) to authenticated;
grant execute on function public.staff_update_order_tracking(uuid,text,text,text,timestamptz,boolean) to authenticated;
grant execute on function public.staff_update_payment_status(uuid,text,text,boolean) to authenticated;
grant execute on function public.staff_set_order_admin_notes(uuid,text) to authenticated;
grant execute on function public.staff_review_change_request(uuid,text,text) to authenticated;
grant execute on function public.staff_complete_change_request(uuid,text) to authenticated;

commit;
