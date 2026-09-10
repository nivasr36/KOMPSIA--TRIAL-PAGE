begin;

create table if not exists private.notification_settings (
  id smallint primary key default 1 check (id = 1),
  email_enabled boolean not null default false,
  provider text,
  sender_name text not null default 'KOMPSIA',
  sender_email text,
  reply_to_email text,
  updated_at timestamptz not null default now()
);

insert into private.notification_settings(id)
values (1)
on conflict (id) do nothing;

create table if not exists private.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  event_key text not null,
  order_id uuid references public.orders(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  recipient_email text not null,
  recipient_name text,
  template_key text not null,
  subject text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','processing','sent','failed','cancelled')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  max_attempts integer not null default 5 check (max_attempts between 1 and 20),
  next_attempt_at timestamptz not null default now(),
  provider_message_id text,
  last_error text,
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(event_key, order_id, recipient_email)
);

create index if not exists notification_outbox_status_next_idx
  on private.notification_outbox(status, next_attempt_at, queued_at);
create index if not exists notification_outbox_order_idx
  on private.notification_outbox(order_id, queued_at desc);
create index if not exists notification_outbox_user_idx
  on private.notification_outbox(user_id, queued_at desc)
  where user_id is not null;

create table if not exists private.notification_delivery_log (
  id uuid primary key default gen_random_uuid(),
  outbox_id uuid not null references private.notification_outbox(id) on delete cascade,
  attempt_number integer not null check (attempt_number > 0),
  provider text,
  provider_message_id text,
  success boolean not null,
  error_message text,
  response_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists notification_delivery_log_outbox_idx
  on private.notification_delivery_log(outbox_id, created_at desc);

revoke all on table private.notification_settings from public, anon, authenticated;
revoke all on table private.notification_outbox from public, anon, authenticated;
revoke all on table private.notification_delivery_log from public, anon, authenticated;

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
  on conflict (event_key, order_id, recipient_email) do update
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

revoke execute on function private.queue_order_notification(uuid,text,text,text,jsonb)
from public, anon, authenticated;
grant execute on function private.queue_order_notification(uuid,text,text,text,jsonb)
to service_role;

create or replace function private.enqueue_order_status_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_template text;
  v_subject text;
  v_event text;
  v_extra jsonb := '{}'::jsonb;
begin
  if new.is_customer_visible is not true then
    return new;
  end if;

  if coalesce(new.metadata->>'event','') = 'payment_status_changed' then
    if new.metadata->>'to' = 'paid' then
      v_template := 'payment_received';
      v_subject := 'Payment received for order ' || (select o.order_number from public.orders o where o.id = new.order_id);
      v_event := 'payment_paid:' || new.id::text;
    elsif new.metadata->>'to' = 'refunded' then
      v_template := 'payment_refunded';
      v_subject := 'Refund processed for order ' || (select o.order_number from public.orders o where o.id = new.order_id);
      v_event := 'payment_refunded:' || new.id::text;
    else
      return new;
    end if;
    v_extra := jsonb_build_object('history_id',new.id,'note',new.note,'event_metadata',new.metadata);
  else
    case new.status
      when 'pending' then
        v_template := 'order_received';
        v_subject := 'We received your KOMPSIA order ' || (select o.order_number from public.orders o where o.id = new.order_id);
      when 'confirmed' then
        v_template := 'order_confirmed';
        v_subject := 'Your KOMPSIA order is confirmed';
      when 'processing' then
        v_template := 'order_processing';
        v_subject := 'Your KOMPSIA order is being prepared';
      when 'packed' then
        v_template := 'order_packed';
        v_subject := 'Your KOMPSIA order is packed';
      when 'shipped' then
        v_template := 'order_shipped';
        v_subject := 'Your KOMPSIA order has shipped';
      when 'delivered' then
        v_template := 'order_delivered';
        v_subject := 'Your KOMPSIA order has been delivered';
      when 'cancelled' then
        v_template := 'order_cancelled';
        v_subject := 'Your KOMPSIA order has been cancelled';
      when 'returned' then
        v_template := 'order_returned';
        v_subject := 'Return completed for your KOMPSIA order';
      when 'refunded' then
        v_template := 'order_refunded';
        v_subject := 'Refund completed for your KOMPSIA order';
      else
        return new;
    end case;
    v_event := 'status:' || new.id::text;
    v_extra := jsonb_build_object('history_id',new.id,'note',new.note,'source',new.source,'event_metadata',new.metadata);
  end if;

  perform private.queue_order_notification(new.order_id, v_event, v_template, v_subject, v_extra);
  return new;
end;
$$;

revoke execute on function private.enqueue_order_status_email() from public, anon, authenticated;

create trigger enqueue_order_status_email_after_insert
after insert on public.order_status_history
for each row execute function private.enqueue_order_status_email();

create or replace function private.enqueue_change_request_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_template text;
  v_subject text;
  v_event text;
begin
  if tg_op = 'INSERT' then
    v_template := case when new.request_type = 'cancellation' then 'cancellation_request_received' else 'return_request_received' end;
    v_subject := case when new.request_type = 'cancellation' then 'We received your cancellation request' else 'We received your return request' end;
    v_event := 'change_request_created:' || new.id::text;
  elsif new.status is distinct from old.status then
    if new.status = 'approved' then
      v_template := case when new.request_type = 'cancellation' then 'cancellation_request_approved' else 'return_request_approved' end;
      v_subject := case when new.request_type = 'cancellation' then 'Your cancellation request was approved' else 'Your return request was approved' end;
    elsif new.status = 'rejected' then
      v_template := case when new.request_type = 'cancellation' then 'cancellation_request_rejected' else 'return_request_rejected' end;
      v_subject := case when new.request_type = 'cancellation' then 'Update on your cancellation request' else 'Update on your return request' end;
    elsif new.status = 'completed' then
      v_template := case when new.request_type = 'cancellation' then 'cancellation_completed' else 'return_completed' end;
      v_subject := case when new.request_type = 'cancellation' then 'Your order cancellation is complete' else 'Your return is complete' end;
    else
      return new;
    end if;
    v_event := 'change_request_status:' || new.id::text || ':' || new.status;
  else
    return new;
  end if;

  perform private.queue_order_notification(
    new.order_id,
    v_event,
    v_template,
    v_subject,
    jsonb_build_object(
      'request_id', new.id,
      'request_type', new.request_type,
      'request_status', new.status,
      'reason', new.reason,
      'customer_note', new.customer_note,
      'admin_response', new.admin_response
    )
  );

  return new;
end;
$$;

revoke execute on function private.enqueue_change_request_email() from public, anon, authenticated;

create trigger enqueue_change_request_email_after_change
after insert or update of status on public.order_change_requests
for each row execute function private.enqueue_change_request_email();

create or replace function private.claim_notification_batch(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,20),1),100);
  v_result jsonb;
