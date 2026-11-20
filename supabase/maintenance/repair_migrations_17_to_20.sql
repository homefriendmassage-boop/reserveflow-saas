-- Recovery for interrupted or partially applied migrations 17–20.
-- Paste the entire file into one SQL Editor tab and run once.
begin;
do $$
begin
  if to_regclass('public.booking_slip_attachments') is null then
    raise exception 'Prerequisite missing: apply migration 15 (slip attachments).';
  end if;
  if to_regclass('public.shop_promptpay') is null then
    raise exception 'Prerequisite missing: apply migration 16 (PromptPay).';
  end if;
  if to_regclass('reserveflow_private.line_outbox') is null
    or to_regclass('reserveflow_private.platform_admins') is null then
    raise exception 'Prerequisite missing: apply migration 10 (LINE and Superadmin).';
  end if;
end;
$$;
alter table public.booking_slip_attachments
  add column if not exists verification_state text not null default 'pending',
  add column if not exists verification_started_at timestamptz,
  add column if not exists verified_amount numeric(12,2),
  add column if not exists thunder_reference text;

create unique index if not exists booking_slip_attachments_thunder_reference_key
on public.booking_slip_attachments(thunder_reference);

create or replace function public.claim_thunder_booking_slip(p_booking_id uuid, p_phone text, p_staff uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  slip public.booking_slip_attachments%rowtype;
begin
  select a.* into slip from public.booking_slip_attachments a
  join public.bookings b on b.id=a.booking_id
  where a.booking_id=p_booking_id and (
    (p_staff is null and b.customer_phone=regexp_replace(p_phone,'[[:space:]-]','','g')
      and b.created_at > now()-interval '24 hours') or exists (
      select 1 from public.shop_members m where m.shop_id=b.shop_id and m.user_id=p_staff
        and m.role in ('owner','admin','cashier')))
  for update of a;
  if not found then return null; end if;
  if slip.verification_state not in ('pending','retry') then
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
  end if;
  if slip.verification_started_at > now()-interval '1 minute' then
    return jsonb_build_object('state','checking');
  end if;
  update public.booking_slip_attachments set verification_started_at=now() where booking_id=p_booking_id;
  return jsonb_build_object('state','claimed','image',slip.image);
end;
$$;

create or replace function public.finish_thunder_booking_slip(
  p_booking_id uuid,p_outcome text,p_reference text,p_amount numeric,p_mobile text,p_paid_at timestamptz
) returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  slip public.booking_slip_attachments%rowtype;
  booking public.bookings%rowtype;
  expected_mobile text;
  outcome text := p_outcome;
begin
  if p_outcome not in ('retry','qr_unreadable','not_verified','provider_verified') then
    raise exception using errcode='22023',message='INVALID_VERIFICATION_OUTCOME';
  end if;
  select * into slip from public.booking_slip_attachments where booking_id=p_booking_id for update;
  if not found then return null; end if;
  if slip.verification_state not in ('pending','retry') then
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
  end if;
  if p_outcome='provider_verified' then
    select * into booking from public.bookings where id=p_booking_id for update;
    select mobile into expected_mobile from public.shop_promptpay where shop_id=booking.shop_id for share;
    if p_amount is null or p_amount <= 0 or p_amount > 9999999999.99 or p_amount <> round(p_amount,2)
      or p_reference is null or length(p_reference) not between 1 and 200 then
      outcome := 'retry';
    elsif p_mobile is null or expected_mobile is null or p_mobile <> expected_mobile
      or p_paid_at is null or p_paid_at < booking.created_at or p_paid_at > now()+interval '2 minutes' then
      outcome := case when p_amount <> booking.amount then 'amount_review' else 'receiver_review' end;
    else
      begin
        update public.booking_slip_attachments set thunder_reference=p_reference where booking_id=p_booking_id;
        if p_amount <> booking.amount then
          outcome := 'amount_review';
        elsif booking.status in ('pending_confirm','pending_payment','slip_review') and booking.starts_at > now() then
          update public.bookings set status='confirmed' where id=p_booking_id;
          outcome := 'confirmed';
        else
          outcome := 'booking_review';
        end if;
      exception when unique_violation then
        outcome := 'duplicate_review';
      end;
    end if;
  end if;
  update public.booking_slip_attachments
  set verification_state=outcome,
    verified_amount=case when outcome in ('confirmed','amount_review','receiver_review','booking_review','duplicate_review')
      then p_amount else null end
  where booking_id=p_booking_id returning * into slip;
  return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
end;
$$;

revoke all on function public.claim_thunder_booking_slip(uuid,text,uuid),
  public.finish_thunder_booking_slip(uuid,text,text,numeric,text,timestamptz) from public,anon,authenticated;
grant execute on function public.claim_thunder_booking_slip(uuid,text,uuid),
  public.finish_thunder_booking_slip(uuid,text,text,numeric,text,timestamptz) to service_role;



alter table public.bookings add column if not exists review_hold boolean not null default false;
lock table public.bookings in access exclusive mode;

do $$
declare original text;
begin
  if exists(select 1 from pg_constraint where conrelid='public.bookings'::regclass
    and conname='bookings_exclusive_period' and contype='x') then return; end if;

  select conname into original from pg_constraint
  where conrelid='public.bookings'::regclass and contype='x';
  if original is not null then
    execute format('alter table public.bookings drop constraint %I',original);
  end if;
  update public.bookings b set review_hold=true
  where b.status in ('pending_payment','pending_confirm','slip_review')
    and not b.review_hold and exists (select 1 from public.booking_slip_attachments a
      where a.booking_id=b.id and a.verification_state<>'booking_review');
  alter table public.bookings add constraint bookings_exclusive_period
  exclude using gist (
    shop_id with =, category_code with =, resource_code with =,
    tstzrange(starts_at,ends_at,'[)') with &&
  ) where (status in ('confirmed','checked_in') or
    (review_hold and status in ('pending_payment','pending_confirm','slip_review')));
end;
$$;

create index if not exists bookings_pending_floor_status on public.bookings(shop_id,category_code,resource_code,created_at desc)
where status in ('pending_payment','pending_confirm','slip_review');

create or replace function public.protect_booking_period()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(
    'booking-slot:'||new.shop_id::text||':'||new.category_code||':'||new.resource_code,0));
  if tg_op='INSERT' and new.status in ('pending_payment','pending_confirm','slip_review') and exists (
    select 1 from public.bookings b where (b.shop_id,b.category_code,b.resource_code)
      = (new.shop_id,new.category_code,new.resource_code)
      and (b.status in ('confirmed','checked_in') or
        (b.review_hold and b.status in ('pending_payment','pending_confirm','slip_review')))
      and tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(new.starts_at,new.ends_at,'[)')
  ) then
    raise exception using errcode='23P01',message='BOOKING_SLOT_TAKEN';
  end if;
  return new;
