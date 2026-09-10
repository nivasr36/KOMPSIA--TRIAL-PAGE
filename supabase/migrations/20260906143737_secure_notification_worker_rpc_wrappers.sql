create or replace function public.notification_worker_status()
returns jsonb
language sql
stable
security definer
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
security definer
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
security definer
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

revoke all on function public.notification_worker_status() from public, anon, authenticated;
revoke all on function public.notification_worker_claim(integer) from public, anon, authenticated;
revoke all on function public.notification_worker_complete(uuid, boolean, text, text, text, jsonb) from public, anon, authenticated;

grant execute on function public.notification_worker_status() to service_role;
grant execute on function public.notification_worker_claim(integer) to service_role;
grant execute on function public.notification_worker_complete(uuid, boolean, text, text, text, jsonb) to service_role;
