begin;

alter table public.rf_promotion_offers
  add column starts_at timestamptz,
  add column ends_at timestamptz,
  add column usage_limit integer check (usage_limit between 1 and 1000000),
  add constraint rf_offer_window check (starts_at is null or ends_at is null or starts_at < ends_at);
alter table public.rf_promotion_vouchers alter column line_user_id drop not null;

-- A short-lived quote reserves quota. Bound selections retain the charged price and gift terms.
create table reserveflow_private.rf_promotion_selections (
  request_id uuid primary key,
  shop_id uuid not null references public.shops(id) on delete cascade,
  offer_id uuid not null,
  terms jsonb not null,
  request_hash bytea not null,
  held_until timestamptz not null,
  booking_id uuid unique references public.bookings(id) on delete cascade,
  foreign key(offer_id,shop_id) references public.rf_promotion_offers(id,shop_id)
);
create index rf_selection_offer on reserveflow_private.rf_promotion_selections(offer_id,held_until);
create table reserveflow_private.rf_promotion_line_bindings (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  line_user text not null check(line_user ~ '^U[0-9a-f]{32}$'),
  bot_id text not null
);
create table reserveflow_private.rf_promotion_refunds (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  reference text not null check (length(btrim(reference)) between 1 and 200),
  recorded_at timestamptz not null default now()
);

-- Lock the offer before reserving quota, and bind the quote to the whole request.
create function reserveflow_private.rf_promotion_terms(p_request jsonb,p_quote boolean)
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
  if not offer.active or offer.hours not between 1 and 5
    or offer.hours is distinct from (p_request->>'p_hours')::integer
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
    'regular_rate',category.price,'amount',offer.price+category.service_fee,'held_until',now()+interval '15 minutes');
  insert into reserveflow_private.rf_promotion_selections(request_id,shop_id,offer_id,terms,request_hash,held_until)
  values(v_id,shop,v_offer,terms,v_sha,(terms->>'held_until')::timestamptz)
  on conflict(request_id) do nothing;
  if not found then raise exception 'PROMOTION_QUOTE_MISMATCH'; end if;
  return terms;
end;
$$;

create function public.rf_release_promotion_quote(p_request jsonb)
returns void language sql security definer set search_path='' as $$
  delete from reserveflow_private.rf_promotion_selections
  where request_id=(p_request->>'p_request_id')::uuid and booking_id is null
    and request_hash=sha256(convert_to(p_request::text,'UTF8'));
$$;

create function public.rf_booking_offers(p_shop_slug text,p_category_code text,p_hours integer)
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'hours',o.hours,
    'mode',o.mode,'price',o.price,'gift',o.gift_name,'gift_value',o.gift_value) order by o.price,o.id),'[]'::jsonb)
  from public.rf_promotion_offers o join public.shops s on s.id=o.shop_id
  join public.categories c on c.shop_id=s.id and c.code=p_category_code
  where s.slug=p_shop_slug and s.public_booking_enabled and reserveflow_private.shop_booking_active(s.id)
    and c.visible and c.template in ('seat','vip','staff') and o.active and o.hours=p_hours and o.hours between 1 and 5
    and (o.starts_at is null or o.starts_at<=now()) and (o.ends_at is null or o.ends_at>now())
    and (o.mode='gift' and o.price=c.price*o.hours and nullif(btrim(o.gift_name),'') is not null
      or o.mode='discount' and o.price<=c.price*o.hours and nullif(btrim(o.gift_name),'') is null and o.gift_value=0)
    and (o.usage_limit is null or o.usage_limit>(
      select count(*) from reserveflow_private.rf_promotion_selections h
      left join public.bookings b on b.id=h.booking_id where h.offer_id=o.id
        and (h.booking_id is null and h.held_until>now() or b.id is not null and b.status<>'cancelled')));
$$;

