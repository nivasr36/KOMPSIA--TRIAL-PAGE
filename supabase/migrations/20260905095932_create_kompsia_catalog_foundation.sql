create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon, authenticated;

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  audience text not null default 'unisex' check (audience in ('men','women','kids','unisex','all')),
  description text,
  image_url text,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.categories(id) on delete set null,
  slug text not null unique,
  sku text unique,
  name text not null,
  short_description text,
  description text,
  audience text not null default 'unisex' check (audience in ('men','women','kids','unisex')),
  base_price numeric(12,2) not null check (base_price >= 0),
  compare_at_price numeric(12,2) check (compare_at_price is null or compare_at_price >= 0),
  currency char(3) not null default 'AED',
  leather_type text,
  material_details text,
  care_instructions text,
  status text not null default 'draft' check (status in ('draft','active','archived')),
  is_featured boolean not null default false,
  is_sale boolean not null default false,
  tags text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  sku text not null unique,
  color text,
  size text,
  price_override numeric(12,2) check (price_override is null or price_override >= 0),
  stock_quantity integer not null default 0 check (stock_quantity >= 0),
  low_stock_threshold integer not null default 3 check (low_stock_threshold >= 0),
  track_inventory boolean not null default true,
  allow_backorder boolean not null default false,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index product_variants_one_default_per_product
  on public.product_variants(product_id)
  where is_default = true;

create index product_variants_product_id_idx on public.product_variants(product_id);
create index products_category_id_idx on public.products(category_id);
create index products_status_idx on public.products(status);

create table public.product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  variant_id uuid references public.product_variants(id) on delete cascade,
  image_url text not null,
  alt_text text,
  sort_order integer not null default 0,
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);

create index product_images_product_id_idx on public.product_images(product_id);
create unique index product_images_one_primary_per_product
  on public.product_images(product_id)
  where is_primary = true and variant_id is null;

create table public.offers (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  discount_type text not null check (discount_type in ('percentage','fixed')),
  discount_value numeric(12,2) not null check (discount_value > 0),
  currency char(3) not null default 'AED',
  min_order_amount numeric(12,2) check (min_order_amount is null or min_order_amount >= 0),
  max_discount numeric(12,2) check (max_discount is null or max_discount >= 0),
  scope text not null default 'all' check (scope in ('all','products','categories')),
  starts_at timestamptz,
  ends_at timestamptz,
  priority integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (discount_type <> 'percentage' or discount_value <= 100),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);

create table public.offer_products (
  offer_id uuid not null references public.offers(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  primary key (offer_id, product_id)
);

create table public.offer_categories (
  offer_id uuid not null references public.offers(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete cascade,
  primary key (offer_id, category_id)
);

create table public.coupons (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code = upper(code)),
  description text,
  discount_type text not null check (discount_type in ('percentage','fixed','free_shipping')),
  discount_value numeric(12,2) not null default 0 check (discount_value >= 0),
  currency char(3) not null default 'AED',
  min_order_amount numeric(12,2) check (min_order_amount is null or min_order_amount >= 0),
  max_discount numeric(12,2) check (max_discount is null or max_discount >= 0),
  scope text not null default 'all' check (scope in ('all','products','categories')),
  starts_at timestamptz,
  ends_at timestamptz,
  usage_limit_total integer check (usage_limit_total is null or usage_limit_total > 0),
  usage_limit_per_customer integer check (usage_limit_per_customer is null or usage_limit_per_customer > 0),
  usage_count integer not null default 0 check (usage_count >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (discount_type <> 'percentage' or discount_value <= 100),
  check (discount_type <> 'free_shipping' or discount_value = 0),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);

create table public.coupon_products (
  coupon_id uuid not null references public.coupons(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  primary key (coupon_id, product_id)
);

create table public.coupon_categories (
  coupon_id uuid not null references public.coupons(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete cascade,
  primary key (coupon_id, category_id)
);

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function private.set_updated_at() from public;

create trigger categories_set_updated_at before update on public.categories
for each row execute function private.set_updated_at();
create trigger products_set_updated_at before update on public.products
for each row execute function private.set_updated_at();
create trigger product_variants_set_updated_at before update on public.product_variants
for each row execute function private.set_updated_at();
create trigger offers_set_updated_at before update on public.offers
for each row execute function private.set_updated_at();
create trigger coupons_set_updated_at before update on public.coupons
for each row execute function private.set_updated_at();

alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_variants enable row level security;
alter table public.product_images enable row level security;
alter table public.offers enable row level security;
alter table public.offer_products enable row level security;
alter table public.offer_categories enable row level security;
alter table public.coupons enable row level security;
alter table public.coupon_products enable row level security;
alter table public.coupon_categories enable row level security;

revoke all on table public.categories from anon, authenticated;
revoke all on table public.products from anon, authenticated;
revoke all on table public.product_variants from anon, authenticated;
revoke all on table public.product_images from anon, authenticated;
revoke all on table public.offers from anon, authenticated;
revoke all on table public.offer_products from anon, authenticated;
revoke all on table public.offer_categories from anon, authenticated;
revoke all on table public.coupons from anon, authenticated;
revoke all on table public.coupon_products from anon, authenticated;
revoke all on table public.coupon_categories from anon, authenticated;

grant select on table public.categories to anon, authenticated;
grant select on table public.products to anon, authenticated;
grant select on table public.product_variants to anon, authenticated;
grant select on table public.product_images to anon, authenticated;
grant select on table public.offers to anon, authenticated;
grant select on table public.offer_products to anon, authenticated;
grant select on table public.offer_categories to anon, authenticated;

create policy "Public can read active categories"
on public.categories for select
to anon, authenticated
using (is_active = true);

create policy "Public can read active products"
on public.products for select
to anon, authenticated
using (status = 'active');

create policy "Public can read active variants of active products"
on public.product_variants for select
to anon, authenticated
using (
  is_active = true
  and exists (
    select 1 from public.products p
    where p.id = product_variants.product_id and p.status = 'active'
  )
);

create policy "Public can read images of active products"
on public.product_images for select
to anon, authenticated
using (
  exists (
    select 1 from public.products p
    where p.id = product_images.product_id and p.status = 'active'
  )
);

create policy "Public can read current offers"
on public.offers for select
to anon, authenticated
using (
  is_active = true
  and (starts_at is null or starts_at <= now())
  and (ends_at is null or ends_at > now())
);

create policy "Public can read product mappings for current offers"
on public.offer_products for select
to anon, authenticated
using (
  exists (
    select 1 from public.offers o
    where o.id = offer_products.offer_id
      and o.is_active = true
      and (o.starts_at is null or o.starts_at <= now())
      and (o.ends_at is null or o.ends_at > now())
  )
);

create policy "Public can read category mappings for current offers"
on public.offer_categories for select
to anon, authenticated
using (
  exists (
    select 1 from public.offers o
    where o.id = offer_categories.offer_id
      and o.is_active = true
      and (o.starts_at is null or o.starts_at <= now())
      and (o.ends_at is null or o.ends_at > now())
  )
);
