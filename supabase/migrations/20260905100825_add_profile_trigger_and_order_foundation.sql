create or replace function private.create_customer_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.customer_profiles (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function private.create_customer_profile_for_new_user() from public;
revoke all on function private.create_customer_profile_for_new_user() from anon, authenticated;

drop trigger if exists on_auth_user_created_create_customer_profile on auth.users;
create trigger on_auth_user_created_create_customer_profile
after insert on auth.users
for each row execute function private.create_customer_profile_for_new_user();

create sequence if not exists private.kompsia_order_number_seq start with 100001;
revoke all on sequence private.kompsia_order_number_seq from public, anon, authenticated;

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  user_id uuid references auth.users(id) on delete set null,
  customer_email text not null,
  customer_phone text,
  status text not null default 'pending' check (status in ('pending','confirmed','processing','packed','shipped','delivered','cancelled','returned','refunded')),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','pending','paid','partially_refunded','refunded','failed','cancelled')),
  payment_method text check (payment_method in ('card','apple_pay','google_pay','cod','wallet','bank_transfer')),
  currency char(3) not null default 'AED',
  subtotal numeric(12,2) not null default 0 check (subtotal >= 0),
  discount_total numeric(12,2) not null default 0 check (discount_total >= 0),
  shipping_total numeric(12,2) not null default 0 check (shipping_total >= 0),
  tax_total numeric(12,2) not null default 0 check (tax_total >= 0),
  grand_total numeric(12,2) not null default 0 check (grand_total >= 0),
  coupon_code text,
  shipping_address jsonb not null,
  billing_address jsonb,
  customer_notes text,
  admin_notes text,
  tracking_number text,
  carrier text,
  placed_at timestamptz not null default now(),
  confirmed_at timestamptz,
  shipped_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  variant_id uuid references public.product_variants(id) on delete set null,
  sku text,
  product_name text not null,
  variant_description text,
  quantity integer not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  discount_total numeric(12,2) not null default 0 check (discount_total >= 0),
  tax_total numeric(12,2) not null default 0 check (tax_total >= 0),
  line_total numeric(12,2) not null check (line_total >= 0),
  created_at timestamptz not null default now()
);

create table public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  status text not null check (status in ('pending','confirmed','processing','packed','shipped','delivered','cancelled','returned','refunded')),
  note text,
  created_at timestamptz not null default now()
);

create index orders_user_id_idx on public.orders(user_id);
create index orders_status_idx on public.orders(status);
create index orders_placed_at_idx on public.orders(placed_at desc);
create index order_items_order_id_idx on public.order_items(order_id);
create index order_status_history_order_id_idx on public.order_status_history(order_id, created_at);

create or replace function private.assign_kompsia_order_number()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.order_number is null or btrim(new.order_number) = '' then
    new.order_number := 'KOM-' || to_char(now(), 'YYYYMMDD') || '-' || lpad(nextval('private.kompsia_order_number_seq')::text, 6, '0');
  end if;
  return new;
end;
$$;

revoke all on function private.assign_kompsia_order_number() from public, anon, authenticated;

create trigger orders_assign_order_number
before insert on public.orders
for each row execute function private.assign_kompsia_order_number();

create trigger orders_set_updated_at
before update on public.orders
for each row execute function private.set_updated_at();

alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_status_history enable row level security;

revoke all on table public.orders from anon, authenticated;
revoke all on table public.order_items from anon, authenticated;
revoke all on table public.order_status_history from anon, authenticated;

grant select on table public.orders to authenticated;
grant select on table public.order_items to authenticated;
grant select on table public.order_status_history to authenticated;

create policy "Customers can read own orders"
on public.orders for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Customers can read items from own orders"
on public.order_items for select
to authenticated
using (
  exists (
    select 1
    from public.orders o
    where o.id = order_items.order_id
      and o.user_id = (select auth.uid())
  )
);

create policy "Customers can read own order history"
on public.order_status_history for select
to authenticated
using (
  exists (
    select 1
    from public.orders o
    where o.id = order_status_history.order_id
      and o.user_id = (select auth.uid())
  )
);
