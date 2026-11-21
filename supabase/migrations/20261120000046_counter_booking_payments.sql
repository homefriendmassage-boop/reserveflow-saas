begin;

create table reserveflow_private.counter_booking_payments (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  walk_in boolean not null
);

alter table reserveflow_private.shop_line_channels add column friend_basic_id text;

create function public.shop_line_friend_id(p_shop_id uuid)
returns text language plpgsql stable security definer set search_path='' as $$
begin
  perform reserveflow_private.line_scope(p_shop_id);
  return (select friend_basic_id from reserveflow_private.shop_line_channels where shop_id=p_shop_id);
end;
$$;

create function public.save_shop_line_friend_id(p_shop_id uuid,p_basic_id text)
returns void language plpgsql security definer set search_path='' as $$
declare basic_id text := nullif(btrim(p_basic_id),'');
begin
  perform reserveflow_private.line_scope(p_shop_id);
  if p_shop_id is null or (basic_id is not null and basic_id !~ '^@[A-Za-z0-9._-]{1,49}$') then
    raise invalid_parameter_value;
  end if;
  update reserveflow_private.shop_line_channels set friend_basic_id=basic_id where shop_id=p_shop_id;
  if not found then raise exception using message='SHOP_LINE_NOT_CONFIGURED'; end if;
end;
$$;

-- Staff may open, check in and close seats with the same permissions as tables.
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

create or replace function public.list_merchant_bookings(p_shop_id uuid)
returns table(id uuid,category_code text,resource_code text,starts_at timestamptz,ends_at timestamptz,
  customer_name text,amount numeric,status text)
language plpgsql stable security definer set search_path=''
as $$
declare role_name text;
begin
  select role into role_name from public.shop_members
  where shop_id=p_shop_id and user_id=(select auth.uid());
  if role_name is null then raise insufficient_privilege; end if;
  return query select b.id,b.category_code,b.resource_code,b.starts_at,b.ends_at,b.customer_name,
    case when role_name<>'staff' then b.amount end,b.status
  from public.bookings b join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
  where b.shop_id=p_shop_id and (role_name<>'staff' or c.template in ('table','seat'))
    and b.status not in ('completed','cancelled')
  order by b.starts_at,b.id;
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
  if role_name='staff' and (p_status<>'completed' or booking.template not in ('table','seat') or booking.status not in ('checked_in','completed')) then
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
      where b.shop_id=p_shop_id and b.id=p_booking_id and c.template in ('table','seat')) then
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

