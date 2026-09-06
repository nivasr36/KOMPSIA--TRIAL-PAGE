begin;

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
  -- Recover jobs abandoned by a crashed/timed-out worker.
  update private.notification_outbox
  set status = case when attempt_count >= max_attempts then 'failed' else 'pending' end,
      last_error = coalesce(last_error, 'Worker lease expired before completion'),
      next_attempt_at = case when attempt_count >= max_attempts then next_attempt_at else now() end,
      updated_at = now()
  where status = 'processing'
    and updated_at < now() - interval '15 minutes';

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

revoke execute on function private.claim_notification_batch(integer) from public, anon, authenticated;
grant execute on function private.claim_notification_batch(integer) to service_role;

create or replace function public.notification_worker_status()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'email_enabled', s.email_enabled,
    'provider', s.provider,
    'sender_name', s.sender_name,
    'sender_email', s.sender_email,
    'reply_to_email', s.reply_to_email
  )
  from private.notification_settings s
  where s.id = 1
$$;

create or replace function public.notification_worker_claim(p_limit integer default 20)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.claim_notification_batch(p_limit)
$$;

create or replace function public.notification_worker_complete(
  p_outbox_id uuid,
  p_success boolean,
  p_provider text,
  p_provider_message_id text default null,
  p_error_message text default null,
  p_response_metadata jsonb default '{}'::jsonb
)
returns void
language sql
security invoker
set search_path = ''
as $$
  select private.complete_notification_delivery(
    p_outbox_id,
    p_success,
    p_provider,
    p_provider_message_id,
    p_error_message,
    p_response_metadata
  )
$$;

revoke execute on function public.notification_worker_status() from public, anon, authenticated;
revoke execute on function public.notification_worker_claim(integer) from public, anon, authenticated;
revoke execute on function public.notification_worker_complete(uuid,boolean,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.notification_worker_status() to service_role;
grant execute on function public.notification_worker_claim(integer) to service_role;
grant execute on function public.notification_worker_complete(uuid,boolean,text,text,text,jsonb) to service_role;

update private.notification_settings
set provider = 'resend',
    sender_name = 'KOMPSIA',
    sender_email = 'orders@kompsia.com',
    email_enabled = false,
    updated_at = now()
where id = 1;

commit;
