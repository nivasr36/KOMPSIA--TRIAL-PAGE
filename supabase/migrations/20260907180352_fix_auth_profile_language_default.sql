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

  if v_first_name is null then
    v_first_name := nullif(btrim(coalesce(v_meta->>'full_name', v_meta->>'name')), '');
  end if;

  v_avatar := nullif(btrim(coalesce(v_meta->>'avatar_url', v_meta->>'picture')), '');

  v_language := lower(nullif(btrim(coalesce(v_meta->>'preferred_language', v_meta->>'locale')), ''));
  v_language := split_part(coalesce(v_language, 'en'), '-', 1);
  if v_language not in ('en', 'ar', 'es', 'el') then
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

commit;
