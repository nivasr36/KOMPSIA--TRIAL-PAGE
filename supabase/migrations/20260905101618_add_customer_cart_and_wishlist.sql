create table public.shopping_carts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  currency char(3) not null default 'AED',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.cart_items (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references public.shopping_carts(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  variant_id uuid references public.product_variants(id) on delete cascade,
  quantity integer not null default 1 check (quantity > 0 and quantity <= 99),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index cart_items_unique_item
  on public.cart_items(cart_id, product_id, coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index cart_items_cart_id_idx on public.cart_items(cart_id);

create table public.wishlist_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  variant_id uuid references public.product_variants(id) on delete cascade,
  created_at timestamptz not null default now()
);

create unique index wishlist_items_unique_item
  on public.wishlist_items(user_id, product_id, coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index wishlist_items_user_id_idx on public.wishlist_items(user_id);

create trigger shopping_carts_set_updated_at
before update on public.shopping_carts
for each row execute function private.set_updated_at();

create trigger cart_items_set_updated_at
before update on public.cart_items
for each row execute function private.set_updated_at();

alter table public.shopping_carts enable row level security;
alter table public.cart_items enable row level security;
alter table public.wishlist_items enable row level security;

revoke all on table public.shopping_carts from anon, authenticated;
revoke all on table public.cart_items from anon, authenticated;
revoke all on table public.wishlist_items from anon, authenticated;

grant select, insert, update, delete on table public.shopping_carts to authenticated;
grant select, insert, update, delete on table public.cart_items to authenticated;
grant select, insert, update, delete on table public.wishlist_items to authenticated;

create policy "Customers can read own cart"
on public.shopping_carts for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Customers can create own cart"
on public.shopping_carts for insert
to authenticated
with check ((select auth.uid()) = user_id);

create policy "Customers can update own cart"
on public.shopping_carts for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy "Customers can delete own cart"
on public.shopping_carts for delete
to authenticated
using ((select auth.uid()) = user_id);

create policy "Customers can read own cart items"
on public.cart_items for select
to authenticated
using (
  exists (
    select 1 from public.shopping_carts c
    where c.id = cart_items.cart_id
      and c.user_id = (select auth.uid())
  )
);

create policy "Customers can create own cart items"
on public.cart_items for insert
to authenticated
with check (
  exists (
    select 1 from public.shopping_carts c
    where c.id = cart_items.cart_id
      and c.user_id = (select auth.uid())
  )
);

create policy "Customers can update own cart items"
on public.cart_items for update
to authenticated
using (
  exists (
    select 1 from public.shopping_carts c
    where c.id = cart_items.cart_id
      and c.user_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1 from public.shopping_carts c
    where c.id = cart_items.cart_id
      and c.user_id = (select auth.uid())
  )
);

create policy "Customers can delete own cart items"
on public.cart_items for delete
to authenticated
using (
  exists (
    select 1 from public.shopping_carts c
    where c.id = cart_items.cart_id
      and c.user_id = (select auth.uid())
  )
);

create policy "Customers can read own wishlist"
on public.wishlist_items for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Customers can add own wishlist items"
on public.wishlist_items for insert
to authenticated
with check ((select auth.uid()) = user_id);

create policy "Customers can remove own wishlist items"
on public.wishlist_items for delete
to authenticated
using ((select auth.uid()) = user_id);
