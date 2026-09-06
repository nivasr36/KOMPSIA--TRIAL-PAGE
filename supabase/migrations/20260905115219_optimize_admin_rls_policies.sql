begin;

-- Merge staff directory reads into one policy.
drop policy if exists "Staff can read own staff record" on public.staff_members;
drop policy if exists "Owners and admins can read staff directory" on public.staff_members;
create policy "Staff directory access"
on public.staff_members for select
to authenticated
using (
  (select auth.uid()) = user_id
  or (select private.is_staff(array['owner','admin']::text[]))
);

-- Replace FOR ALL policies with write-only policies so SELECT is handled by the dedicated read policy.
drop policy if exists "Owner admin manage categories" on public.categories;
create policy "Owner admin insert categories" on public.categories for insert to authenticated
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin update categories" on public.categories for update to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin delete categories" on public.categories for delete to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

drop policy if exists "Owner admin manage products" on public.products;
create policy "Owner admin insert products" on public.products for insert to authenticated
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin update products" on public.products for update to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin delete products" on public.products for delete to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

drop policy if exists "Owner admin manage variants" on public.product_variants;
create policy "Owner admin insert variants" on public.product_variants for insert to authenticated
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin update variants" on public.product_variants for update to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin delete variants" on public.product_variants for delete to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

drop policy if exists "Owner admin manage product images" on public.product_images;
create policy "Owner admin insert product images" on public.product_images for insert to authenticated
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin update product images" on public.product_images for update to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin delete product images" on public.product_images for delete to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

drop policy if exists "Owner admin manage offers" on public.offers;
create policy "Owner admin insert offers" on public.offers for insert to authenticated
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin update offers" on public.offers for update to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin delete offers" on public.offers for delete to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

drop policy if exists "Owner admin manage offer products" on public.offer_products;
create policy "Owner admin insert offer products" on public.offer_products for insert to authenticated
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin delete offer products" on public.offer_products for delete to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

drop policy if exists "Owner admin manage offer categories" on public.offer_categories;
create policy "Owner admin insert offer categories" on public.offer_categories for insert to authenticated
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin delete offer categories" on public.offer_categories for delete to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

drop policy if exists "Owner admin manage coupons" on public.coupons;
create policy "Owner admin insert coupons" on public.coupons for insert to authenticated
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin update coupons" on public.coupons for update to authenticated
using ((select private.is_staff(array['owner','admin']::text[])))
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin delete coupons" on public.coupons for delete to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

drop policy if exists "Owner admin manage coupon products" on public.coupon_products;
create policy "Owner admin insert coupon products" on public.coupon_products for insert to authenticated
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin delete coupon products" on public.coupon_products for delete to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

drop policy if exists "Owner admin manage coupon categories" on public.coupon_categories;
create policy "Owner admin insert coupon categories" on public.coupon_categories for insert to authenticated
with check ((select private.is_staff(array['owner','admin']::text[])));
create policy "Owner admin delete coupon categories" on public.coupon_categories for delete to authenticated
using ((select private.is_staff(array['owner','admin']::text[])));

commit;
