begin;

create or replace function reserveflow_private.booking_from_payment_request(p_request jsonb)
returns jsonb language sql set search_path=''
as $$
  select public.submit_customer_booking(
    (p_request->>'p_request_id')::uuid, p_request->>'p_shop_slug',
    p_request->>'p_category_code', p_request->>'p_resource_code',
    (p_request->>'p_date')::date, (p_request->>'p_hour')::integer,
    (p_request->>'p_hours')::integer, (p_request->>'p_guests')::integer,
    (p_request->>'p_tickets')::integer, p_request->>'p_name',
    p_request->>'p_phone', p_request->>'p_note', (p_request->>'p_minute')::integer
  );
$$;

create or replace function public.quote_customer_payment(p_request jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  quote jsonb;
  qr text;
begin
  begin
    quote := reserveflow_private.booking_from_payment_request(p_request);
    qr := public.booking_promptpay_qr((quote->>'id')::uuid,p_request->>'p_phone');
    if qr is null then
      raise exception using errcode='22023', message='BOOKING_PAYMENT_UNAVAILABLE';
    end if;
    -- Reuse booking validation and pricing, then roll back the row and its outbox events.
    raise sqlstate 'RF026';
  exception when sqlstate 'RF026' then
    return quote || jsonb_build_object('qr',qr);
  end;
end;
$$;

create or replace function public.submit_customer_payment(p_request jsonb,p_amount numeric,p_image text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  booking jsonb;
  booking_id_value uuid;
  image_bytes bytea;
begin
  if not coalesce(length(p_image) <= 1450000
      and p_image ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$',false) then
    raise exception using errcode='22023', message='INVALID_SLIP_ATTACHMENT';
  end if;
  image_bytes := decode(split_part(p_image,',',2),'base64');
  if octet_length(image_bytes)>1048576 or not (case split_part(p_image,';',1)
    when 'data:image/jpeg' then substring(image_bytes,1,3)=decode('ffd8ff','hex')
    when 'data:image/png' then substring(image_bytes,1,8)=decode('89504e470d0a1a0a','hex')
    when 'data:image/webp' then substring(image_bytes,1,4)=decode('52494646','hex')
      and substring(image_bytes,9,4)=decode('57454250','hex')
    else false end) then
    raise exception using errcode='22023', message='INVALID_SLIP_ATTACHMENT';
  end if;
  booking := reserveflow_private.booking_from_payment_request(p_request);
  booking_id_value := (booking->>'id')::uuid;
  if (booking->>'amount')::numeric is distinct from p_amount then
    raise exception using errcode='22023', message='BOOKING_PRICE_CHANGED';
  end if;
  if exists (
    select 1 from public.booking_slip_attachments a
    where a.booking_id=booking_id_value and a.image=p_image
  ) then
    return booking;
  end if;
  if public.booking_promptpay_qr(booking_id_value,p_request->>'p_phone') is null then
    raise exception using errcode='22023', message='BOOKING_PAYMENT_UNAVAILABLE';
  end if;
  perform public.attach_customer_booking_slip(booking_id_value,p_request->>'p_phone',p_image);
  return booking;
end;
$$;

revoke all on function reserveflow_private.booking_from_payment_request(jsonb) from public,anon,authenticated;
revoke all on function public.submit_customer_booking(uuid,text,text,text,date,integer,integer,integer,integer,text,text,text,integer) from public,anon,authenticated;
revoke all on function public.quote_customer_payment(jsonb), public.submit_customer_payment(jsonb,numeric,text) from public;
grant execute on function public.quote_customer_payment(jsonb), public.submit_customer_payment(jsonb,numeric,text) to anon,authenticated;

create or replace function reserveflow_private.queue_line_booking()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  insert into reserveflow_private.line_outbox(target_id,kind,payload)
  select t.id,'booking',jsonb_build_object(
    'name',s.name,'resource',coalesce(r.name,new.resource_code),'category',c.name,
    'date',to_char(new.starts_at at time zone s.timezone,'DD/MM/YYYY HH24:MI'),
    'time_zone',s.timezone,'booking_id',new.id,'amount',new.amount)
  from public.shops s join reserveflow_private.line_targets t on t.owner_scope=s.id::text
  left join public.categories c on (c.shop_id,c.code)=(new.shop_id,new.category_code)
  left join public.resources r on (r.shop_id,r.category_code,r.code)=(new.shop_id,new.category_code,new.resource_code)
  where s.id=new.shop_id and reserveflow_private.line_target_is_current(t);
  return new;
end;
$$;

commit;