end;
$$;
drop trigger if exists protect_booking_period on public.bookings;
create trigger protect_booking_period before insert or update of status,review_hold on public.bookings
for each row execute function public.protect_booking_period();
revoke all on function public.protect_booking_period() from public,anon,authenticated;

create table if not exists public.booking_selection_presence (
  shop_id uuid not null,
  session_id uuid not null,
  category_code text not null,
  resource_code text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  expires_at timestamptz not null,
  primary key(shop_id,session_id),
  foreign key(shop_id,category_code,resource_code) references public.resources(shop_id,category_code,code) on delete cascade
);
create index if not exists booking_selection_presence_expiry on public.booking_selection_presence(expires_at);
create index if not exists booking_selection_presence_resource on public.booking_selection_presence(shop_id,category_code,resource_code);
alter table public.booking_selection_presence enable row level security;
revoke all on public.booking_selection_presence from public,anon,authenticated;

create or replace function public.mark_booking_selection(
  p_shop_slug text,p_session uuid,p_category_code text,p_resource_code text,
  p_date date,p_hour integer,p_minute integer,p_hours integer
) returns void language plpgsql security definer set search_path=''
as $$
declare
  shop uuid;
  zone text;
  opening timestamptz;
  duration integer;
begin
  select s.id,s.timezone into shop,zone from public.shops s
  where s.slug=p_shop_slug and s.public_booking_enabled;
  if shop is null or p_session is null then return; end if;
  if p_resource_code is null then
    delete from public.booking_selection_presence where shop_id=shop and session_id=p_session;
    return;
  end if;
  select case when c.template='table' then 2 else p_hours end into duration
  from public.categories c join public.resources r on (r.shop_id,r.category_code)=(c.shop_id,c.code)
  where c.shop_id=shop and c.code=p_category_code and c.visible and c.template in ('table','seat','vip')
    and r.code=p_resource_code and not (r.display @> '{"archived":true}');
  if duration is null or duration not between 1 and 6 or p_hour not between 10 and 22
    or p_minute not in (0,30) or (p_hour=22 and p_minute<>0)
    or p_date not between (now() at time zone zone)::date and (now() at time zone zone)::date+90
    or p_date is null or p_hour is null or p_minute is null then return; end if;
  opening := (p_date+make_time(p_hour,p_minute,0)) at time zone zone;
  delete from public.booking_selection_presence
  where (shop_id,session_id) in (
    select shop_id,session_id from public.booking_selection_presence where expires_at<=now()
    order by expires_at limit 100 for update skip locked
  );
  insert into public.booking_selection_presence(shop_id,session_id,category_code,resource_code,starts_at,ends_at,expires_at)
  values(shop,p_session,p_category_code,p_resource_code,opening,opening+make_interval(hours=>duration),now()+interval '15 seconds')
  on conflict(shop_id,session_id) do update set category_code=excluded.category_code,resource_code=excluded.resource_code,
    starts_at=excluded.starts_at,ends_at=excluded.ends_at,expires_at=excluded.expires_at;
end;
$$;
revoke all on function public.mark_booking_selection(text,uuid,text,text,date,integer,integer,integer) from public,anon,authenticated;
grant execute on function public.mark_booking_selection(text,uuid,text,text,date,integer,integer,integer) to anon,authenticated;

create or replace function public.booking_floor_availability(
  p_shop_id uuid,p_category_code text,p_resource_code text,p_start timestamptz,p_end timestamptz
) returns text language sql stable security definer set search_path=''
as $$
  select case
    when exists (select 1 from public.bookings b
      where (b.shop_id,b.category_code,b.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and b.status in ('confirmed','checked_in')
        and tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(p_start,p_end,'[)')) then 'booked'
    when exists (select 1 from public.bookings b
      where (b.shop_id,b.category_code,b.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and b.review_hold and b.status in ('pending_payment','pending_confirm','slip_review')
        and tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(p_start,p_end,'[)')) then 'review'
    when exists (select 1 from public.bookings b
      where (b.shop_id,b.category_code,b.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and b.status in ('pending_payment','pending_confirm','slip_review')
        and b.created_at > statement_timestamp()-interval '15 minutes'
        and tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(p_start,p_end,'[)')) then 'unpaid'
    when exists (select 1 from public.booking_selection_presence s
      where (s.shop_id,s.category_code,s.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and s.expires_at > statement_timestamp()
        and tstzrange(s.starts_at,s.ends_at,'[)') && tstzrange(p_start,p_end,'[)')) then 'selecting'
    else 'available'
  end;
$$;
revoke all on function public.booking_floor_availability(uuid,text,text,timestamptz,timestamptz) from public,anon,authenticated;

create or replace function public.attach_customer_booking_slip(p_booking_id uuid,p_phone text,p_image text)
returns void language plpgsql security definer set search_path = ''
as $$
declare review_state text := 'pending';
begin
  if not coalesce(length(p_image) <= 1450000 and p_image ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$',false)
    or not coalesce(p_phone ~ '^[0-9[:space:]-]{9,20}$',false) then
    raise exception using errcode='22023',message='INVALID_SLIP_ATTACHMENT';
  end if;
  perform 1 from public.bookings b
  where b.id=p_booking_id and b.customer_phone=regexp_replace(p_phone,'[[:space:]-]','','g')
    and b.created_at > now() - interval '24 hours'
    and b.status in ('pending_confirm','pending_payment','slip_review')
    and b.amount > 0
  for update;
  if not found then raise exception using errcode='22023',message='SLIP_BOOKING_UNAVAILABLE'; end if;

  if exists (select 1 from public.booking_slip_attachments where booking_id=p_booking_id) then
    if exists (select 1 from public.booking_slip_attachments where booking_id=p_booking_id and image=p_image) then return; end if;
    raise exception using errcode='22023',message='SLIP_ALREADY_ATTACHED';
  end if;
  begin
    update public.bookings set review_hold=true where id=p_booking_id;
  exception when exclusion_violation then
    -- Keep the evidence if another booking won after this customer paid.
    review_state := 'booking_review';
  end;
  insert into public.booking_slip_attachments(booking_id,image,verification_state)
  values (p_booking_id,p_image,review_state);
end;
$$;

create or replace function public.booking_table_plan(
  p_shop_slug text, p_category_code text, p_date date, p_hour integer, p_minute integer
)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  with eligible as (
    select s.id, c.code,
      (p_date + make_time(p_hour, p_minute, 0)) at time zone s.timezone as starts_at
    from public.shops s
    join public.categories c on c.shop_id = s.id
    where s.slug = p_shop_slug and s.public_booking_enabled and c.visible
      and c.code = p_category_code and c.template = 'table'
      and p_hour between 10 and 22 and p_minute in (0, 30)
      and (p_hour < 22 or p_minute = 0)
      and p_date between (statement_timestamp() at time zone s.timezone)::date
                     and (statement_timestamp() at time zone s.timezone)::date + 90
  )
  select jsonb_build_object(
    'width', coalesce(l.width, 960),
    'height', coalesce(l.height, 540),
    'background', l.background_image,
    'decorations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', decoration->>'type', 'label', decoration->>'label', 'x', decoration->'x', 'y', decoration->'y',
        'w', decoration->'w', 'h', decoration->'h'
      ))
      from jsonb_array_elements(case when jsonb_typeof(l.decorations) = 'array'
        then l.decorations else '[]'::jsonb end) decoration
    ), '[]'::jsonb),
    'tables', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', r.code, 'x', r.display->'x', 'y', r.display->'y',
        'w', r.display->'w', 'h', r.display->'h',
        'occupied', availability.state in ('booked','review'), 'availability', availability.state
      ) order by r.code)
      from public.resources r
      cross join lateral (
        select public.booking_floor_availability(r.shop_id,r.category_code,r.code,e.starts_at,e.starts_at + interval '2 hours') as state
      ) availability
      where (r.shop_id, r.category_code) = (e.id, e.code)
    ), '[]'::jsonb)
  )
  from eligible e
  left join public.layouts l on (l.shop_id, l.category_code) = (e.id, e.code);
