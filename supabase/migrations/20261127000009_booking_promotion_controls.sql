begin;

alter table public.shops add column promotions_online_only boolean not null default false;

create function public.set_merchant_promotions_online_only(p_shop_id uuid, p_enabled boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() and not reserveflow_private.is_shop_owner(p_shop_id) then
    raise insufficient_privilege;
  end if;
  update public.shops set promotions_online_only=p_enabled where id=p_shop_id;
  if not found then raise no_data_found; end if;
end;
$$;

revoke all on function public.set_merchant_promotions_online_only(uuid,boolean) from public,anon,authenticated;
grant execute on function public.set_merchant_promotions_online_only(uuid,boolean) to authenticated;

create function public.get_platform_promotions_online_only(p_shop_id uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return (select promotions_online_only from public.shops where id=p_shop_id);
end;
$$;

revoke all on function public.get_platform_promotions_online_only(uuid) from public,anon,authenticated;
grant execute on function public.get_platform_promotions_online_only(uuid) to authenticated;

create function public.booking_resource_next_start(
  p_shop_slug text,p_category_code text,p_resource_code text,p_business_date date,p_after time,p_hours integer
)
returns text language sql stable security definer set search_path='' as $$
  select to_char(candidate.starts,'HH24:MI')
  from public.shops s
  join public.categories c on c.shop_id=s.id and c.code=p_category_code and c.visible
  join public.resources r on r.shop_id=c.shop_id and r.category_code=c.code and r.code=p_resource_code
  cross join lateral generate_series(p_business_date + time '06:00',
    p_business_date + 1 + time '05:30', interval '30 minutes') candidate(starts)
  where s.slug=p_shop_slug and s.public_booking_enabled
    and c.template in ('table','seat','vip')
    and p_hours between 1 and case when c.template='seat' then 6 else 5 end
    and p_business_date between ((statement_timestamp() at time zone s.timezone)-interval '6 hours')::date
      and ((statement_timestamp() at time zone s.timezone)-interval '6 hours')::date+90
    and candidate.starts > p_business_date + case when p_after < time '06:00' then 1 else 0 end + p_after
    and (candidate.starts at time zone s.timezone) > statement_timestamp()
    and public.booking_floor_availability(s.id,c.code,r.code,candidate.starts at time zone s.timezone,
      (candidate.starts at time zone s.timezone)+make_interval(hours=>p_hours)) not in ('booked','review','in_use')
  order by candidate.starts limit 1;
$$;

revoke all on function public.booking_resource_next_start(text,text,text,date,time,integer) from public,anon,authenticated;
grant execute on function public.booking_resource_next_start(text,text,text,date,time,integer) to anon,authenticated;

create or replace function public.rf_booking_offers(p_shop_slug text,p_category_code text,p_hours integer)
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'hours',o.hours,
    'mode',o.mode,'price',o.price,'gift',o.gift_name,'gift_value',o.gift_value,'allows_extra_hours',true) order by o.price,o.id),'[]'::jsonb)
  from public.rf_promotion_offers o join public.shops s on s.id=o.shop_id
  join public.categories c on c.shop_id=s.id and c.code=p_category_code
  where s.slug=p_shop_slug and s.public_booking_enabled and reserveflow_private.shop_booking_active(s.id)
    and (o.category_code is null or o.category_code=c.code)
    and c.visible and c.template in ('seat','vip','staff') and o.active and o.hours=p_hours and o.hours between 1 and 5
    and (o.starts_at is null or o.starts_at<=now()) and (o.ends_at is null or o.ends_at>now())
    and (o.mode='gift' and o.price=c.price*o.hours and nullif(btrim(o.gift_name),'') is not null
      or o.mode='discount' and o.price<=c.price*o.hours and nullif(btrim(o.gift_name),'') is null and o.gift_value=0)
    and (o.usage_limit is null or o.usage_limit>(
      select count(*) from reserveflow_private.rf_promotion_selections h
      left join public.bookings b on b.id=h.booking_id where h.offer_id=o.id
        and (h.booking_id is null and h.held_until>now() or b.id is not null and b.status<>'cancelled')));
$$;

