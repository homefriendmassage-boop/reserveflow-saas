-- ReserveFlow promotion vouchers: isolated tables; do not alter existing booking/payment flows.
begin;
create table if not exists public.rf_promotion_offers (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  hours integer not null check (hours between 1 and 24),
  mode text not null check (mode in ('discount','gift')),
  price numeric(12,2) not null check (price >= 0),
  gift_name text,
  gift_value numeric(12,2) not null default 0 check (gift_value >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id,shop_id),
  check (mode = 'discount' or nullif(btrim(gift_name),'') is not null)
);
create index if not exists rf_promotion_offers_shop on public.rf_promotion_offers(shop_id,active,hours);
create table if not exists public.rf_promotion_vouchers (
  id uuid primary key default gen_random_uuid(),
  token uuid not null unique default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  booking_id uuid not null references public.bookings(id) on delete cascade,
  offer_id uuid not null,
  line_user_id text not null check (line_user_id ~ '^U[0-9a-f]{32}$'),
  status text not null default 'issued' check (status in ('issued','redeemed','void')),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  redeemed_by uuid,
  unique (booking_id,offer_id),
  foreign key (offer_id,shop_id) references public.rf_promotion_offers(id,shop_id),
  check ((status='redeemed' and redeemed_at is not null and redeemed_by is not null) or status<>'redeemed')
);
create index if not exists rf_promotion_vouchers_shop_status on public.rf_promotion_vouchers(shop_id,status,expires_at);
create table if not exists public.rf_promotion_events (
  id uuid primary key default gen_random_uuid(),
  voucher_id uuid not null references public.rf_promotion_vouchers(id) on delete cascade,
  kind text not null check (kind in ('issued','redeemed')),
  status text not null default 'pending' check (status in ('pending','sent','failed')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  delivered_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  unique(voucher_id,kind)
);
create index if not exists rf_promotion_events_due on public.rf_promotion_events(status,next_attempt_at);
alter table public.rf_promotion_offers enable row level security;
alter table public.rf_promotion_vouchers enable row level security;
alter table public.rf_promotion_events enable row level security;
revoke all on public.rf_promotion_offers,public.rf_promotion_vouchers,public.rf_promotion_events from anon,authenticated;
grant select on public.rf_promotion_offers to authenticated;
create policy rf_offers_merchant_read on public.rf_promotion_offers for select to authenticated
  using(exists(select 1 from public.shop_members m where m.shop_id=rf_promotion_offers.shop_id and m.user_id=(select auth.uid())));
-- Only shop owner/admin can configure offers; cashier/staff may redeem.
create function public.rf_save_promotion_offer(
  p_shop_id uuid,p_id uuid,p_name text,p_hours integer,p_mode text,
  p_price numeric,p_gift_name text,p_gift_value numeric,p_active boolean
) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
  if (select auth.uid()) is null or not exists (
    select 1 from public.shop_members m where m.shop_id=p_shop_id and m.user_id=(select auth.uid()) and m.role in ('owner','admin')
  ) then raise exception 'PROMOTION_FORBIDDEN'; end if;
  if p_id is null then
    insert into public.rf_promotion_offers(shop_id,name,hours,mode,price,gift_name,gift_value,active)
    values(p_shop_id,p_name,p_hours,p_mode,p_price,p_gift_name,coalesce(p_gift_value,0),coalesce(p_active,true))
    returning id into result;
  else
    update public.rf_promotion_offers set name=p_name,hours=p_hours,mode=p_mode,price=p_price,
      gift_name=p_gift_name,gift_value=coalesce(p_gift_value,0),active=coalesce(p_active,true)
    where id=p_id and shop_id=p_shop_id returning id into result;
    if result is null then raise exception 'PROMOTION_NOT_FOUND'; end if;
  end if;
  return result;
end $$;
-- Voucher issuance is service-only, invoked AFTER verified payment/confirmed booking.
create function public.rf_issue_promotion_voucher(
  p_booking_id uuid,p_offer_id uuid,p_line_user_id text,p_expires_at timestamptz
) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid; v_shop uuid;
begin
  select b.shop_id into v_shop from public.bookings b where b.id=p_booking_id
    and b.status in ('confirmed','checked_in','completed') for update;
  if v_shop is null then raise exception 'BOOKING_NOT_CONFIRMED'; end if;
  if p_expires_at<=now() or p_expires_at>now()+interval '90 days' then raise exception 'INVALID_EXPIRY'; end if;
  if not exists(select 1 from public.rf_promotion_offers o where o.id=p_offer_id and o.shop_id=v_shop and o.active)
    then raise exception 'OFFER_NOT_AVAILABLE'; end if;
  insert into public.rf_promotion_vouchers(shop_id,booking_id,offer_id,line_user_id,expires_at)
  values(v_shop,p_booking_id,p_offer_id,p_line_user_id,p_expires_at)
  on conflict(booking_id,offer_id) do nothing;
  select id into result from public.rf_promotion_vouchers where booking_id=p_booking_id and offer_id=p_offer_id;
  insert into public.rf_promotion_events(voucher_id,kind) values(result,'issued') on conflict do nothing;
  return result;
end $$;
-- Read-only preview for staff. Never consume a voucher by merely scanning.
create function public.rf_preview_promotion_voucher(p_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v record;
begin
  select v.id,v.shop_id,v.status,v.expires_at,v.redeemed_at,o.name,o.gift_name,o.mode,o.hours
  into v from public.rf_promotion_vouchers v join public.rf_promotion_offers o on o.id=v.offer_id
  where v.token=p_token;
  if not found then return jsonb_build_object('valid',false,'reason','NOT_FOUND'); end if;
  if not exists(select 1 from public.shop_members m where m.shop_id=v.shop_id and m.user_id=(select auth.uid())
    and m.role in ('owner','admin','cashier','staff')) then raise exception 'VOUCHER_FORBIDDEN'; end if;
  return jsonb_build_object('valid',v.status='issued' and v.expires_at>now(),
    'status',case when v.expires_at<=now() and v.status='issued' then 'expired' else v.status end,
    'offer',v.name,'gift',v.gift_name,'mode',v.mode,'hours',v.hours,'expires_at',v.expires_at,'redeemed_at',v.redeemed_at);
end $$;
-- Atomic redemption guarded by row lock: two simultaneous scans cannot both succeed.
create function public.rf_redeem_promotion_voucher(p_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v record;
begin
  select id,shop_id,status,expires_at into v
  from public.rf_promotion_vouchers where token=p_token for update;
  if not found then return jsonb_build_object('ok',false,'reason','NOT_FOUND'); end if;
  if not exists(select 1 from public.shop_members m where m.shop_id=v.shop_id and m.user_id=(select auth.uid())
    and m.role in ('owner','admin','cashier','staff')) then raise exception 'VOUCHER_FORBIDDEN'; end if;
  if v.status<>'issued' or v.expires_at<=now() then
    return jsonb_build_object('ok',false,'reason',case when v.status='redeemed' then 'ALREADY_REDEEMED'
      when v.expires_at<=now() then 'EXPIRED' else 'NOT_ACTIVE' end);
  end if;
  update public.rf_promotion_vouchers
  set status='redeemed',redeemed_at=now(),redeemed_by=(select auth.uid()) where id=v.id;
  insert into public.rf_promotion_events(voucher_id,kind) values(v.id,'redeemed') on conflict do nothing;
  return jsonb_build_object('ok',true,'status','redeemed');
end $$;
revoke all on function public.rf_issue_promotion_voucher(uuid,uuid,text,timestamptz) from public,anon,authenticated;
grant execute on function public.rf_issue_promotion_voucher(uuid,uuid,text,timestamptz) to service_role;
revoke all on function public.rf_save_promotion_offer(uuid,uuid,text,integer,text,numeric,text,numeric,boolean) from public,anon;
grant execute on function public.rf_save_promotion_offer(uuid,uuid,text,integer,text,numeric,text,numeric,boolean) to authenticated;
revoke all on function public.rf_preview_promotion_voucher(uuid),public.rf_redeem_promotion_voucher(uuid) from public,anon;
grant execute on function public.rf_preview_promotion_voucher(uuid),public.rf_redeem_promotion_voucher(uuid) to authenticated;
commit;
