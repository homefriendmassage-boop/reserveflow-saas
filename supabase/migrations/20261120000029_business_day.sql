begin;

-- Keep calendar dates in the RPC contract. The UI maps after-midnight slots to the next calendar date.

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
    if p_hours is not null and p_hours not between 1 and 5 then
      raise exception using errcode = '22023', message = 'INVALID_BOOKING';
    end if;
    duration_hours := coalesce(p_hours,2);
    quantity := coalesce(p_guests, p_tickets);
  end if;

  local_today := ((statement_timestamp() at time zone selected.timezone)-interval '6 hours')::date;
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
  total := resource.price * quantity + resource.service_fee;
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
  select case when c.template='table' then coalesce(p_hours,2) else p_hours end into duration
  from public.categories c join public.resources r on (r.shop_id,r.category_code)=(c.shop_id,c.code)
  where c.shop_id=shop and c.code=p_category_code and c.visible and c.template in ('table','seat','vip')
    and r.code=p_resource_code and not (r.display @> '{"archived":true}');
  if duration is null or duration not between 1 and 6 or p_hour not between 0 and 23
    or p_minute not in (0,30) or p_date is null or not isfinite(p_date)
    or p_hour is null or p_minute is null then return; end if;
  opening := (p_date+make_time(p_hour,p_minute,0)) at time zone zone;
  if ((opening at time zone zone)-interval '6 hours')::date not between
    ((now() at time zone zone)-interval '6 hours')::date and ((now() at time zone zone)-interval '6 hours')::date+90
    then return; end if;
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
      and p_hour between 0 and 23 and p_minute in (0, 30)
      and (p_date + make_time(p_hour,p_minute,0) - interval '6 hours')::date between
        ((statement_timestamp() at time zone s.timezone)-interval '6 hours')::date
        and ((statement_timestamp() at time zone s.timezone)-interval '6 hours')::date + 90
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
    select s.id, c.code, coalesce(p_hours,2) as duration_hours,
      (p_date + make_time(p_hour, p_minute, 0)) at time zone s.timezone as starts_at
    from public.shops s
    join public.categories c on c.shop_id = s.id
    where s.slug = p_shop_slug and s.public_booking_enabled and c.visible
      and c.code = p_category_code and c.template in ('table', 'seat', 'vip')
      and ((c.template = 'table' and coalesce(p_hours,2) between 1 and 5) or (c.template = 'seat' and p_hours between 1 and 6)
        or (c.template = 'vip' and p_hours between 1 and 5))
      and p_hour between 0 and 23 and p_minute in (0, 30)
      and (p_date + make_time(p_hour,p_minute,0) - interval '6 hours')::date between
        ((statement_timestamp() at time zone s.timezone)-interval '6 hours')::date
        and ((statement_timestamp() at time zone s.timezone)-interval '6 hours')::date + 90
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
    or p_date>((now() at time zone shop.timezone)-interval '6 hours')::date then raise invalid_parameter_value; end if;
  start_day := (p_date + time '06:00') at time zone shop.timezone;
  end_day := (p_date+1 + time '06:00') at time zone shop.timezone;

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

create or replace function reserveflow_private.booking_pass_details(p_booking uuid)
returns jsonb language sql stable set search_path=''
as $$
  select jsonb_build_object('booking_id',b.id,'shop',s.name,'item',r.name,'category',c.name,
    'date',to_char((b.starts_at at time zone s.timezone)-interval '6 hours','DD/MM/YYYY'),
    'period',to_char(b.starts_at at time zone s.timezone,'HH24:MI')||
      case when (b.starts_at at time zone s.timezone)::time<time '06:00' then ' (+1 วัน)' else '' end||' – '||
      to_char(b.ends_at at time zone s.timezone,'HH24:MI')||
      case when ((b.starts_at at time zone s.timezone)-interval '6 hours')::date<>(b.ends_at at time zone s.timezone)::date
        then ' (+1 วัน)' else '' end,
    'hours',extract(epoch from b.ends_at-b.starts_at)/3600,'amount',b.amount,'status',b.status)
  from public.bookings b join public.shops s on s.id=b.shop_id
  join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
  join public.resources r on (r.shop_id,r.category_code,r.code)=(b.shop_id,b.category_code,b.resource_code)
  where b.id=p_booking;
$$;

create or replace function public.get_customer_booking_pass(p_token uuid)
returns jsonb language sql stable security definer set search_path=''
as $$
  select reserveflow_private.booking_pass_details(b.id) || jsonb_build_object(
    'scan_token',case when b.status='confirmed' and now()<b.ends_at then t.scan_token end,
    'line_code',case when c.bot_id is not null and (t.line_user is null or t.line_bot is distinct from c.bot_id)
      and b.ends_at>now() and b.status in ('pending_payment','pending_confirm','slip_review','confirmed') then t.line_token end,
    'line_linked',t.line_user is not null and t.line_bot=c.bot_id,
    'line_delivery',case when delivery.delivered_at is not null then 'accepted'
      when delivery.attempts>=8 then 'failed' when delivery.attempts is not null then 'queued' end,
    'bot_name',c.bot_name,'expired',now()>=b.ends_at)
  from reserveflow_private.booking_passes t join public.bookings b on b.id=t.booking_id
  left join reserveflow_private.shop_line_channels c on c.shop_id=b.shop_id
  left join lateral (
    select q.delivered_at,q.attempts from reserveflow_private.line_outbox q
    where q.customer_booking_id=t.booking_id and q.kind='booking_pass' and q.sender_bot_id=c.bot_id
    order by q.next_at desc limit 1
  ) delivery on true
  where t.view_token=p_token and now()<=b.ends_at+interval '30 days';
$$;

commit;
