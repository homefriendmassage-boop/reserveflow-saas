begin;

create table reserveflow_private.platform_billing (
  id boolean primary key default true check (id),
  mobile text check (mobile ~ '^0[689][0-9]{8}$'),
  prices jsonb not null default '{}'::jsonb,
  referral_percent numeric(5,2) not null default 0 check (referral_percent between 0 and 100)
);
insert into reserveflow_private.platform_billing default values;

create table reserveflow_private.shop_subscriptions (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  expires_at timestamptz not null,
  referrer_shop uuid references public.shops(id) on delete set null
);
create table reserveflow_private.package_orders (
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
create unique index package_one_pending_order on reserveflow_private.package_orders(shop_id) where state='pending';
create table reserveflow_private.referral_credits (
  order_id uuid primary key references reserveflow_private.package_orders(id) on delete restrict,
  shop_id uuid not null references public.shops(id) on delete restrict,
  amount numeric(12,2) not null,
  paid_at timestamptz
);

create function reserveflow_private.is_platform_admin()
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from reserveflow_private.platform_admins where user_id=(select auth.uid()));
$$;
create function reserveflow_private.is_shop_owner(p_shop_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=(select auth.uid()) and role='owner');
$$;

create function public.platform_package_prices()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('prices',prices,'payments_enabled',mobile is not null,
    'mobile',case when reserveflow_private.is_platform_admin() then mobile end,
    'referral_percent',case when reserveflow_private.is_platform_admin() then referral_percent end)
  from reserveflow_private.platform_billing;
$$;

create function public.save_platform_package_settings(p_mobile text,p_prices jsonb,p_referral numeric)
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

create function reserveflow_private.start_shop_trial()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into reserveflow_private.shop_subscriptions(shop_id,expires_at)
  values(new.id,now()+interval '7 days');
  return new;
end;
$$;
create trigger start_shop_trial after insert on public.shops
for each row execute function reserveflow_private.start_shop_trial();

create function public.register_platform_shop(p_name text,p_slug text,p_referral uuid,p_plan text)
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

create function reserveflow_private.shop_booking_active(p_shop_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select not exists(select 1 from reserveflow_private.shop_subscriptions
    where shop_id=p_shop_id and expires_at<=now());
$$;

create function public.shop_package_overview(p_shop_id uuid)
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

create function public.open_package_order(p_shop_id uuid,p_plan text)
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

create function public.submit_package_slip(p_order_id uuid,p_image text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not coalesce(length(p_image)<=1450000 and p_image ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$',false) then raise invalid_parameter_value; end if;
  update reserveflow_private.package_orders set slip=p_image
  where id=p_order_id and state='pending' and slip is null and reserveflow_private.is_shop_owner(shop_id);
  if not found then raise invalid_parameter_value; end if;
end;
$$;

create function public.platform_package_queue()
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

create function public.platform_package_slip(p_order_id uuid)
returns text language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return (select slip from reserveflow_private.package_orders where id=p_order_id);
end;
$$;

create function public.platform_package_verification_input(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return (select jsonb_build_object('image',slip,'amount',amount,'mobile',receiving_mobile,'created_at',created_at)
    from reserveflow_private.package_orders where id=p_order_id and slip is not null and state='pending');
end;
$$;

create function public.cancel_unpaid_package_order(p_order_id uuid)
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

create function public.review_package_order(p_order_id uuid,p_approve boolean,p_reference text)
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

create function public.complete_referral_payout(p_order_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  update reserveflow_private.referral_credits set paid_at=now() where order_id=p_order_id and paid_at is null;
end;
$$;

alter table reserveflow_private.line_outbox drop constraint line_outbox_kind_check;
alter table reserveflow_private.line_outbox add constraint line_outbox_kind_check check (kind in ('shop','booking','referral'));
create function public.send_referral_flex(p_shop_id uuid,p_target_id uuid)
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

commit;