$$;

create or replace function public.booking_resource_plan(
  p_shop_slug text, p_category_code text, p_date date, p_hour integer, p_minute integer, p_hours integer
)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  with eligible as (
    select s.id, c.code, case when c.template in ('seat','vip') then p_hours else 2 end as duration_hours,
      (p_date + make_time(p_hour, p_minute, 0)) at time zone s.timezone as starts_at
    from public.shops s
    join public.categories c on c.shop_id = s.id
    where s.slug = p_shop_slug and s.public_booking_enabled and c.visible
      and c.code = p_category_code and c.template in ('table', 'seat', 'vip')
      and (c.template = 'table' or (c.template = 'seat' and p_hours between 1 and 6)
        or (c.template = 'vip' and p_hours between 1 and 5))
      and p_hour between 10 and 22 and p_minute in (0, 30)
      and (p_hour < 22 or p_minute = 0)
      and p_date between (statement_timestamp() at time zone s.timezone)::date
                     and (statement_timestamp() at time zone s.timezone)::date + 90
  )
  select jsonb_build_object(
    'width', coalesce(l.width, 960),
    'height', coalesce(l.height, 540),
    'background', l.background_image,
    'decorations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', decoration->>'type', 'label', decoration->>'label', 'x', decoration->'x', 'y', decoration->'y',
        'w', decoration->'w', 'h', decoration->'h'
      ))
      from jsonb_array_elements(case when jsonb_typeof(l.decorations) = 'array'
        then l.decorations else '[]'::jsonb end) decoration
    ), '[]'::jsonb),
    'tables', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', r.code, 'x', r.display->'x', 'y', r.display->'y',
        'w', r.display->'w', 'h', r.display->'h',
        'occupied', availability.state in ('booked','review'), 'availability', availability.state
      ) order by r.code)
      from public.resources r
      cross join lateral (
        select public.booking_floor_availability(r.shop_id,r.category_code,r.code,e.starts_at,e.starts_at + make_interval(hours => e.duration_hours)) as state
      ) availability
      where (r.shop_id, r.category_code) = (e.id, e.code)
    ), '[]'::jsonb)
  )
  from eligible e
  left join public.layouts l on (l.shop_id, l.category_code) = (e.id, e.code);
$$;



create table if not exists reserveflow_private.platform_billing (
  id boolean primary key default true check (id),
  mobile text check (mobile ~ '^0[689][0-9]{8}$'),
  prices jsonb not null default '{}'::jsonb,
  referral_percent numeric(5,2) not null default 0 check (referral_percent between 0 and 100)
);
insert into reserveflow_private.platform_billing(id) values(true) on conflict(id) do nothing;

create table if not exists reserveflow_private.shop_subscriptions (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  expires_at timestamptz not null,
  referrer_shop uuid references public.shops(id) on delete set null
);
create table if not exists reserveflow_private.package_orders (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  plan text not null check (plan in ('monthly','quarterly','half_year','yearly')),
  months integer not null,
  amount numeric(12,2) not null,
  receiving_mobile text not null,
  referral_percent numeric(5,2) not null,
  state text not null default 'pending' check (state in ('pending','approved','rejected')),
  slip text,
  transfer_reference text unique,
  created_at timestamptz not null default now()
);
create unique index if not exists package_one_pending_order on reserveflow_private.package_orders(shop_id) where state='pending';
create table if not exists reserveflow_private.referral_credits (
  order_id uuid primary key references reserveflow_private.package_orders(id) on delete restrict,
  shop_id uuid not null references public.shops(id) on delete restrict,
  amount numeric(12,2) not null,
  paid_at timestamptz
);

create or replace function reserveflow_private.is_platform_admin()
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from reserveflow_private.platform_admins where user_id=(select auth.uid()));
$$;
create or replace function reserveflow_private.is_shop_owner(p_shop_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=(select auth.uid()) and role='owner');
$$;

create or replace function public.platform_package_prices()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('prices',prices,'payments_enabled',mobile is not null,
    'mobile',case when reserveflow_private.is_platform_admin() then mobile end,
    'referral_percent',case when reserveflow_private.is_platform_admin() then referral_percent end)
  from reserveflow_private.platform_billing;
$$;

create or replace function public.save_platform_package_settings(p_mobile text,p_prices jsonb,p_referral numeric)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if nullif(p_mobile,'') is not null and p_mobile !~ '^0[689][0-9]{8}$' then raise invalid_parameter_value; end if;
  if jsonb_typeof(p_prices) <> 'object' or p_referral is null or p_referral not between 0 and 100 or exists (
    select 1 from jsonb_each(p_prices) entry
    where entry.key not in ('monthly','quarterly','half_year','yearly') or
      jsonb_typeof(entry.value) <> 'number' or (entry.value::text)::numeric not between 1 and 10000000
  ) then raise invalid_parameter_value; end if;
  update reserveflow_private.platform_billing
    set mobile=nullif(p_mobile,''),prices=p_prices,referral_percent=p_referral;
