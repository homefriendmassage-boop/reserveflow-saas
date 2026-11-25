begin;

alter table public.categories add column hour_promotions jsonb not null default '{}'::jsonb;

create function reserveflow_private.booking_category_amount(
  p_template text,p_rate numeric,p_fee numeric,p_promotions jsonb,p_quantity integer
)
returns numeric language sql immutable set search_path='' as $$
  select p_fee + case when p_template in ('seat','vip','staff') then least(
    p_rate*p_quantity,
    (select min((offer.value#>>'{}')::numeric+(p_quantity-offer.key::integer)*p_rate)
      from jsonb_each(p_promotions) offer where offer.key::integer<=p_quantity)
  ) else p_rate*p_quantity end;
$$;

create function public.save_merchant_hour_promotions(p_shop_id uuid,p_code text,p_promotions jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare kind text;
begin
  if not reserveflow_private.is_platform_admin() and not reserveflow_private.is_shop_owner(p_shop_id) then
    raise insufficient_privilege;
  end if;
  select template into kind from public.categories
    where shop_id=p_shop_id and code=p_code for update;
  if kind is null or kind not in ('seat','vip','staff') or jsonb_typeof(p_promotions) is distinct from 'object' then
    raise exception using errcode='22023',message='INVALID_HOUR_PROMOTIONS';
  end if;
  if exists(select 1 from jsonb_each(p_promotions) offer
    where offer.key !~ (case when kind='seat' then '^[2-6]$' else '^[2-5]$' end)
      or case when jsonb_typeof(offer.value)='number' then
        (offer.value#>>'{}')::numeric not between 0 and 99999999.99
        or round((offer.value#>>'{}')::numeric,2)<>(offer.value#>>'{}')::numeric
      else true end) then
    raise exception using errcode='22023',message='INVALID_HOUR_PROMOTIONS';
  end if;
  update public.categories set hour_promotions=p_promotions where shop_id=p_shop_id and code=p_code;
end;
$$;

revoke all on function public.save_merchant_hour_promotions(uuid,text,jsonb),
  reserveflow_private.booking_category_amount(text,numeric,numeric,jsonb,integer) from public,anon,authenticated;
grant execute on function public.save_merchant_hour_promotions(uuid,text,jsonb) to authenticated;

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
    or p_hour is null or p_hour not between 0 and 23
    or p_minute is null or p_minute not in (0, 30)
    or char_length(customer_name) not between 1 and 100
    or normalized_phone !~ '^0[0-9]{8,9}$' or char_length(customer_note) > 500
  then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING';
  end if;

  select s.id, s.timezone, c.template, c.price, c.service_fee, c.hour_promotions, r.capacity, r.display
    into selected
  from public.shops s
  join public.categories c on c.shop_id = s.id
  join public.resources r on (r.shop_id, r.category_code) = (c.shop_id, c.code)
  where s.slug = p_shop_slug and s.public_booking_enabled and c.visible
    and c.code = p_category_code and r.code = p_resource_code for share of r,c;
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
    if p_hours is not null and p_hours not between 1 and 5 then
      raise exception using errcode = '22023', message = 'INVALID_BOOKING';
    end if;
    duration_hours := coalesce(p_hours,2);
    quantity := coalesce(p_guests, p_tickets);
  end if;

  local_today := ((statement_timestamp() at time zone selected.timezone)-interval '6 hours')::date;
  start_at := (p_date + make_time(p_hour, p_minute, 0)) at time zone selected.timezone;
  end_at := start_at + make_interval(hours => duration_hours);
  total := reserveflow_private.booking_category_amount(selected.template,selected.price,
    selected.service_fee,selected.hour_promotions,quantity);
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

  if start_at <= statement_timestamp() or ((start_at at time zone selected.timezone)-interval '6 hours')::date > local_today + 90 then
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

  select s.timezone, c.price, c.service_fee, c.hour_promotions, c.template, r.capacity,r.display into resource
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

  select s.timezone, c.price, c.service_fee, c.hour_promotions, c.template, r.capacity,r.display into resource
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

create or replace function public.booking_catalog(p_shop_slug text)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'name', s.name,
    'timezone', s.timezone,
    'slip_attachments_enabled', true,
    'promptpay_enabled', exists(select 1 from public.shop_promptpay p where p.shop_id=s.id),
    'promptpay_mobile', (select p.mobile from public.shop_promptpay p where p.shop_id=s.id and length(p.mobile)=10),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', c.code, 'name', c.name, 'template', c.template,
        'price', c.price, 'service_fee', c.service_fee, 'hour_promotions', c.hour_promotions,
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

notify pgrst,'reload schema';
commit;
