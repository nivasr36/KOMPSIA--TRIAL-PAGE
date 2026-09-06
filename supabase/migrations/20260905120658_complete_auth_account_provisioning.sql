begin;

create or replace function private.create_customer_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_first_name text;
  v_last_name text;
  v_avatar text;
  v_language text;
begin
  v_first_name := nullif(btrim(coalesce(
    v_meta->>'first_name',
    v_meta->>'given_name'
  )), '');

  v_last_name := nullif(btrim(coalesce(
    v_meta->>'last_name',
    v_meta->>'family_name'
  )), '');

  -- If the provider only gives a full name, use it as first_name rather than
  -- making an unreliable guess about family-name boundaries.
  if v_first_name is null then
    v_first_name := nullif(btrim(coalesce(v_meta->>'full_name', v_meta->>'name')), '');
  end if;

  v_avatar := nullif(btrim(coalesce(v_meta->>'avatar_url', v_meta->>'picture')), '');

  v_language := lower(nullif(btrim(coalesce(v_meta->>'preferred_language', v_meta->>'locale')), ''));
  if v_language is not null then
    v_language := split_part(v_language, '-', 1);
  end if;
  if v_language not in ('en','ar') then
    v_language := 'en';
  end if;

  insert into public.customer_profiles (
    id,
    first_name,
    last_name,
    phone,
    avatar_url,
    preferred_language
  ) values (
    new.id,
    v_first_name,
    v_last_name,
    nullif(btrim(new.phone), ''),
    v_avatar,
    v_language
  )
  on conflict (id) do update
  set first_name = coalesce(public.customer_profiles.first_name, excluded.first_name),
      last_name = coalesce(public.customer_profiles.last_name, excluded.last_name),
      phone = coalesce(public.customer_profiles.phone, excluded.phone),
      avatar_url = coalesce(public.customer_profiles.avatar_url, excluded.avatar_url),
      preferred_language = coalesce(public.customer_profiles.preferred_language, excluded.preferred_language),
      updated_at = now();

  insert into public.shopping_carts(user_id, currency)
  values (new.id, 'AED')
  on conflict (user_id) do nothing;

  return new;
end;
$$;

revoke execute on function private.create_customer_profile_for_new_user()
from public, anon, authenticated;

create or replace function private.get_my_account_context_internal()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED';
  end if;

  select jsonb_build_object(
    'user_id', u.id,
    'email', u.email,
    'phone', u.phone,
    'email_confirmed', (u.email_confirmed_at is not null),
    'phone_confirmed', (u.phone_confirmed_at is not null),
    'created_at', u.created_at,
    'last_sign_in_at', u.last_sign_in_at,
    'auth_provider', u.raw_app_meta_data->>'provider',
    'auth_providers', coalesce(u.raw_app_meta_data->'providers', '[]'::jsonb),
    'profile', jsonb_build_object(
      'first_name', cp.first_name,
      'last_name', cp.last_name,
      'phone', cp.phone,
      'date_of_birth', cp.date_of_birth,
      'avatar_url', cp.avatar_url,
      'preferred_language', cp.preferred_language,
      'marketing_opt_in', cp.marketing_opt_in
    ),
    'cart_id', sc.id,
    'staff_role', (
      select sm.role
      from public.staff_members sm
      where sm.user_id = u.id and sm.is_active is true
      limit 1
    )
  )
  into v_result
  from auth.users u
  left join public.customer_profiles cp on cp.id = u.id
  left join public.shopping_carts sc on sc.user_id = u.id
  where u.id = v_user_id;

  if v_result is null then
    raise exception 'AUTH_USER_NOT_FOUND';
  end if;

  return v_result;
end;
$$;

revoke execute on function private.get_my_account_context_internal()
from public, anon, authenticated;
grant execute on function private.get_my_account_context_internal()
to authenticated;

create or replace function public.get_my_account_context()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_my_account_context_internal()
$$;

revoke execute on function public.get_my_account_context() from public, anon;
grant execute on function public.get_my_account_context() to authenticated;

-- Ensure existing users, if any are introduced by import before frontend wiring,
-- can be provisioned safely by the backend without exposing this capability.
create or replace function private.provision_missing_customer_resources()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  r record;
begin
  for r in select u.id, u.phone, u.raw_user_meta_data from auth.users u loop
    insert into public.customer_profiles(id, phone)
    values (r.id, nullif(btrim(r.phone),''))
    on conflict (id) do nothing;

    insert into public.shopping_carts(user_id, currency)
    values (r.id, 'AED')
    on conflict (user_id) do nothing;

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function private.provision_missing_customer_resources()
from public, anon, authenticated;
grant execute on function private.provision_missing_customer_resources()
to service_role;

commit;