begin
  with picked as (
    select o.id
    from private.notification_outbox o
    join private.notification_settings s on s.id = 1
    where s.email_enabled is true
      and o.status in ('pending','failed')
      and o.attempt_count < o.max_attempts
      and o.next_attempt_at <= now()
    order by o.queued_at
    for update skip locked
    limit v_limit
  ), claimed as (
    update private.notification_outbox o
    set status = 'processing',
        attempt_count = attempt_count + 1,
        updated_at = now()
    from picked p
    where o.id = p.id
    returning o.*
  )
  select coalesce(jsonb_agg(to_jsonb(c) order by c.queued_at), '[]'::jsonb)
  into v_result
  from claimed c;

  return v_result;
end;
$$;

create or replace function private.complete_notification_delivery(
  p_outbox_id uuid,
  p_success boolean,
  p_provider text,
  p_provider_message_id text,
  p_error_message text,
  p_response_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt integer;
begin
  select attempt_count into v_attempt
  from private.notification_outbox
  where id = p_outbox_id
  for update;

  if not found then
    raise exception 'NOTIFICATION_NOT_FOUND';
  end if;

  insert into private.notification_delivery_log(
    outbox_id, attempt_number, provider, provider_message_id, success, error_message, response_metadata
  ) values (
    p_outbox_id, v_attempt, p_provider, p_provider_message_id, p_success, nullif(p_error_message,''), coalesce(p_response_metadata,'{}'::jsonb)
  );

  if p_success then
    update private.notification_outbox
    set status='sent', provider_message_id=p_provider_message_id, last_error=null, sent_at=now(), updated_at=now()
    where id=p_outbox_id;
  else
    update private.notification_outbox
    set status=case when attempt_count >= max_attempts then 'failed' else 'pending' end,
        last_error=nullif(p_error_message,''),
        next_attempt_at=now() + make_interval(mins => least(60, greatest(2, attempt_count * 5))),
        updated_at=now()
    where id=p_outbox_id;
  end if;
end;
$$;

revoke execute on function private.claim_notification_batch(integer) from public, anon, authenticated;
revoke execute on function private.complete_notification_delivery(uuid,boolean,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function private.claim_notification_batch(integer) to service_role;
grant execute on function private.complete_notification_delivery(uuid,boolean,text,text,text,jsonb) to service_role;

commit;
