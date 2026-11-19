create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;
set search_path = public, extensions;

create table public.shops (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  timezone text not null default 'Asia/Bangkok',
  plan text not null default 'Trial',
  created_at timestamptz not null default now()
);

-- Auth owns identities. Membership assignment is a privileged provisioning operation.
create table public.shop_members (
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'admin')),
  primary key (shop_id, user_id)
);
create index shop_members_user_idx on public.shop_members(user_id);

create table public.categories (
  shop_id uuid not null references public.shops(id) on delete cascade,
  code text not null,
  name text not null,
  template text not null check (template in ('table', 'staff', 'vip', 'seat', 'ticket')),
  visible boolean not null default true,
  sort_order integer not null default 0,
  price numeric(12,2) not null default 0 check (price >= 0),
  service_fee numeric(12,2) not null default 0 check (service_fee >= 0),
  payment_mode text not null default 'deposit' check (payment_mode in ('deposit', 'full')),
  default_status text not null default 'pending_payment'
    check (default_status in ('pending_payment', 'pending_confirm', 'confirmed')),
  primary key (shop_id, code)
);

create table public.resources (
  shop_id uuid not null,
  category_code text not null,
  code text not null,
  name text not null,
  description text not null default '',
  capacity integer check (capacity > 0),
  display jsonb not null default '{}',
  primary key (shop_id, category_code, code),
  foreign key (shop_id, category_code) references public.categories(shop_id, code) on delete cascade
);

create table public.layouts (
  shop_id uuid not null,
  category_code text not null,
  width integer not null check (width > 0),
  height integer not null check (height > 0),
  aspect text not null,
  decorations jsonb not null default '[]',
  background_path text,
  primary key (shop_id, category_code),
  foreign key (shop_id, category_code) references public.categories(shop_id, code) on delete cascade
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null,
  category_code text not null,
  resource_code text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at),
  customer_user_id uuid references auth.users(id) on delete set null,
  customer_name text not null,
  customer_phone text not null,
  customer_note text not null default '',
  guests integer check (guests > 0),
  tickets integer check (tickets > 0),
  amount numeric(12,2) not null check (amount >= 0),
  status text not null check (status in (
    'pending_payment', 'slip_review', 'pending_confirm', 'confirmed',
    'checked_in', 'completed', 'cancelled'
  )),
  created_at timestamptz not null default now(),
  foreign key (shop_id, category_code, resource_code)
    references public.resources(shop_id, category_code, code) on delete restrict,
  exclude using gist (
    shop_id with =, category_code with =, resource_code with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status not in ('cancelled', 'completed'))
);
create index bookings_shop_created_idx on public.bookings(shop_id, created_at desc);

-- Browser roles start deny-by-default. Phase 1 only enables merchant reads.
alter table public.shops enable row level security;
alter table public.shop_members enable row level security;
alter table public.categories enable row level security;
alter table public.resources enable row level security;
alter table public.layouts enable row level security;
alter table public.bookings enable row level security;

revoke all on public.shops, public.shop_members, public.categories, public.resources,
  public.layouts, public.bookings from public, anon, authenticated;
grant select on public.shops, public.shop_members, public.categories, public.resources,
  public.layouts, public.bookings to authenticated;

create policy read_own_memberships on public.shop_members for select to authenticated
  using (user_id = (select auth.uid()));
create policy read_member_shop on public.shops for select to authenticated
  using (id in (select shop_id from public.shop_members where user_id = (select auth.uid())));
create policy read_member_categories on public.categories for select to authenticated
  using (shop_id in (select shop_id from public.shop_members where user_id = (select auth.uid())));
create policy read_member_resources on public.resources for select to authenticated
  using (shop_id in (select shop_id from public.shop_members where user_id = (select auth.uid())));
create policy read_member_layouts on public.layouts for select to authenticated
  using (shop_id in (select shop_id from public.shop_members where user_id = (select auth.uid())));
create policy read_member_bookings on public.bookings for select to authenticated
  using (shop_id in (select shop_id from public.shop_members where user_id = (select auth.uid())));

reset search_path;
