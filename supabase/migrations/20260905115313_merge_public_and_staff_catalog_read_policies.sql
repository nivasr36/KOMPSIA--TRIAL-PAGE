begin;

-- Categories
drop policy if exists "Public can read active categories" on public.categories;
drop policy if exists "Staff can read all categories" on public.categories;
create policy "Catalog category read access"
on public.categories for select
to anon, authenticated
using (
  is_active = true
  or (select private.is_staff(array['owner','admin','order_manager','support']::text[]))
);

-- Products
drop policy if exists "Public can read active products" on public.products;
drop policy if exists "Staff can read all products" on public.products;
create policy "Catalog product read access"
on public.products for select
to anon, authenticated
using (
  status = 'active'
  or (select private.is_staff(array['owner','admin','order_manager','support']::text[]))
);

-- Variants
drop policy if exists "Public can read active variants of active products" on public.product_variants;
drop policy if exists "Staff can read all variants" on public.product_variants;
create policy "Catalog variant read access"
on public.product_variants for select
to anon, authenticated
using (
  (
    is_active = true
    and exists (
      select 1 from public.products p
      where p.id = product_variants.product_id
        and p.status = 'active'
    )
  )
  or (select private.is_staff(array['owner','admin','order_manager','support']::text[]))
);

-- Product images
drop policy if exists "Public can read images of active products" on public.product_images;
drop policy if exists "Staff can read all product images" on public.product_images;
create policy "Catalog product image read access"
on public.product_images for select
to anon, authenticated
using (
  exists (
    select 1 from public.products p
    where p.id = product_images.product_id
      and p.status = 'active'
  )
  or (select private.is_staff(array['owner','admin','order_manager','support']::text[]))
);

-- Offers
drop policy if exists "Public can read current offers" on public.offers;
drop policy if exists "Staff can read offers" on public.offers;
create policy "Offer read access"
on public.offers for select
to anon, authenticated
using (
  (
    is_active = true
    and (starts_at is null or starts_at <= now())
    and (ends_at is null or ends_at > now())
  )
  or (select private.is_staff(array['owner','admin','order_manager','support']::text[]))
);

-- Offer product mappings
drop policy if exists "Public can read product mappings for current offers" on public.offer_products;
drop policy if exists "Staff can read offer products" on public.offer_products;
create policy "Offer product mapping read access"
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
  or (select private.is_staff(array['owner','admin','order_manager','support']::text[]))
);

-- Offer category mappings
drop policy if exists "Public can read category mappings for current offers" on public.offer_categories;
drop policy if exists "Staff can read offer categories" on public.offer_categories;
create policy "Offer category mapping read access"
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
  or (select private.is_staff(array['owner','admin','order_manager','support']::text[]))
);

commit;