create or replace function reserveflow_private.rf_promotion_terms(p_request jsonb,p_quote boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_offer uuid := (p_request->>'offer_id')::uuid;
  v_id uuid := (p_request->>'p_request_id')::uuid;
  v_sha bytea := sha256(convert_to(p_request::text,'UTF8'));
  shop uuid;
  category public.categories%rowtype;
  offer public.rf_promotion_offers%rowtype;
  selection reserveflow_private.rf_promotion_selections%rowtype;
  regular numeric;
  duration integer := (p_request->>'p_hours')::integer;
  terms jsonb;
begin
  if v_offer is null then return null; end if;
  if v_id is null then raise invalid_parameter_value; end if;
  select id into shop from public.shops where slug=p_request->>'p_shop_slug' and public_booking_enabled;
  select * into category from public.categories where shop_id=shop and code=p_request->>'p_category_code'
    and visible and template in ('seat','vip','staff');
  select * into offer from public.rf_promotion_offers where id=v_offer and shop_id=shop for update;
  if category.shop_id is null or offer.id is null then raise exception 'PROMOTION_UNAVAILABLE'; end if;
  select * into selection from reserveflow_private.rf_promotion_selections where request_id=v_id for update;
  if found then
    if selection.request_hash<>v_sha or selection.offer_id<>v_offer then raise exception 'PROMOTION_QUOTE_MISMATCH'; end if;
    if selection.booking_id is not null or selection.held_until>now() then return selection.terms; end if;
    raise exception 'PROMOTION_QUOTE_EXPIRED';
  end if;
  if not p_quote then raise exception 'PROMOTION_QUOTE_EXPIRED'; end if;
  if exists(select 1 from public.bookings where id=v_id) then raise exception 'PROMOTION_QUOTE_MISMATCH'; end if;
  regular := category.price*offer.hours;
  if (offer.category_code is not null and offer.category_code<>category.code)
    or not offer.active or offer.hours not between 1 and 5
    or duration is null or duration < offer.hours
    or duration > (case when category.template='seat' then 6 else 5 end)
    or (duration > offer.hours and exists (
      select 1 from generate_series(offer.hours+1,5) as later(hours)
      where public.rf_booking_offers(p_request->>'p_shop_slug',category.code,later.hours) <> '[]'::jsonb
    ))
    or (offer.starts_at is not null and now()<offer.starts_at)
    or (offer.ends_at is not null and now()>=offer.ends_at)
    or (offer.mode='gift' and (offer.price<>regular or nullif(btrim(offer.gift_name),'') is null))
    or (offer.mode='discount' and (offer.price>regular or nullif(btrim(offer.gift_name),'') is not null or offer.gift_value<>0))
    then raise exception 'PROMOTION_UNAVAILABLE'; end if;
  if offer.usage_limit is not null and (
    select count(*) from reserveflow_private.rf_promotion_selections h
    left join public.bookings b on b.id=h.booking_id
    where h.offer_id=offer.id and (h.booking_id is null and h.held_until>now()
      or b.id is not null and b.status<>'cancelled')
  )>=offer.usage_limit then raise exception 'PROMOTION_SOLD_OUT'; end if;
  terms := jsonb_build_object('id',offer.id,'name',offer.name,'mode',offer.mode,'hours',offer.hours,
    'gift',offer.gift_name,'gift_value',offer.gift_value,'price',offer.price,'fee',category.service_fee,
    'regular_rate',category.price,'extra_hours',duration-offer.hours,
    'amount',offer.price+category.service_fee+(duration-offer.hours)*category.price,'held_until',now()+interval '15 minutes');
  insert into reserveflow_private.rf_promotion_selections(request_id,shop_id,offer_id,terms,request_hash,held_until)
  values(v_id,shop,v_offer,terms,v_sha,(terms->>'held_until')::timestamptz)
  on conflict(request_id) do nothing;
  if not found then raise exception 'PROMOTION_QUOTE_MISMATCH'; end if;
  return terms;
end;
$$;

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

  select s.timezone, c.price, c.service_fee, case when s.promotions_online_only then '{}'::jsonb else c.hour_promotions end as hour_promotions, c.template, r.capacity,r.display into resource
  from public.shops s
  join public.categories c on c.shop_id = s.id
  join public.resources r on (r.shop_id, r.category_code) = (c.shop_id, c.code)
  where s.id = p_shop_id
    and c.code = p_category_code and r.code = p_resource_code for share of r,c;

  if not found or p_request_id is null
    or char_length(guest_name) > 100
    or (normalized_phone <> '' and normalized_phone !~ '^0[0-9]{8,9}$') then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING';
  end if;

  if role_name='staff' and (resource.template not in ('table','seat') or not walk_in) then
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
    if p_hours is not null and p_hours not between 1 and 5 then
      raise exception using errcode = '22023', message = 'INVALID_BOOKING';
    end if;
    duration_hours := coalesce(p_hours,2);
    quantity := coalesce(p_guests, p_tickets);
  end if;

  if walk_in then
    start_at := clock_time;
  else
    if p_date is null or not isfinite(p_date)
      or p_hour is null or p_hour not between 0 and 23
      or p_minute is null or p_minute not in (0, 30) then
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
  if not walk_in and (start_at <= clock_time or ((start_at at time zone resource.timezone)-interval '6 hours')::date >
    ((clock_time at time zone resource.timezone)-interval '6 hours')::date + 90) then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_DATE';
  end if;
  total := reserveflow_private.booking_category_amount(resource.template,resource.price,
    resource.service_fee,resource.hour_promotions,quantity);
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

create or replace function public.create_merchant_actual_booking(
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
  normalized_phone text := regexp_replace(coalesce(p_phone, ''), '[[:space:]-]', '', 'g');
  guest_name text := coalesce(nullif(btrim(p_name), ''), 'ลูกค้าหน้าร้าน');
  total numeric;
  duration_hours integer;
  quantity integer;
  existing public.bookings%rowtype;
begin
  select role into role_name from public.shop_members where shop_id=p_shop_id and user_id=(select auth.uid());
  if role_name is null then raise insufficient_privilege; end if;

  select s.timezone, c.price, c.service_fee, case when s.promotions_online_only then '{}'::jsonb else c.hour_promotions end as hour_promotions, c.template, r.capacity,r.display into resource
  from public.shops s
  join public.categories c on c.shop_id = s.id
  join public.resources r on (r.shop_id, r.category_code) = (c.shop_id, c.code)
  where s.id = p_shop_id
    and c.code = p_category_code and r.code = p_resource_code for share of r,c;

  if not found or p_request_id is null
    or char_length(guest_name) > 100
    or (normalized_phone <> '' and normalized_phone !~ '^0[0-9]{8,9}$') then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING';
  end if;

  if role_name='staff' and resource.template<>'table' then
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
    if p_hours is not null and p_hours not between 1 and 5 then
      raise exception using errcode = '22023', message = 'INVALID_BOOKING';
    end if;
    duration_hours := coalesce(p_hours,2);
    quantity := coalesce(p_guests, p_tickets);
  end if;

  if p_date is null or not isfinite(p_date)
    or p_hour is null or p_hour not between 0 and 23 or p_minute is null or p_minute not between 0 and 59 then
    raise exception using errcode='22023',message='INVALID_ACTUAL_BOOKING_DATE';
  end if;
  start_at := (p_date+make_time(p_hour,p_minute,0)) at time zone resource.timezone;

  perform pg_advisory_xact_lock(hashtextextended('booking-request:' || p_request_id::text, 0));
  select * into existing from public.bookings where id = p_request_id;
  if found then
    if (existing.shop_id, existing.category_code, existing.resource_code,
        existing.guests, existing.tickets, existing.customer_name, existing.customer_phone)
      is distinct from (p_shop_id, p_category_code, p_resource_code, p_guests, p_tickets, guest_name, normalized_phone)
      or existing.ends_at <> existing.starts_at + make_interval(hours => duration_hours)
      or existing.starts_at <> start_at then
      raise exception using errcode = '22023', message = 'BOOKING_REQUEST_MISMATCH';
    end if;
    return existing.id;
  end if;

  if resource.display @> '{"archived":true}' then
    raise exception using errcode = '22023', message = 'BOOKING_OPTION_UNAVAILABLE';
  end if;
  if start_at > clock_time then
    raise exception using errcode='22023',message='INVALID_ACTUAL_BOOKING_DATE';
  end if;
  total := reserveflow_private.booking_category_amount(resource.template,resource.price,
    resource.service_fee,resource.hour_promotions,quantity);
  if total > 9999999999.99 then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_PRICE';
  end if;

  insert into public.bookings (
    id, shop_id, category_code, resource_code, starts_at, ends_at,
    customer_name, customer_phone, guests, tickets, amount, status
  ) values (
    p_request_id, p_shop_id, p_category_code, p_resource_code, start_at, start_at + make_interval(hours => duration_hours),
    guest_name, normalized_phone, p_guests, p_tickets, total, 'checked_in'
  );
  return p_request_id;
exception when exclusion_violation then
  raise exception using errcode = '23P01', message = 'BOOKING_SLOT_TAKEN';
end;
$$;

notify pgrst,'reload schema';
commit;
