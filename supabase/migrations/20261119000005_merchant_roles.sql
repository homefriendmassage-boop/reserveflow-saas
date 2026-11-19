begin;

alter table public.shop_members drop constraint shop_members_role_check;
alter table public.shop_members add constraint shop_members_role_check
  check (role in ('owner', 'admin', 'cashier', 'staff'));

-- Existing admin memberships retain their table-management permissions.
create or replace function public.create_merchant_table_booking(
  p_shop_id uuid, p_request_id uuid, p_category_code text, p_resource_code text,
  p_date date, p_hour integer, p_minute integer, p_guests integer, p_name text, p_phone text
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
  existing public.bookings%rowtype;
begin
  if not exists (
    select 1 from public.shop_members m
    where m.shop_id = p_shop_id and m.user_id = (select auth.uid()) and m.role in ('owner', 'admin', 'cashier')
  ) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;

  select s.timezone, c.price, c.service_fee, r.capacity into resource
  from public.shops s
  join public.categories c on c.shop_id = s.id
  join public.resources r on (r.shop_id, r.category_code) = (c.shop_id, c.code)
  where s.id = p_shop_id and c.template = 'table'
    and c.code = p_category_code and r.code = p_resource_code;

  if not found or p_request_id is null or p_guests is null or p_guests not between 1 and 100
    or (resource.capacity is not null and p_guests > resource.capacity)
    or char_length(guest_name) > 100
    or (normalized_phone <> '' and normalized_phone !~ '^0[0-9]{8,9}$') then
    raise exception using errcode = '22023', message = 'INVALID_TABLE_BOOKING';
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
        existing.guests, existing.customer_name, existing.customer_phone)
      is distinct from (p_shop_id, p_category_code, p_resource_code, p_guests, guest_name, normalized_phone)
      or (not walk_in and existing.starts_at <> start_at) then
      raise exception using errcode = '22023', message = 'BOOKING_REQUEST_MISMATCH';
    end if;
    return existing.id;
  end if;

  if not walk_in and (start_at <= clock_time or p_date > (clock_time at time zone resource.timezone)::date + 90) then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_DATE';
  end if;
  total := resource.price * p_guests + resource.service_fee;
  if total > 9999999999.99 then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_PRICE';
  end if;

  insert into public.bookings (
    id, shop_id, category_code, resource_code, starts_at, ends_at,
    customer_name, customer_phone, guests, amount, status
  ) values (
    p_request_id, p_shop_id, p_category_code, p_resource_code, start_at, start_at + interval '2 hours',
    guest_name, normalized_phone, p_guests, total, case when walk_in then 'checked_in' else 'confirmed' end
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
  join public.categories c on (b.shop_id, b.category_code) = (c.shop_id, c.code)
  where b.id = p_booking_id and b.shop_id = p_shop_id and c.template = 'table'
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

create function public.update_merchant_shop(p_shop_id uuid, p_name text, p_enabled boolean)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role = 'owner') then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 100 or p_enabled is null then
    raise exception using errcode = '22023', message = 'INVALID_SHOP_SETTINGS';
  end if;
  update public.shops set name = btrim(p_name), public_booking_enabled = p_enabled where id = p_shop_id;
end;
$$;

create function public.move_merchant_table(
  p_shop_id uuid, p_category_code text, p_resource_code text, p_x integer, p_y integer
)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role in ('owner', 'admin', 'cashier')) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_x is null or p_y is null or p_x not between 5 and 95 or p_y not between 5 and 95 then
    raise exception using errcode = '22023', message = 'INVALID_TABLE_POSITION';
  end if;
  update public.resources r
    set display = (case when jsonb_typeof(r.display) = 'object' then r.display else '{}'::jsonb end)
      || jsonb_build_object('x', p_x, 'y', p_y)
  from public.categories c
  where (r.shop_id, r.category_code) = (c.shop_id, c.code) and c.template = 'table'
    and r.shop_id = p_shop_id and r.category_code = p_category_code and r.code = p_resource_code;
  if not found then
    raise exception using errcode = '22023', message = 'INVALID_TABLE_POSITION';
  end if;
end;
$$;

create function public.check_in_merchant_booking(p_shop_id uuid, p_booking_id uuid)
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

create function public.set_merchant_staff_role(p_shop_id uuid, p_user_id uuid, p_role text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role = 'owner') then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_user_id is null or p_role is null or p_role not in ('cashier', 'staff', 'remove')
    or not exists (select 1 from auth.users where id = p_user_id) then
    raise exception using errcode = '22023', message = 'INVALID_STAFF_ROLE';
  end if;
  if p_role = 'remove' then
    delete from public.shop_members where shop_id = p_shop_id and user_id = p_user_id and role <> 'owner';
  else
    insert into public.shop_members (shop_id, user_id, role) values (p_shop_id, p_user_id, p_role)
      on conflict (shop_id, user_id) do update set role = excluded.role where shop_members.role <> 'owner';
  end if;
  if not found then
    raise exception using errcode = '22023', message = 'INVALID_STAFF_ROLE';
  end if;
end;
$$;

revoke all on function public.update_merchant_shop(uuid, text, boolean),
  public.move_merchant_table(uuid, text, text, integer, integer),
  public.check_in_merchant_booking(uuid, uuid),
  public.set_merchant_staff_role(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.update_merchant_shop(uuid, text, boolean),
  public.move_merchant_table(uuid, text, text, integer, integer),
  public.check_in_merchant_booking(uuid, uuid),
  public.set_merchant_staff_role(uuid, uuid, text) to authenticated;

commit;
