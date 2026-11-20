begin;

create function public.link_verified_shop_line_user(p_shop_id uuid,p_owner uuid,p_bot_id text,p_user_id text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not coalesce(p_user_id ~ '^U[0-9a-f]{32}$',false) then raise invalid_parameter_value; end if;
  perform pg_advisory_xact_lock(hashtextextended('line-pairing:'||p_shop_id::text,0));
  if not exists(select 1 from public.shop_members m where m.shop_id=p_shop_id and m.user_id=p_owner and m.role='owner')
    or not exists(select 1 from reserveflow_private.shop_line_channels s where s.shop_id=p_shop_id and s.bot_id=p_bot_id)
  then raise insufficient_privilege; end if;
  insert into reserveflow_private.line_targets(owner_scope,target,target_type,bot_id)
  values(p_shop_id::text,p_user_id,'user',p_bot_id)
  on conflict(owner_scope,target) do update set bot_id=excluded.bot_id
  where line_targets.bot_id is distinct from excluded.bot_id;
end;
$$;
revoke all on function public.link_verified_shop_line_user(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.link_verified_shop_line_user(uuid,uuid,text,text) to service_role;

create function public.create_merchant_actual_booking(
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
    if p_hours is not null then
      raise exception using errcode = '22023', message = 'INVALID_BOOKING';
    end if;
    duration_hours := 2;
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
revoke all on function public.create_merchant_actual_booking(uuid,uuid,text,text,date,integer,integer,integer,integer,integer,text,text)
from public,anon,authenticated;
grant execute on function public.create_merchant_actual_booking(uuid,uuid,text,text,date,integer,integer,integer,integer,integer,text,text)
to authenticated;
commit;
