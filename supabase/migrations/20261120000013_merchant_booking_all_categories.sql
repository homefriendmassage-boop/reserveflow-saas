begin;

create function public.require_distinct_resource_name()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and (old.shop_id,old.category_code,lower(btrim(old.name)))
    is not distinct from (new.shop_id,new.category_code,lower(btrim(new.name))) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('resource-name:' || new.shop_id::text || ':' || new.category_code, 0));
  if exists (select 1 from public.resources r where r.shop_id = new.shop_id and r.category_code = new.category_code
    and r.code <> new.code and lower(btrim(r.name)) = lower(btrim(new.name))) then
    raise exception using errcode = '23505', message = 'RESOURCE_NAME_EXISTS';
  end if;
  return new;
end;
$$;

create trigger reserveflow_distinct_resource_name before insert or update of shop_id, category_code, name on public.resources
for each row execute function public.require_distinct_resource_name();

revoke all on function public.require_distinct_resource_name() from public, anon, authenticated;


create function public.create_merchant_booking(
  p_shop_id uuid, p_request_id uuid, p_category_code text, p_resource_code text,
  p_date date, p_hour integer, p_minute integer, p_guests integer, p_hours integer, p_tickets integer, p_name text, p_phone text
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  resource record;
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
  if not exists (
    select 1 from public.shop_members m
    where m.shop_id = p_shop_id and m.user_id = (select auth.uid()) and m.role in ('owner', 'admin', 'cashier')
  ) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;

  select s.timezone, c.price, c.service_fee, c.template, r.capacity into resource
  from public.shops s
  join public.categories c on c.shop_id = s.id
  join public.resources r on (r.shop_id, r.category_code) = (c.shop_id, c.code)
  where s.id = p_shop_id
    and c.code = p_category_code and r.code = p_resource_code;

  if not found or p_request_id is null
    or char_length(guest_name) > 100
    or (normalized_phone <> '' and normalized_phone !~ '^0[0-9]{8,9}$') then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING';
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
begin
  if not exists (
    select 1 from public.shop_members m
    where m.shop_id = p_shop_id and m.user_id = (select auth.uid()) and m.role in ('owner', 'admin', 'cashier')
  ) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;

  select b.status, b.starts_at into booking
  from public.bookings b
  where b.id = p_booking_id and b.shop_id = p_shop_id
  for update of b;
  if not found or p_status is null or p_status not in ('cancelled', 'completed', 'confirmed') then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_STATUS';
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

revoke all on function public.create_merchant_booking(uuid,uuid,text,text,date,integer,integer,integer,integer,integer,text,text)
  from public, anon, authenticated;
grant execute on function public.create_merchant_booking(uuid,uuid,text,text,date,integer,integer,integer,integer,integer,text,text)
  to authenticated;

commit;