end;
$$;

create or replace function reserveflow_private.start_shop_trial()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into reserveflow_private.shop_subscriptions(shop_id,expires_at)
  values(new.id,now()+interval '7 days');
  return new;
end;
$$;
drop trigger if exists start_shop_trial on public.shops;
create trigger start_shop_trial after insert on public.shops
for each row execute function reserveflow_private.start_shop_trial();

create or replace function public.register_platform_shop(p_name text,p_slug text,p_referral uuid,p_plan text)
returns uuid language plpgsql security definer set search_path='' as $$
declare new_shop uuid; referrer uuid; first_registration boolean;
begin
  if auth.uid() is null then raise insufficient_privilege; end if;
  perform pg_advisory_xact_lock(hashtextextended('shop-registration:' || auth.uid()::text,0));
  first_registration := not exists(select 1 from public.shop_members where user_id=auth.uid());
  new_shop := public.register_merchant_shop(p_name,p_slug);
  if first_registration then
    select id into referrer from public.shops where id=p_referral and id<>new_shop;
    update reserveflow_private.shop_subscriptions set referrer_shop=referrer where shop_id=new_shop;
  end if;
  if p_plan is not null then perform public.open_package_order(new_shop,p_plan); end if;
  return new_shop;
end;
$$;

create or replace function reserveflow_private.shop_booking_active(p_shop_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select not exists(select 1 from reserveflow_private.shop_subscriptions
    where shop_id=p_shop_id and expires_at<=now());
$$;

create or replace function public.shop_package_overview(p_shop_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
  return jsonb_build_object(
    'expires_at',(select expires_at from reserveflow_private.shop_subscriptions where shop_id=p_shop_id),
    'orders',coalesce((select jsonb_agg((to_jsonb(o)-'slip') || jsonb_build_object('has_slip',o.slip is not null) order by o.created_at desc) from (
      select * from reserveflow_private.package_orders where shop_id=p_shop_id order by created_at desc limit 10
    ) o),'[]'::jsonb),
    'unpaid_referral',coalesce((select sum(amount) from reserveflow_private.referral_credits where shop_id=p_shop_id and paid_at is null),0));
end;
$$;

create or replace function public.open_package_order(p_shop_id uuid,p_plan text)
returns uuid language plpgsql security definer set search_path='' as $$
declare billing reserveflow_private.platform_billing%rowtype; order_id uuid; months integer;
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
  perform pg_advisory_xact_lock(hashtextextended('package-order:'||p_shop_id::text,0));
  select id into order_id from reserveflow_private.package_orders where shop_id=p_shop_id and state='pending';
  if found then return order_id; end if;
  select * into billing from reserveflow_private.platform_billing;
  months := case p_plan when 'monthly' then 1 when 'quarterly' then 3 when 'half_year' then 6 when 'yearly' then 12 end;
  if months is null or billing.mobile is null or not (billing.prices ? p_plan) then
    raise exception using errcode='22023',message='PACKAGE_NOT_CONFIGURED';
  end if;
  insert into reserveflow_private.package_orders(shop_id,plan,months,amount,receiving_mobile,referral_percent)
  values(p_shop_id,p_plan,months,(billing.prices->>p_plan)::numeric,billing.mobile,billing.referral_percent)
  returning id into order_id;
  return order_id;
end;
$$;

create or replace function public.submit_package_slip(p_order_id uuid,p_image text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not coalesce(length(p_image)<=1450000 and p_image ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$',false) then raise invalid_parameter_value; end if;
  update reserveflow_private.package_orders set slip=p_image
  where id=p_order_id and state='pending' and slip is null and reserveflow_private.is_shop_owner(shop_id);
  if not found then raise invalid_parameter_value; end if;
end;
$$;

create or replace function public.platform_package_queue()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return jsonb_build_object('orders',coalesce((
    select jsonb_agg(to_jsonb(q) order by q.created_at) from (
      select o.id,o.plan,o.amount,o.receiving_mobile,s.name,o.created_at from reserveflow_private.package_orders o
      join public.shops s on s.id=o.shop_id where o.state='pending' and o.slip is not null order by o.created_at limit 100
    ) q
  ),'[]'::jsonb),'credits',coalesce((
    select jsonb_agg(to_jsonb(q)) from (
      select c.order_id,c.amount,s.name from reserveflow_private.referral_credits c
      join public.shops s on s.id=c.shop_id where c.paid_at is null limit 100
    ) q
  ),'[]'::jsonb));
end;
$$;

create or replace function public.platform_package_slip(p_order_id uuid)
returns text language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return (select slip from reserveflow_private.package_orders where id=p_order_id);
end;
$$;

create or replace function public.platform_package_verification_input(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return (select jsonb_build_object('image',slip,'amount',amount,'mobile',receiving_mobile,'created_at',created_at)
    from reserveflow_private.package_orders where id=p_order_id and slip is not null and state='pending');
end;
$$;

create or replace function public.cancel_unpaid_package_order(p_order_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  update reserveflow_private.package_orders set state='rejected'
  where id=p_order_id and state='pending' and slip is null and reserveflow_private.is_shop_owner(shop_id);
  if not found then raise invalid_parameter_value; end if;
end;
$$;

revoke all on function public.platform_package_verification_input(uuid),public.cancel_unpaid_package_order(uuid)
  from public,anon,authenticated;
grant execute on function public.platform_package_verification_input(uuid),public.cancel_unpaid_package_order(uuid) to authenticated;

create or replace function public.review_package_order(p_order_id uuid,p_approve boolean,p_reference text)
returns void language plpgsql security definer set search_path='' as $$
declare
  request reserveflow_private.package_orders%rowtype;
  referrer uuid;
  reference text := btrim(p_reference);
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  select * into request from reserveflow_private.package_orders where id=p_order_id for update;
  if not found or request.state<>'pending' or request.slip is null or p_approve is null then raise invalid_parameter_value; end if;
  if not p_approve then
    update reserveflow_private.package_orders set state='rejected' where id=p_order_id;
    return;
  end if;
  if reference is null or length(reference) not between 4 and 200 then raise invalid_parameter_value; end if;
  perform pg_advisory_xact_lock(hashtextextended('payment-reference:'||reference,0));
  if exists (select 1 from public.booking_slip_attachments where thunder_reference=reference) then
    raise unique_violation;
  end if;
  update reserveflow_private.package_orders set state='approved',transfer_reference=reference where id=p_order_id;
  insert into reserveflow_private.shop_subscriptions as s(shop_id,expires_at)
  values(request.shop_id,now()+make_interval(months=>request.months))
  on conflict(shop_id) do update set expires_at=greatest(s.expires_at,now())+make_interval(months=>request.months)
  returning referrer_shop into referrer;
  if referrer is not null and request.referral_percent>0 then
    insert into reserveflow_private.referral_credits(order_id,shop_id,amount)
    values(request.id,referrer,round(request.amount*request.referral_percent/100,2));
  end if;
end;
$$;

create or replace function public.complete_referral_payout(p_order_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  update reserveflow_private.referral_credits set paid_at=now() where order_id=p_order_id and paid_at is null;
end;
$$;

create or replace function public.send_referral_flex(p_shop_id uuid,p_target_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare target_scope text;
begin
  if p_shop_id is null then
    if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
    target_scope := 'platform';
  else
    if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
    target_scope := p_shop_id::text;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('referral-flex:'||p_target_id::text,0));
  if exists(select 1 from reserveflow_private.line_outbox where target_id=p_target_id and kind='referral'
    and next_at>now()-interval '30 seconds') then return; end if;
  insert into reserveflow_private.line_outbox(target_id,kind,payload)
  select id,'referral',jsonb_build_object('ref',p_shop_id,'name',coalesce((select name from public.shops where id=p_shop_id),'ReserveFlow'))
  from reserveflow_private.line_targets where owner_scope=target_scope and id=p_target_id;
  if not found then raise insufficient_privilege; end if;
end;
$$;

revoke all on function public.platform_package_prices() from public,anon,authenticated;
grant execute on function public.platform_package_prices() to anon,authenticated;
revoke all on function public.save_platform_package_settings(text,jsonb,numeric),public.register_platform_shop(text,text,uuid,text),
 public.shop_package_overview(uuid),public.open_package_order(uuid,text),public.submit_package_slip(uuid,text),
 public.platform_package_queue(),public.platform_package_slip(uuid),public.review_package_order(uuid,boolean,text),
 public.complete_referral_payout(uuid),public.send_referral_flex(uuid,uuid) from public,anon,authenticated;
grant execute on function public.save_platform_package_settings(text,jsonb,numeric),public.register_platform_shop(text,text,uuid,text),
 public.shop_package_overview(uuid),public.open_package_order(uuid,text),public.submit_package_slip(uuid,text),
 public.platform_package_queue(),public.platform_package_slip(uuid),public.review_package_order(uuid,boolean,text),
 public.complete_referral_payout(uuid),public.send_referral_flex(uuid,uuid) to authenticated;

create or replace function public.create_merchant_booking(
  p_shop_id uuid, p_request_id uuid, p_category_code text, p_resource_code text,
  p_date date, p_hour integer, p_minute integer, p_guests integer, p_hours integer, p_tickets integer, p_name text, p_phone text
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  resource record;
  role_name text;
  start_at timestamptz;
  clock_time timestamptz := statement_timestamp();
  walk_in boolean := p_date is null and p_hour is null and p_minute is null;
  normalized_phone text := regexp_replace(coalesce(p_phone, ''), '[[:space:]-]', '', 'g');
  guest_name text := coalesce(nullif(btrim(p_name), ''), 'ลูกค้าหน้าร้าน');
  total numeric;
  duration_hours integer;
  quantity integer;
  existing public.bookings%rowtype;
begin
  select role into role_name from public.shop_members where shop_id=p_shop_id and user_id=(select auth.uid());
  if role_name is null then raise insufficient_privilege; end if;

  select s.timezone, c.price, c.service_fee, c.template, r.capacity,r.display into resource
  from public.shops s
  join public.categories c on c.shop_id = s.id
  join public.resources r on (r.shop_id, r.category_code) = (c.shop_id, c.code)
  where s.id = p_shop_id
    and c.code = p_category_code and r.code = p_resource_code for share of r;

  if not found or p_request_id is null
    or char_length(guest_name) > 100
    or (normalized_phone <> '' and normalized_phone !~ '^0[0-9]{8,9}$') then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING';
  end if;

  if role_name='staff' and (resource.template<>'table' or not walk_in) then
    raise exception using errcode='42501',message='MERCHANT_BOOKING_FORBIDDEN';
  end if;

  if resource.template in ('table', 'vip') then
    if p_guests is null or p_guests not between 1 and 100
      or (resource.capacity is not null and p_guests > resource.capacity) then
      raise exception using errcode = '22023', message = 'INVALID_CAPACITY';
    end if;
  elsif p_guests is not null then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING';
  end if;

  if resource.template = 'ticket' then
    if p_tickets is null or p_tickets not between 1 and 10
      or (resource.capacity is not null and p_tickets > resource.capacity) then
      raise exception using errcode = '22023', message = 'INVALID_CAPACITY';
    end if;
  elsif p_tickets is not null then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING';
  end if;

  if resource.template in ('staff', 'vip', 'seat') then
    if p_hours is null or p_hours not between 1 and
      (case when resource.template = 'seat' then 6 else 5 end) then
      raise exception using errcode = '22023', message = 'INVALID_BOOKING';
    end if;
    duration_hours := p_hours;
    quantity := p_hours;
  else
    if p_hours is not null then
      raise exception using errcode = '22023', message = 'INVALID_BOOKING';
    end if;
    duration_hours := 2;
    quantity := coalesce(p_guests, p_tickets);
  end if;

  if walk_in then
    start_at := clock_time;
  else
    if p_date is null or not isfinite(p_date)
      or p_hour is null or p_hour not between 10 and 22
      or p_minute is null or p_minute not in (0, 30)
      or (p_hour = 22 and p_minute <> 0) then
      raise exception using errcode = '22023', message = 'INVALID_BOOKING_DATE';
    end if;
    start_at := (p_date + make_time(p_hour, p_minute, 0)) at time zone resource.timezone;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('booking-request:' || p_request_id::text, 0));
  select * into existing from public.bookings where id = p_request_id;
  if found then
    if (existing.shop_id, existing.category_code, existing.resource_code,
        existing.guests, existing.tickets, existing.customer_name, existing.customer_phone)
      is distinct from (p_shop_id, p_category_code, p_resource_code, p_guests, p_tickets, guest_name, normalized_phone)
      or existing.ends_at <> existing.starts_at + make_interval(hours => duration_hours)
      or (not walk_in and existing.starts_at <> start_at) then
      raise exception using errcode = '22023', message = 'BOOKING_REQUEST_MISMATCH';
    end if;
    return existing.id;
  end if;

  if resource.display @> '{"archived":true}' then
    raise exception using errcode = '22023', message = 'BOOKING_OPTION_UNAVAILABLE';
  end if;
  if not walk_in and (start_at <= clock_time or p_date > (clock_time at time zone resource.timezone)::date + 90) then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_DATE';
  end if;
  total := resource.price * quantity + resource.service_fee;
  if total > 9999999999.99 then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_PRICE';
  end if;

  insert into public.bookings (
    id, shop_id, category_code, resource_code, starts_at, ends_at,
    customer_name, customer_phone, guests, tickets, amount, status
  ) values (
    p_request_id, p_shop_id, p_category_code, p_resource_code, start_at, start_at + make_interval(hours => duration_hours),
    guest_name, normalized_phone, p_guests, p_tickets, total, case when walk_in then 'checked_in' else 'confirmed' end
  );
  return p_request_id;
exception when exclusion_violation then
  raise exception using errcode = '23P01', message = 'BOOKING_SLOT_TAKEN';
end;
$$;

create or replace function public.change_merchant_table_booking_status(
  p_shop_id uuid, p_booking_id uuid, p_status text
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  booking record;
  role_name text;
begin
  select role into role_name from public.shop_members where shop_id=p_shop_id and user_id=(select auth.uid());
  if role_name is null then raise insufficient_privilege; end if;

  select b.status, b.starts_at,c.template into booking
  from public.bookings b join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
  where b.id = p_booking_id and b.shop_id = p_shop_id
  for update of b;
  if not found or p_status is null or p_status not in ('cancelled', 'completed', 'confirmed') then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_STATUS';
  end if;
  if role_name='staff' and (p_status<>'completed' or booking.template<>'table' or booking.status not in ('checked_in','completed')) then
    raise exception using errcode='42501',message='MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if booking.status = p_status then return; end if;
  if not (
    (p_status = 'cancelled' and booking.status not in ('cancelled', 'completed'))
    or (p_status = 'completed' and booking.status in ('confirmed', 'checked_in') and booking.starts_at <= statement_timestamp())
    or (p_status = 'confirmed' and booking.status = 'pending_confirm' and booking.starts_at > statement_timestamp())
  ) then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_STATUS';
  end if;

  update public.bookings set status = p_status where id = p_booking_id and shop_id = p_shop_id;
end;
$$;

create or replace function public.booking_catalog(p_shop_slug text)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'name', s.name,
    'timezone', s.timezone,
    'slip_attachments_enabled', true,
    'promptpay_mobile', (select p.mobile from public.shop_promptpay p where p.shop_id=s.id),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', c.code, 'name', c.name, 'template', c.template,
        'price', c.price, 'service_fee', c.service_fee,
        'resources', coalesce((
          select jsonb_agg(jsonb_build_object(
            'code', r.code, 'name', r.name, 'description', r.description, 'capacity', r.capacity, 'position', r.display->>'position', 'photo', r.display->>'photo'
          ) order by r.code)
          from public.resources r
          where (r.shop_id, r.category_code) = (c.shop_id, c.code) and not (r.display @> '{"archived":true}')
        ), '[]'::jsonb)
      ) order by c.sort_order, c.code)
      from public.categories c
      where c.shop_id = s.id and c.visible
    ), '[]'::jsonb)
  )
  from public.shops s
  where s.slug = p_shop_slug and s.public_booking_enabled and reserveflow_private.shop_booking_active(s.id);
$$;

create or replace function public.submit_customer_booking(
  p_request_id uuid, p_shop_slug text, p_category_code text, p_resource_code text,
  p_date date, p_hour integer, p_hours integer, p_guests integer, p_tickets integer,
  p_name text, p_phone text, p_note text, p_minute integer default 0
)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  selected record;
  start_at timestamptz;
  end_at timestamptz;
  local_today date;
  duration_hours integer;
  quantity integer;
  total numeric;
  saved public.bookings%rowtype;
  customer_name text := btrim(coalesce(p_name, ''));
  normalized_phone text := regexp_replace(coalesce(p_phone, ''), '[[:space:]-]', '', 'g');
  customer_note text := btrim(coalesce(p_note, ''));
begin
  if p_request_id is null or p_date is null or not isfinite(p_date)
    or p_hour is null or p_hour not between 10 and 22
    or p_minute is null or p_minute not in (0, 30)
    or (p_hour = 22 and p_minute <> 0)
    or char_length(customer_name) not between 1 and 100
    or normalized_phone !~ '^0[0-9]{8,9}$' or char_length(customer_note) > 500
  then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING';
  end if;

  select s.id, s.timezone, c.template, c.price, c.service_fee, r.capacity, r.display
    into selected
  from public.shops s
  join public.categories c on c.shop_id = s.id
  join public.resources r on (r.shop_id, r.category_code) = (c.shop_id, c.code)
  where s.slug = p_shop_slug and s.public_booking_enabled and c.visible
    and c.code = p_category_code and r.code = p_resource_code for share of r;
  if not found then
    raise exception using errcode = '22023', message = 'BOOKING_OPTION_UNAVAILABLE';
  end if;

  if selected.template in ('table', 'vip') then
    if p_guests is null or p_guests not between 1 and 100
      or (selected.capacity is not null and p_guests > selected.capacity) then
      raise exception using errcode = '22023', message = 'INVALID_CAPACITY';
    end if;
  elsif p_guests is not null then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING';
  end if;

  if selected.template = 'ticket' then
    if p_tickets is null or p_tickets not between 1 and 10
      or (selected.capacity is not null and p_tickets > selected.capacity) then
      raise exception using errcode = '22023', message = 'INVALID_CAPACITY';
    end if;
  elsif p_tickets is not null then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING';
  end if;

  if selected.template in ('staff', 'vip', 'seat') then
    if p_hours is null or p_hours not between 1 and
      (case when selected.template = 'seat' then 6 else 5 end) then
      raise exception using errcode = '22023', message = 'INVALID_BOOKING';
    end if;
    duration_hours := p_hours;
    quantity := p_hours;
  else
    if p_hours is not null then
      raise exception using errcode = '22023', message = 'INVALID_BOOKING';
    end if;
    duration_hours := 2;
    quantity := coalesce(p_guests, p_tickets);
  end if;

  local_today := (statement_timestamp() at time zone selected.timezone)::date;
  start_at := (p_date + make_time(p_hour, p_minute, 0)) at time zone selected.timezone;
  end_at := start_at + make_interval(hours => duration_hours);
  total := selected.price * quantity + selected.service_fee;
  if total > 9999999999.99 then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_PRICE';
  end if;

  -- Serialize retries for the same opaque request ID, including simultaneous calls.
  perform pg_advisory_xact_lock(hashtextextended('booking-request:' || p_request_id::text, 0));
  select * into saved from public.bookings where id = p_request_id;
  if found then
    if (saved.shop_id, saved.category_code, saved.resource_code, saved.starts_at, saved.ends_at,
        saved.guests, saved.tickets, saved.customer_name, saved.customer_phone, saved.customer_note)
      is distinct from (selected.id, p_category_code, p_resource_code, start_at, end_at,
        p_guests, p_tickets, customer_name, normalized_phone, customer_note) then
      raise exception using errcode = '22023', message = 'BOOKING_REQUEST_MISMATCH';
    end if;
    return jsonb_build_object('id', saved.id, 'amount', saved.amount);
  end if;

  if not reserveflow_private.shop_booking_active(selected.id) then
    raise exception using errcode='22023',message='BOOKING_OPTION_UNAVAILABLE';
  end if;
  if selected.display @> '{"archived":true}' then
    raise exception using errcode = '22023', message = 'BOOKING_OPTION_UNAVAILABLE';
  end if;

  if start_at <= statement_timestamp() or p_date > local_today + 90 then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_DATE';
  end if;

  -- Lightweight abuse limit for enabled test shops, independent of UI validation.
  perform pg_advisory_xact_lock(hashtextextended('booking-phone:' || selected.id::text || ':' || normalized_phone, 0));
  if (select count(*) from public.bookings b where b.shop_id = selected.id
      and b.customer_phone = normalized_phone
      and b.created_at > statement_timestamp() - interval '1 hour') >= 5 then
    raise exception using errcode = '22023', message = 'BOOKING_RATE_LIMIT';
  end if;

  insert into public.bookings (
    id, shop_id, category_code, resource_code, starts_at, ends_at,
    customer_name, customer_phone, customer_note, guests, tickets, amount, status
  ) values (
    p_request_id, selected.id, p_category_code, p_resource_code, start_at, end_at,
    customer_name, normalized_phone, customer_note, p_guests, p_tickets, total, 'pending_confirm'
  );

  return jsonb_build_object('id', p_request_id, 'amount', total);
exception when exclusion_violation then
  raise exception using errcode = '23P01', message = 'BOOKING_SLOT_TAKEN';
end;
$$;

create or replace function public.finish_thunder_booking_slip(
  p_booking_id uuid,p_outcome text,p_reference text,p_amount numeric,p_mobile text,p_paid_at timestamptz
) returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  slip public.booking_slip_attachments%rowtype;
  booking public.bookings%rowtype;
  expected_mobile text;
  outcome text := p_outcome;
begin
  if p_outcome not in ('retry','qr_unreadable','not_verified','provider_verified') then
    raise exception using errcode='22023',message='INVALID_VERIFICATION_OUTCOME';
  end if;
  select * into slip from public.booking_slip_attachments where booking_id=p_booking_id for update;
  if not found then return null; end if;
  if slip.verification_state not in ('pending','retry') then
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
  end if;
  if p_outcome='provider_verified' then
    select * into booking from public.bookings where id=p_booking_id for update;
    select mobile into expected_mobile from public.shop_promptpay where shop_id=booking.shop_id for share;
    if p_amount is null or p_amount <= 0 or p_amount > 9999999999.99 or p_amount <> round(p_amount,2)
      or p_reference is null or length(p_reference) not between 1 and 200 then
      outcome := 'retry';
    elsif p_mobile is null or expected_mobile is null or p_mobile <> expected_mobile
      or p_paid_at is null or p_paid_at < booking.created_at or p_paid_at > now()+interval '2 minutes' then
      outcome := case when p_amount <> booking.amount then 'amount_review' else 'receiver_review' end;
    else
      begin
        perform pg_advisory_xact_lock(hashtextextended('payment-reference:'||p_reference,0));
        if exists (select 1 from reserveflow_private.package_orders where transfer_reference=p_reference) then
          raise unique_violation;
        end if;
        update public.booking_slip_attachments set thunder_reference=p_reference where booking_id=p_booking_id;
        if p_amount <> booking.amount then
          outcome := 'amount_review';
        elsif booking.status in ('pending_confirm','pending_payment','slip_review') and booking.starts_at > now() then
          update public.bookings set status='confirmed' where id=p_booking_id;
          outcome := 'confirmed';
        else
          outcome := 'booking_review';
        end if;
      exception when unique_violation then
        outcome := 'duplicate_review';
      end;
    end if;
  end if;
  update public.booking_slip_attachments
  set verification_state=outcome,
    verified_amount=case when outcome in ('confirmed','amount_review','receiver_review','booking_review','duplicate_review')
      then p_amount else null end
  where booking_id=p_booking_id returning * into slip;
  return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
end;
$$;

create or replace function public.check_in_merchant_booking(p_shop_id uuid, p_booking_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid())
      and role in ('owner', 'admin', 'cashier', 'staff')) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=(select auth.uid()) and role='staff')
    and not exists(select 1 from public.bookings b join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
      where b.shop_id=p_shop_id and b.id=p_booking_id and c.template='table') then
    raise insufficient_privilege;
  end if;
  update public.bookings set status = 'checked_in'
    where shop_id = p_shop_id and id = p_booking_id and status = 'confirmed'
      and statement_timestamp() >= starts_at - interval '30 minutes'
      and statement_timestamp() < ends_at;
  if not found and not exists (select 1 from public.bookings
    where shop_id = p_shop_id and id = p_booking_id and status = 'checked_in') then
    raise exception using errcode = '22023', message = 'INVALID_CHECK_IN';
  end if;
end;
$$;



alter table public.booking_slip_attachments add column if not exists verified_paid_at timestamptz;
create index if not exists booking_slip_paid_daily on public.booking_slip_attachments(verified_paid_at)
where verification_state='confirmed' and verified_paid_at is not null;
create index if not exists bookings_shop_service_day on public.bookings(shop_id,starts_at);

create or replace function reserveflow_private.can_read_shop_reports(p_shop_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.shop_members where shop_id=p_shop_id
    and user_id=(select auth.uid()) and role in ('owner','admin','cashier'));
$$;

create or replace function public.shop_daily_report(p_shop_id uuid,p_date date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  shop public.shops%rowtype;
  start_day timestamptz;
  end_day timestamptz;
  service jsonb;
  receipts jsonb;
  categories jsonb;
begin
  if not reserveflow_private.can_read_shop_reports(p_shop_id) then raise insufficient_privilege; end if;
  select * into strict shop from public.shops where id=p_shop_id;
  if p_date is null or not isfinite(p_date) or p_date<'2000-01-01'::date
    or p_date>(now() at time zone shop.timezone)::date then raise invalid_parameter_value; end if;
  start_day := p_date::timestamp at time zone shop.timezone;
  end_day := (p_date+1)::timestamp at time zone shop.timezone;

  select jsonb_build_object(
    'bookings',count(*),
    'active',count(*) filter(where b.status in ('confirmed','checked_in','completed')),
    'pending',count(*) filter(where b.status in ('pending_payment','pending_confirm','slip_review')),
    'cancelled',count(*) filter(where b.status='cancelled'),
    'booking_amount',coalesce(sum(b.amount) filter(where b.status in ('confirmed','checked_in','completed')),0))
  into service from public.bookings b
    where b.shop_id=p_shop_id and b.starts_at>=start_day and b.starts_at<end_day;
  select jsonb_build_object('verified_amount',coalesce(sum(a.verified_amount),0),
    'verified_count',count(*))
  into receipts from public.booking_slip_attachments a join public.bookings b on b.id=a.booking_id
    where b.shop_id=p_shop_id and a.verification_state='confirmed'
      and a.verified_paid_at>=start_day and a.verified_paid_at<end_day;

  select coalesce(jsonb_agg(to_jsonb(parts) order by parts.name),'[]'::jsonb) into categories from (
    select c.name,count(*) as bookings,count(*) filter(where b.status='cancelled') as cancelled,
      coalesce(sum(b.amount) filter(where b.status in ('confirmed','checked_in','completed')),0) as booking_amount
    from public.bookings b join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
    where b.shop_id=p_shop_id and b.starts_at>=start_day and b.starts_at<end_day
    group by c.code,c.name
  ) parts;
  return jsonb_build_object('shop_name',shop.name,'date',p_date,'categories',categories) || service || receipts;
end;
$$;

create or replace function public.shop_daily_report_groups(p_shop_id uuid)
returns table(id uuid,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.can_read_shop_reports(p_shop_id) then raise insufficient_privilege; end if;
  return query select t.id,t.created_at from reserveflow_private.line_targets t
  where t.owner_scope=p_shop_id::text and t.target_type='group' order by t.created_at;
end;
$$;

alter table reserveflow_private.line_outbox drop constraint if exists line_outbox_kind_check;
alter table reserveflow_private.line_outbox add constraint line_outbox_kind_check
check(kind in ('shop','booking','referral','daily_report'));

create or replace function public.send_shop_daily_report(p_shop_id uuid,p_date date,p_target_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  report jsonb := public.shop_daily_report(p_shop_id,p_date);
  outbox_id uuid;
begin
  if not exists(select 1 from reserveflow_private.line_targets where id=p_target_id
    and owner_scope=p_shop_id::text and target_type='group') then raise insufficient_privilege; end if;
  perform pg_advisory_xact_lock(hashtextextended('daily-report:'||p_target_id::text||':'||p_date::text,0));
  select id into outbox_id from reserveflow_private.line_outbox
  where target_id=p_target_id and kind='daily_report' and payload->>'date'=p_date::text and payload=report
    and coalesce(delivered_at,next_at)>now()-interval '30 seconds' and attempts<8
  limit 1;
  if found then return outbox_id; end if;
  insert into reserveflow_private.line_outbox(target_id,kind,payload)
  values(p_target_id,'daily_report',report) returning id into outbox_id;
  return outbox_id;
end;
$$;

revoke all on function public.shop_daily_report(uuid,date),public.shop_daily_report_groups(uuid),
  public.send_shop_daily_report(uuid,date,uuid) from public,anon,authenticated;
grant execute on function public.shop_daily_report(uuid,date),public.shop_daily_report_groups(uuid),
  public.send_shop_daily_report(uuid,date,uuid) to authenticated;
create or replace function public.finish_thunder_booking_slip(
  p_booking_id uuid,p_outcome text,p_reference text,p_amount numeric,p_mobile text,p_paid_at timestamptz
) returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  slip public.booking_slip_attachments%rowtype;
  booking public.bookings%rowtype;
  expected_mobile text;
  outcome text := p_outcome;
begin
  if p_outcome not in ('retry','qr_unreadable','not_verified','provider_verified') then
    raise exception using errcode='22023',message='INVALID_VERIFICATION_OUTCOME';
  end if;
  select * into slip from public.booking_slip_attachments where booking_id=p_booking_id for update;
  if not found then return null; end if;
  if slip.verification_state not in ('pending','retry') then
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
  end if;
  if p_outcome='provider_verified' then
    select * into booking from public.bookings where id=p_booking_id for update;
    select mobile into expected_mobile from public.shop_promptpay where shop_id=booking.shop_id for share;
    if p_amount is null or p_amount <= 0 or p_amount > 9999999999.99 or p_amount <> round(p_amount,2)
      or p_reference is null or length(p_reference) not between 1 and 200 then
      outcome := 'retry';
    elsif p_mobile is null or expected_mobile is null or p_mobile <> expected_mobile
      or p_paid_at is null or p_paid_at < booking.created_at or p_paid_at > now()+interval '2 minutes' then
      outcome := case when p_amount <> booking.amount then 'amount_review' else 'receiver_review' end;
    else
      begin
        perform pg_advisory_xact_lock(hashtextextended('payment-reference:'||p_reference,0));
        if exists (select 1 from reserveflow_private.package_orders where transfer_reference=p_reference) then
          raise unique_violation;
        end if;
        update public.booking_slip_attachments set thunder_reference=p_reference where booking_id=p_booking_id;
        if p_amount <> booking.amount then
          outcome := 'amount_review';
        elsif booking.status in ('pending_confirm','pending_payment','slip_review') and booking.starts_at > now() then
          update public.bookings set status='confirmed' where id=p_booking_id;
          outcome := 'confirmed';
        else
          outcome := 'booking_review';
        end if;
      exception when unique_violation then
        outcome := 'duplicate_review';
      end;
    end if;
  end if;
  update public.booking_slip_attachments
  set verification_state=outcome,
    verified_paid_at=case when outcome='confirmed' then p_paid_at end,
    verified_amount=case when outcome in ('confirmed','amount_review','receiver_review','booking_review','duplicate_review')
      then p_amount else null end
  where booking_id=p_booking_id returning * into slip;
  return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
end;
$$;

commit;

select '17–20 ready' as reserveflow_repair,
  to_regprocedure('public.shop_daily_report(uuid,date)') is not null as daily_reports_ready;
