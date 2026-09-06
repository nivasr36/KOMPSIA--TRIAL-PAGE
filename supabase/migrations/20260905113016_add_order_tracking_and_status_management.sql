begin;

-- Payment methods: align the order table with the checkout settings.
alter table public.orders drop constraint if exists orders_payment_method_check;
alter table public.orders
  add constraint orders_payment_method_check
  check (payment_method is null or payment_method = any (array[
    'card'::text,
    'apple_pay'::text,
    'google_pay'::text,
    'cod'::text,
    'tabby'::text,
    'tamara'::text,
    'wallet'::text,
    'bank_transfer'::text
  ]));

-- Additional fulfillment/tracking milestones.
alter table public.orders
  add column if not exists tracking_url text,
  add column if not exists estimated_delivery_at timestamptz,
  add column if not exists returned_at timestamptz,
  add column if not exists refunded_at timestamptz;

-- Make status history suitable for both customer-visible and internal events.
alter table public.order_status_history
  add column if not exists source text not null default 'system',
  add column if not exists is_customer_visible boolean not null default true,
  add column if not exists metadata jsonb not null default '{}'::jsonb;

alter table public.order_status_history drop constraint if exists order_status_history_source_check;
alter table public.order_status_history
  add constraint order_status_history_source_check
  check (source = any (array['system'::text,'admin'::text,'customer'::text,'carrier'::text,'payment'::text]));

create index if not exists order_status_history_order_created_idx
  on public.order_status_history(order_id, created_at desc);

-- Customers should only see status-history events intended for them.
drop policy if exists "Customers can read own order history" on public.order_status_history;
create policy "Customers can read own visible order history"
on public.order_status_history for select
to authenticated
using (
  is_customer_visible is true
  and exists (
    select 1
    from public.orders o
    where o.id = order_status_history.order_id
      and o.user_id = (select auth.uid())
  )
);

-- Expose only the new tracking columns that are safe for customers to read.
grant select (
  tracking_url,
  estimated_delivery_at,
  returned_at,
  refunded_at
) on public.orders to authenticated;

-- Customer cancellation/return request queue.
create table public.order_change_requests (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  request_type text not null check (request_type = any (array['cancellation'::text,'return'::text])),
  status text not null default 'pending' check (status = any (array['pending'::text,'approved'::text,'rejected'::text,'completed'::text,'cancelled'::text])),
  reason text not null check (char_length(btrim(reason)) between 3 and 1000),
  customer_note text,
  admin_response text,
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index order_change_requests_one_pending_per_type
  on public.order_change_requests(order_id, request_type)
  where status = 'pending';
create index order_change_requests_user_created_idx
  on public.order_change_requests(user_id, created_at desc);
create index order_change_requests_order_idx
  on public.order_change_requests(order_id);

create trigger order_change_requests_set_updated_at
before update on public.order_change_requests
for each row execute function private.set_updated_at();

alter table public.order_change_requests enable row level security;
revoke all on table public.order_change_requests from anon, authenticated;

grant select on table public.order_change_requests to authenticated;
grant insert (order_id, user_id, request_type, reason, customer_note)
  on public.order_change_requests to authenticated;

create policy "Customers can read own order change requests"
on public.order_change_requests for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Customers can request eligible order changes"
on public.order_change_requests for insert
to authenticated
with check (
  (select auth.uid()) = user_id
  and exists (
    select 1
    from public.orders o
    where o.id = order_change_requests.order_id
      and o.user_id = (select auth.uid())
      and (
        (
          order_change_requests.request_type = 'cancellation'
          and o.status = any (array['pending'::text,'confirmed'::text,'processing'::text,'packed'::text])
        )
        or
        (
          order_change_requests.request_type = 'return'
          and o.status = 'delivered'
        )
      )
  )
);

-- Service-side order lifecycle function. It is not callable by browsers.
create or replace function public.set_order_status_internal(
  p_order_id uuid,
  p_new_status text,
  p_note text default null,
  p_source text default 'admin',
  p_customer_visible boolean default true
)
returns public.orders
language plpgsql
security invoker
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

  insert into public.order_status_history (
    order_id, status, note, source, is_customer_visible
  ) values (
    p_order_id, p_new_status, p_note, p_source, p_customer_visible
  );

  return v_order;
end;
$$;

revoke execute on function public.set_order_status_internal(uuid, text, text, text, boolean)
from public, anon, authenticated;
grant execute on function public.set_order_status_internal(uuid, text, text, text, boolean)
to service_role;

-- Service-side fulfillment/tracking details. Also not callable by browsers.
create or replace function public.update_order_tracking_internal(
  p_order_id uuid,
  p_carrier text,
  p_tracking_number text,
  p_tracking_url text default null,
  p_estimated_delivery_at timestamptz default null,
  p_customer_visible boolean default true
)
returns public.orders
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
begin
  if coalesce(btrim(p_carrier), '') = '' or coalesce(btrim(p_tracking_number), '') = '' then
    raise exception 'TRACKING_DETAILS_REQUIRED';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  if v_order.status not in ('packed','shipped') then
    raise exception 'ORDER_NOT_READY_FOR_TRACKING';
  end if;

  update public.orders
  set carrier = btrim(p_carrier),
      tracking_number = btrim(p_tracking_number),
      tracking_url = nullif(btrim(p_tracking_url), ''),
      estimated_delivery_at = p_estimated_delivery_at,
      updated_at = now()
  where id = p_order_id
  returning * into v_order;

  insert into public.order_status_history (
    order_id, status, note, source, is_customer_visible, metadata
  ) values (
    p_order_id,
    v_order.status,
    'Tracking details updated',
    'carrier',
    p_customer_visible,
    jsonb_build_object(
      'carrier', v_order.carrier,
      'tracking_number', v_order.tracking_number,
      'tracking_url', v_order.tracking_url,
      'estimated_delivery_at', v_order.estimated_delivery_at
    )
  );

  return v_order;
end;
$$;

revoke execute on function public.update_order_tracking_internal(uuid, text, text, text, timestamptz, boolean)
from public, anon, authenticated;
grant execute on function public.update_order_tracking_internal(uuid, text, text, text, timestamptz, boolean)
to service_role;

commit;
