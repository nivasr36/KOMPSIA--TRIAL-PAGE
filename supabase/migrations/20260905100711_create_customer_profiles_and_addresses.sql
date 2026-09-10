create table public.customer_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  first_name text,
  last_name text,
  phone text,
  date_of_birth date,
  avatar_url text,
  preferred_language text not null default 'en' check (preferred_language in ('en','ar')),
  marketing_opt_in boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  label text,
  full_name text not null,
  phone text,
  company text,
  address_line1 text not null,
  address_line2 text,
  city text not null,
  state_region text,
  postal_code text,
  country_code char(2) not null default 'AE',
  is_default_shipping boolean not null default false,
  is_default_billing boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index customer_addresses_user_id_idx on public.customer_addresses(user_id);
create unique index customer_addresses_one_default_shipping_per_user
  on public.customer_addresses(user_id)
  where is_default_shipping = true;
create unique index customer_addresses_one_default_billing_per_user
  on public.customer_addresses(user_id)
  where is_default_billing = true;

create trigger customer_profiles_set_updated_at
before update on public.customer_profiles
for each row execute function private.set_updated_at();

create trigger customer_addresses_set_updated_at
before update on public.customer_addresses
for each row execute function private.set_updated_at();

alter table public.customer_profiles enable row level security;
alter table public.customer_addresses enable row level security;

revoke all on table public.customer_profiles from anon, authenticated;
revoke all on table public.customer_addresses from anon, authenticated;

grant select, insert, update, delete on table public.customer_profiles to authenticated;
grant select, insert, update, delete on table public.customer_addresses to authenticated;

create policy "Customers can read own profile"
on public.customer_profiles for select
to authenticated
using ((select auth.uid()) = id);

create policy "Customers can create own profile"
on public.customer_profiles for insert
to authenticated
with check ((select auth.uid()) = id);

create policy "Customers can update own profile"
on public.customer_profiles for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create policy "Customers can delete own profile"
on public.customer_profiles for delete
to authenticated
using ((select auth.uid()) = id);

create policy "Customers can read own addresses"
on public.customer_addresses for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Customers can create own addresses"
on public.customer_addresses for insert
to authenticated
with check ((select auth.uid()) = user_id);

create policy "Customers can update own addresses"
on public.customer_addresses for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy "Customers can delete own addresses"
on public.customer_addresses for delete
to authenticated
using ((select auth.uid()) = user_id);
