-- Preserve every historical outbox and delivery-log row while introducing a
-- deterministic key for future enqueue operations. Existing duplicate test
-- events receive a legacy suffix; the earliest row keeps the canonical key so
-- an identical event cannot be queued again.
alter table private.notification_outbox
  add column idempotency_key text;

with ranked as (
  select
    id,
    event_key || ':' || coalesce(order_id::text, 'system') || ':' || lower(btrim(recipient_email)) as base_key,
    row_number() over (
      partition by event_key, order_id, lower(btrim(recipient_email))
      order by queued_at, id
    ) as occurrence
  from private.notification_outbox
)
update private.notification_outbox o
set idempotency_key = case
  when r.occurrence = 1 then r.base_key
  else r.base_key || ':legacy:' || o.id::text
end
from ranked r
where r.id = o.id;

alter table private.notification_outbox
  alter column idempotency_key set not null,
  add constraint notification_outbox_idempotency_key_not_blank
    check (btrim(idempotency_key) <> ''),
  add constraint notification_outbox_idempotency_key_key
    unique (idempotency_key);

create or replace function private.set_notification_idempotency_key()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.idempotency_key :=
    new.event_key || ':' || coalesce(new.order_id::text, 'system') || ':' || lower(btrim(new.recipient_email));
  return new;
end;
$$;

revoke all on function private.set_notification_idempotency_key() from public;

create trigger set_notification_outbox_idempotency_key
before insert or update of event_key, order_id, recipient_email
on private.notification_outbox
for each row execute function private.set_notification_idempotency_key();

create or replace function private.queue_order_notification(
  p_order_id uuid,
  p_event_key text,
  p_template_key text,
  p_subject text,
  p_extra_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_id uuid;
  v_name text;
begin
  select * into v_order
  from public.orders
  where id = p_order_id;

  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  if coalesce(btrim(v_order.customer_email),'') = '' then
    return null;
  end if;

  v_name := nullif(btrim(coalesce(v_order.shipping_address->>'full_name','')), '');

  insert into private.notification_outbox(
    event_key,
    order_id,
    user_id,
    recipient_email,
    recipient_name,
    template_key,
    subject,
    payload
  ) values (
    p_event_key,
    v_order.id,
    v_order.user_id,
    lower(btrim(v_order.customer_email)),
    v_name,
    p_template_key,
    p_subject,
    jsonb_build_object(
      'order_number', v_order.order_number,
      'status', v_order.status,
      'payment_status', v_order.payment_status,
      'payment_method', v_order.payment_method,
      'currency', v_order.currency,
      'subtotal', v_order.subtotal,
      'discount_total', v_order.discount_total,
      'shipping_total', v_order.shipping_total,
      'tax_total', v_order.tax_total,
      'grand_total', v_order.grand_total,
      'carrier', v_order.carrier,
      'tracking_number', v_order.tracking_number,
      'tracking_url', v_order.tracking_url,
      'estimated_delivery_at', v_order.estimated_delivery_at
    ) || coalesce(p_extra_payload, '{}'::jsonb)
  )
  on conflict (idempotency_key) do update
  set payload = excluded.payload,
      subject = excluded.subject,
      template_key = excluded.template_key,
      status = case when private.notification_outbox.status = 'sent' then private.notification_outbox.status else 'pending' end,
      next_attempt_at = case when private.notification_outbox.status = 'sent' then private.notification_outbox.next_attempt_at else now() end,
      updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function private.queue_order_notification(uuid,text,text,text,jsonb) from public;

create or replace function private.queue_system_notification(
  p_event_key text,
  p_recipient_email text,
  p_recipient_name text,
  p_template_key text,
  p_subject text,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if coalesce(btrim(p_event_key), '') = '' then
    raise exception 'EVENT_KEY_REQUIRED';
  end if;
  if coalesce(btrim(p_recipient_email), '') = '' then
    raise exception 'RECIPIENT_REQUIRED';
  end if;

  insert into private.notification_outbox(
    event_key,
    order_id,
    user_id,
    recipient_email,
    recipient_name,
    template_key,
    subject,
    payload
  ) values (
    btrim(p_event_key),
    null,
    null,
    lower(btrim(p_recipient_email)),
    nullif(btrim(p_recipient_name), ''),
    btrim(p_template_key),
    btrim(p_subject),
    coalesce(p_payload, '{}'::jsonb)
  )
  on conflict (idempotency_key) do update
  set updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function private.queue_system_notification(text,text,text,text,text,jsonb) from public;

-- The scheduled invocation deliberately reads all environment-specific values
-- from Vault. The job remains inert until these two entries are configured:
--   kompsia_project_url
--   kompsia_notification_worker_token
create extension if not exists pg_cron with schema pg_catalog;

create or replace function private.invoke_notification_worker()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project_url text;
  v_worker_token text;
  v_request_id bigint;
begin
  select decrypted_secret into v_project_url
  from vault.decrypted_secrets
  where name = 'kompsia_project_url'
  order by updated_at desc
  limit 1;

  select decrypted_secret into v_worker_token
  from vault.decrypted_secrets
  where name = 'kompsia_notification_worker_token'
  order by updated_at desc
  limit 1;

  if coalesce(v_project_url, '') = ''
     or coalesce(v_worker_token, '') = '' then
    return null;
  end if;

  select net.http_post(
    url := rtrim(v_project_url, '/') || '/functions/v1/send-order-notifications',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Kompsia-Worker-Token', v_worker_token
    ),
    body := jsonb_build_object('source', 'pg_cron', 'invoked_at', now()),
    timeout_milliseconds := 10000
  ) into v_request_id;

  return v_request_id;
end;
$$;

revoke all on function private.invoke_notification_worker() from public, anon, authenticated;

create or replace function public.set_default_customer_address(
  p_address_id uuid,
  p_kind text default 'shipping'
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_kind not in ('shipping', 'billing') then
    raise exception 'INVALID_ADDRESS_KIND';
  end if;

  if not exists (
    select 1
    from public.customer_addresses
    where id = p_address_id
      and user_id = v_user_id
  ) then
    raise exception 'ADDRESS_NOT_FOUND';
  end if;

  if p_kind = 'shipping' then
    update public.customer_addresses
    set is_default_shipping = false
    where user_id = v_user_id
      and is_default_shipping;

    update public.customer_addresses
    set is_default_shipping = true
    where id = p_address_id
      and user_id = v_user_id;
  else
    update public.customer_addresses
    set is_default_billing = false
    where user_id = v_user_id
      and is_default_billing;

    update public.customer_addresses
    set is_default_billing = true
    where id = p_address_id
      and user_id = v_user_id;
  end if;
end;
$$;

revoke all on function public.set_default_customer_address(uuid, text) from public, anon;
grant execute on function public.set_default_customer_address(uuid, text) to authenticated;

alter table public.customer_profiles
  drop constraint if exists customer_profiles_preferred_language_check;

alter table public.customer_profiles
  add constraint customer_profiles_preferred_language_check
  check (preferred_language in ('en', 'ar', 'es', 'el'));

do $$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid from cron.job where jobname = 'kompsia-send-order-notifications'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'kompsia-send-order-notifications',
    '* * * * *',
    'select private.invoke_notification_worker();'
  );
end;
$$;