-- Existing booking validation, with an internally calculated, immutable quote amount when selected.
create function reserveflow_private.rf_submit_customer_booking(
  p_request_id uuid, p_shop_slug text, p_category_code text, p_resource_code text,
  p_date date, p_hour integer, p_hours integer, p_guests integer, p_tickets integer,
  p_name text, p_phone text, p_note text, p_minute integer, p_offer_amount numeric
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
  total := coalesce(p_offer_amount,reserveflow_private.booking_category_amount(selected.template,selected.price,
    selected.service_fee,selected.hour_promotions,quantity));
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

-- Preserve the original signature for integrations that do not select an offer.
create or replace function public.submit_customer_booking(
  p_request_id uuid,p_shop_slug text,p_category_code text,p_resource_code text,
  p_date date,p_hour integer,p_hours integer,p_guests integer,p_tickets integer,
  p_name text,p_phone text,p_note text,p_minute integer default 0
)
returns jsonb language sql security definer set search_path='' as $$
  select reserveflow_private.rf_submit_customer_booking(p_request_id,p_shop_slug,p_category_code,p_resource_code,
    p_date,p_hour,p_hours,p_guests,p_tickets,p_name,p_phone,p_note,p_minute,null);
$$;

create or replace function public.quote_customer_payment(p_request jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  quote jsonb;
  qr text;
  bank_account jsonb;
  request_id uuid;
  requested_shop text;
  normalized_phone text;
  fingerprint bytea;
  terms jsonb;
begin
  terms := reserveflow_private.rf_promotion_terms(p_request,true);
  begin
    quote := reserveflow_private.booking_from_payment_request(p_request);
    qr := public.booking_promptpay_qr((quote->>'id')::uuid,p_request->>'p_phone');
    bank_account := reserveflow_private.booking_bank_account((quote->>'id')::uuid);
    if qr is null and bank_account is null then
      raise exception using errcode='22023', message='BOOKING_PAYMENT_UNAVAILABLE';
    end if;
    -- Reuse booking validation and pricing, then roll back the row and its outbox events.
    raise sqlstate 'RF026';
  exception when sqlstate 'RF026' then
    null;
  end;
  request_id := (quote->>'id')::uuid;
  requested_shop := p_request->>'p_shop_slug';
  normalized_phone := regexp_replace(p_request->>'p_phone','[[:space:]-]','','g');
  fingerprint := sha256(convert_to(p_request::text,'UTF8'));
  perform pg_advisory_xact_lock(hashtextextended('payment-quote:'||requested_shop||':'||normalized_phone,0));
  if not exists(select 1 from reserveflow_private.booking_payment_quotes q where q.booking_id=request_id) then
    if (select count(*) from reserveflow_private.booking_payment_quotes q
      where q.shop_slug=requested_shop and q.phone=normalized_phone and q.quoted_at>now()-interval '1 hour')>=15
    then raise exception using errcode='22023',message='BOOKING_RATE_LIMIT'; end if;
    insert into reserveflow_private.booking_payment_quotes(booking_id,shop_slug,phone,request_hash)
    values(request_id,requested_shop,normalized_phone,fingerprint);
  end if;
  if not exists(select 1 from reserveflow_private.booking_payment_quotes q
    where q.booking_id=request_id and q.request_hash=fingerprint and q.quoted_at>now()-interval '24 hours')
  then raise exception using errcode='22023',message='BOOKING_QUOTE_MISMATCH'; end if;
  delete from reserveflow_private.booking_payment_quotes where booking_id in (
    select q.booking_id from reserveflow_private.booking_payment_quotes q where q.quoted_at<now()-interval '30 days'
    order by q.quoted_at limit 25 for update skip locked
  );
  return quote || jsonb_build_object('qr',qr,'bank_account',bank_account,'promotion',terms);
end;
$$;

create or replace function reserveflow_private.booking_from_payment_request(p_request jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare
  terms jsonb;
  saved jsonb;
begin
  terms := reserveflow_private.rf_promotion_terms(p_request,false);
  saved := reserveflow_private.rf_submit_customer_booking(
    (p_request->>'p_request_id')::uuid,p_request->>'p_shop_slug',
    p_request->>'p_category_code',p_request->>'p_resource_code',
    (p_request->>'p_date')::date,(p_request->>'p_hour')::integer,(p_request->>'p_hours')::integer,
    (p_request->>'p_guests')::integer,(p_request->>'p_tickets')::integer,
    p_request->>'p_name',p_request->>'p_phone',p_request->>'p_note',(p_request->>'p_minute')::integer,
    (terms->>'amount')::numeric);
  if terms is not null then
    update reserveflow_private.rf_promotion_selections set booking_id=(saved->>'id')::uuid
      where request_id=(p_request->>'p_request_id')::uuid and booking_id is null;
    return saved || jsonb_build_object('promotion',terms);
  end if;
  return saved;
end;
$$;

-- Compatibility with the offer editor, now with explicit schedule and quota controls.
drop function public.rf_save_promotion_offer(uuid,uuid,text,integer,text,numeric,text,numeric,boolean);
create function public.rf_save_promotion_offer(
  p_shop_id uuid,p_id uuid,p_name text,p_hours integer,p_mode text,p_price numeric,
  p_gift_name text,p_gift_value numeric,p_active boolean,p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,p_usage_limit integer default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid; gift text := nullif(btrim(p_gift_name),'');
begin
  if not exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=auth.uid()
    and role in ('owner','admin')) then raise insufficient_privilege; end if;
  if p_hours is null or p_hours not between 1 and 5 or p_mode not in ('gift','discount')
    or (p_mode='gift' and gift is null)
    or (p_mode='discount' and (gift is not null or coalesce(p_gift_value,0)<>0))
    then raise invalid_parameter_value; end if;
  if p_id is null then
    insert into public.rf_promotion_offers(shop_id,name,hours,mode,price,gift_name,gift_value,active,starts_at,ends_at,usage_limit)
      values(p_shop_id,btrim(p_name),p_hours,p_mode,p_price,gift,coalesce(p_gift_value,0),p_active,p_starts_at,p_ends_at,p_usage_limit)
      returning id into result;
  else
    update public.rf_promotion_offers set name=btrim(p_name),hours=p_hours,mode=p_mode,price=p_price,
      gift_name=gift,gift_value=coalesce(p_gift_value,0),active=p_active,starts_at=p_starts_at,ends_at=p_ends_at,usage_limit=p_usage_limit
      where id=p_id and shop_id=p_shop_id returning id into result;
    if not found then raise exception 'PROMOTION_NOT_FOUND'; end if;
  end if;
  return result;
end;
$$;

revoke all on function reserveflow_private.rf_promotion_terms(jsonb,boolean),
  reserveflow_private.rf_submit_customer_booking(uuid,text,text,text,date,integer,integer,integer,integer,text,text,text,integer,numeric),
  public.rf_booking_offers(text,text,integer),public.rf_release_promotion_quote(jsonb),
  public.rf_save_promotion_offer(uuid,uuid,text,integer,text,numeric,text,numeric,boolean,timestamptz,timestamptz,integer)
  from public,anon,authenticated;
grant execute on function public.rf_booking_offers(text,text,integer),public.rf_release_promotion_quote(jsonb) to anon,authenticated;
grant execute on function public.rf_save_promotion_offer(uuid,uuid,text,integer,text,numeric,text,numeric,boolean,timestamptz,timestamptz,integer) to authenticated;

commit;
