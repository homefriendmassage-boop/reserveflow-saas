begin;

create table reserveflow_private.merchant_cash_payments (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  amount numeric(12,2) not null check (amount >= 0),
  received_at timestamptz not null default statement_timestamp(),
  received_by uuid references auth.users(id) on delete set null
);

create function public.create_merchant_cash_booking(
  p_shop_id uuid,p_request jsonb,p_actual boolean,p_line_user text default null
)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
  request record;
  booking_id_value uuid;
  received_amount numeric;
begin
  if not exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=auth.uid()
    and role in ('owner','admin','cashier','staff')) then raise insufficient_privilege; end if;
  select * into request from jsonb_to_record(p_request) as fields(
    p_request_id uuid,p_category_code text,p_resource_code text,p_date date,p_hour integer,p_minute integer,
    p_guests integer,p_hours integer,p_tickets integer,p_name text,p_phone text);
  if request.p_request_id is null or p_actual is null then raise invalid_parameter_value; end if;

  perform pg_advisory_xact_lock(hashtextextended('booking-request:'||request.p_request_id::text,0));
  if exists(select 1 from public.bookings where id=request.p_request_id)
    and not exists(select 1 from reserveflow_private.merchant_cash_payments where booking_id=request.p_request_id) then
    raise exception using errcode='22023',message='BOOKING_REQUEST_MISMATCH';
  end if;

  if p_line_user is not null then
    booking_id_value := public.create_merchant_booking_for_line(p_shop_id,p_request,p_line_user,p_actual);
  elsif p_actual then
    booking_id_value := public.create_merchant_actual_booking(p_shop_id,request.p_request_id,
      request.p_category_code,request.p_resource_code,request.p_date,request.p_hour,request.p_minute,
      request.p_guests,request.p_hours,request.p_tickets,request.p_name,request.p_phone);
  else
    booking_id_value := public.create_merchant_booking(p_shop_id,request.p_request_id,
      request.p_category_code,request.p_resource_code,request.p_date,request.p_hour,request.p_minute,
      request.p_guests,request.p_hours,request.p_tickets,request.p_name,request.p_phone);
  end if;

  select amount into strict received_amount from public.bookings where id=booking_id_value and shop_id=p_shop_id;
  if p_request->>'p_expected_amount' is not null
    and received_amount is distinct from (p_request->>'p_expected_amount')::numeric then
    raise exception using errcode='22023',message='BOOKING_PRICE_CHANGED';
  end if;
  insert into reserveflow_private.merchant_cash_payments(booking_id,amount,received_by)
  values(booking_id_value,received_amount,auth.uid()) on conflict(booking_id) do nothing;
  return booking_id_value;
end;
$$;

create function public.merchant_cash_booking_ids(p_shop_id uuid)
returns uuid[] language sql stable security definer set search_path=''
as $$
  select coalesce(array_agg(b.id),'{}'::uuid[])
  from reserveflow_private.merchant_cash_payments p join public.bookings b on b.id=p.booking_id
  join public.shop_members m on m.shop_id=b.shop_id and m.user_id=auth.uid()
  where b.shop_id=p_shop_id and p.amount>0 and b.status not in ('completed','cancelled');
$$;

revoke all on function public.create_merchant_cash_booking(uuid,jsonb,boolean,text),
  public.merchant_cash_booking_ids(uuid) from public,anon,authenticated;
grant execute on function public.create_merchant_cash_booking(uuid,jsonb,boolean,text),
  public.merchant_cash_booking_ids(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