create function public.create_counter_booking_payment(p_shop_id uuid,p_request jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  requested_id uuid := (p_request->>'p_request_id')::uuid;
  booking_id_value uuid;
  booking public.bookings%rowtype;
begin
  if requested_id is null or not coalesce(regexp_replace(p_request->>'p_phone','[[:space:]-]','','g') ~ '^0[0-9]{8,9}$',false) then
    raise exception using errcode='22023',message='COUNTER_PHONE_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('booking-request:'||requested_id::text,0));
  if exists(select 1 from public.bookings where id=requested_id)
    and not exists(select 1 from reserveflow_private.counter_booking_payments where booking_id=requested_id) then
    raise exception using errcode='22023',message='BOOKING_REQUEST_MISMATCH';
  end if;

  booking_id_value := public.create_merchant_booking(p_shop_id,requested_id,
    p_request->>'p_category_code',p_request->>'p_resource_code',(p_request->>'p_date')::date,
    (p_request->>'p_hour')::integer,(p_request->>'p_minute')::integer,(p_request->>'p_guests')::integer,
    (p_request->>'p_hours')::integer,(p_request->>'p_tickets')::integer,p_request->>'p_name',p_request->>'p_phone');
  select * into strict booking from public.bookings where id=booking_id_value;
  insert into reserveflow_private.counter_booking_payments(booking_id,walk_in)
    values(booking_id_value,p_request->>'p_date' is null) on conflict do nothing;
  if found then
    if booking.amount<=0 or (not exists(select 1 from public.shop_promptpay where shop_id=p_shop_id)
      and reserveflow_private.booking_bank_account(booking_id_value) is null) then
      raise exception using errcode='22023',message='BOOKING_PAYMENT_UNAVAILABLE';
    end if;
    update public.bookings set status='pending_payment',review_hold=true where id=booking_id_value;
  end if;
  return (reserveflow_private.issue_booking_pass(jsonb_build_object('id',booking_id_value))->>'pass_token')::uuid;
end;
$$;

create function public.merchant_counter_payment_token(p_shop_id uuid,p_booking_id uuid)
returns uuid language sql stable security definer set search_path='' as $$
  select p.view_token from reserveflow_private.booking_passes p
  join reserveflow_private.counter_booking_payments c on c.booking_id=p.booking_id
  join public.bookings b on b.id=p.booking_id and b.shop_id=p_shop_id
  join public.shop_members m on m.shop_id=b.shop_id and m.user_id=auth.uid()
  where p.booking_id=p_booking_id and b.status in ('pending_payment','slip_review');
$$;

create or replace function public.booking_promptpay_qr(p_booking_id uuid,p_phone text)
returns text language plpgsql stable security definer set search_path=''
as $$
declare
  recipient text;
  charge numeric;
  proxy_field text;
  amount_text text;
  account text;
  qr text;
  crc integer := 65535;
  pos integer;
  bit_index integer;
begin
  select p.mobile,b.amount into recipient,charge from public.bookings b
  join public.shop_promptpay p on p.shop_id=b.shop_id
  where b.id=p_booking_id and b.customer_phone=regexp_replace(p_phone,'[[:space:]-]','','g')
    and b.created_at>now()-interval '24 hours' and (b.starts_at>now() or (b.ends_at>now() and exists(
      select 1 from reserveflow_private.counter_booking_payments c where c.booking_id=b.id)))
    and b.status in ('pending_confirm','pending_payment','slip_review') and b.amount>0;
  if not found then return null; end if;
  proxy_field := case when length(recipient)=13 then '0213'||recipient
    else '0113'||'0066'||substr(recipient,2) end;
  account := '0016A000000677010111'||proxy_field;
  amount_text := charge::numeric(12,2)::text;
  qr := '00020101021229'||lpad(length(account)::text,2,'0')||account||
    '5802TH530376454'||lpad(length(amount_text)::text,2,'0')||amount_text||'6304';
  for pos in 1..length(qr) loop
    crc := crc # (ascii(substr(qr,pos,1)) << 8);
    for bit_index in 1..8 loop
      crc := ((crc << 1) # (case when (crc & 32768)<>0 then 4129 else 0 end)) & 65535;
    end loop;
  end loop;
  return qr||upper(lpad(to_hex(crc),4,'0'));
end;
$$;

create function public.counter_booking_payment_details(p_token uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'amount',b.amount,'has_slip',a.booking_id is not null,'line_friend_id',l.friend_basic_id,
    'can_pay',a.booking_id is null and b.status='pending_payment' and b.ends_at>now()
      and b.created_at>now()-interval '24 hours',
    'qr',case when a.booking_id is null then public.booking_promptpay_qr(b.id,b.customer_phone) end,
    'bank_account',case when a.booking_id is null and b.status='pending_payment' and b.ends_at>now()
      and b.created_at>now()-interval '24 hours' then reserveflow_private.booking_bank_account(b.id) end)
  from reserveflow_private.booking_passes p
  join public.bookings b on b.id=p.booking_id
  join reserveflow_private.counter_booking_payments c on c.booking_id=b.id
  left join public.booking_slip_attachments a on a.booking_id=b.id
  left join reserveflow_private.shop_line_channels l on l.shop_id=b.shop_id
  where p.view_token=p_token and now()<=b.ends_at+interval '30 days';
$$;

create function public.attach_counter_booking_slip(p_token uuid,p_image text)
returns void language plpgsql security definer set search_path='' as $$
declare
  booking public.bookings%rowtype;
  image_bytes bytea;
begin
  select b.* into booking from reserveflow_private.booking_passes p
  join public.bookings b on b.id=p.booking_id
  join reserveflow_private.counter_booking_payments c on c.booking_id=b.id
  where p.view_token=p_token for update of b;
  if not found or booking.ends_at<=now() then
    raise exception using errcode='22023',message='SLIP_BOOKING_UNAVAILABLE';
  end if;
  if not coalesce(length(p_image)<=1450000
    and p_image ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$',false) then
    raise exception using errcode='22023',message='INVALID_SLIP_ATTACHMENT';
  end if;
  image_bytes := decode(split_part(p_image,',',2),'base64');
  if octet_length(image_bytes)>1048576 or not (case split_part(p_image,';',1)
    when 'data:image/jpeg' then substring(image_bytes,1,3)=decode('ffd8ff','hex')
    when 'data:image/png' then substring(image_bytes,1,8)=decode('89504e470d0a1a0a','hex')
    when 'data:image/webp' then substring(image_bytes,1,4)=decode('52494646','hex')
      and substring(image_bytes,9,4)=decode('57454250','hex')
    else false end) then
    raise exception using errcode='22023',message='INVALID_SLIP_ATTACHMENT';
  end if;
  perform public.attach_customer_booking_slip(booking.id,booking.customer_phone,p_image);
  update public.bookings set status='slip_review' where id=booking.id and status='pending_payment';
end;
$$;

create function public.confirm_counter_booking_payment(p_shop_id uuid,p_booking_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare reservation record;
begin
  if not exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=auth.uid()
    and role in ('owner','admin','cashier')) then raise insufficient_privilege; end if;
  select b.status,b.starts_at,b.ends_at,c.walk_in into reservation
  from public.bookings b join reserveflow_private.counter_booking_payments c on c.booking_id=b.id
  where b.id=p_booking_id and b.shop_id=p_shop_id for update of b;
  if not found then raise invalid_parameter_value; end if;
  if reservation.status in ('confirmed','checked_in') then return; end if;
  if reservation.status<>'slip_review' or reservation.ends_at<=now()
    or not exists(select 1 from public.booking_slip_attachments where booking_id=p_booking_id) then
    raise exception using errcode='22023',message='SLIP_BOOKING_UNAVAILABLE';
  end if;
  update public.bookings set status='confirmed' where id=p_booking_id;
  if reservation.walk_in then
    update public.bookings set status='checked_in' where id=p_booking_id;
  end if;
end;
$$;

revoke all on function public.shop_line_friend_id(uuid),public.save_shop_line_friend_id(uuid,text),
  public.create_counter_booking_payment(uuid,jsonb),public.merchant_counter_payment_token(uuid,uuid),
  public.confirm_counter_booking_payment(uuid,uuid),public.counter_booking_payment_details(uuid),
  public.attach_counter_booking_slip(uuid,text) from public,anon,authenticated;
grant execute on function public.shop_line_friend_id(uuid),public.save_shop_line_friend_id(uuid,text),
  public.create_counter_booking_payment(uuid,jsonb),public.merchant_counter_payment_token(uuid,uuid),
  public.confirm_counter_booking_payment(uuid,uuid) to authenticated;
grant execute on function public.counter_booking_payment_details(uuid),public.attach_counter_booking_slip(uuid,text)
  to anon,authenticated;
notify pgrst,'reload schema';
commit;
