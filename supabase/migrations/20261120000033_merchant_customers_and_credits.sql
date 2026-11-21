begin;

update reserveflow_private.platform_billing
set prices='{"monthly":299,"quarterly":849,"half_year":1590,"yearly":2990}'::jsonb || prices;

create table if not exists reserveflow_private.slip_credit_packs (
  code text primary key,
  credits integer not null check(credits between 1 and 100000),
  amount numeric(12,2) not null check(amount>0)
);
insert into reserveflow_private.slip_credit_packs values ('standard',500,450),('volume',1000,800)
on conflict do nothing;

create or replace function reserveflow_private.available_slip_packs()
returns table(code text,credits integer,amount numeric)
language sql stable set search_path=''
as $$
  select 'starter',o.credits,o.amount from reserveflow_private.slip_credit_offer o
  union all select p.code,p.credits,p.amount from reserveflow_private.slip_credit_packs p;
$$;

create or replace function public.open_slip_credit_pack(p_shop_id uuid,p_code text)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
  insert into reserveflow_private.slip_credit_orders(shop_id,credits,amount,receiving_mobile)
  select p_shop_id,o.credits,o.amount,b.mobile
  from reserveflow_private.available_slip_packs() o cross join reserveflow_private.platform_billing b
  where o.code=p_code and b.mobile is not null
  on conflict(shop_id) where state='pending' do nothing;
end;
$$;

create or replace function public.save_slip_credit_pack(p_code text,p_credits integer,p_amount numeric)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if p_code='starter' then
    perform public.save_slip_credit_offer(p_credits,p_amount);
    return;
  end if;
  if p_credits is null or p_credits not between 1 and 100000 or p_amount is null
    or p_amount not between 0.01 and 9999999999.99 or p_amount<>round(p_amount,2) then raise invalid_parameter_value; end if;
  update reserveflow_private.slip_credit_packs set credits=p_credits,amount=p_amount where code=p_code;
  if not found then raise invalid_parameter_value; end if;
end;
$$;

alter table reserveflow_private.slip_credit_usage add column if not exists shop_id uuid references public.shops(id) on delete cascade;
alter table reserveflow_private.slip_credit_usage add column if not exists allowance_period date;
alter table reserveflow_private.slip_credit_usage add column if not exists credit_source text
  check(credit_source in ('included','topup'));
create index if not exists slip_allowance_period on reserveflow_private.slip_credit_usage(shop_id,allowance_period)
where credit_source='included';

create or replace function reserveflow_private.shop_slip_allowance(p_shop_id uuid)
returns table(period date, included_limit integer, remaining integer)
language sql stable set search_path=''
as $$
  with allowance as (
    select
      case when exists(select 1 from reserveflow_private.shop_subscriptions s
        where s.shop_id=p_shop_id and s.expires_at>now())
      and exists(select 1 from reserveflow_private.package_orders o
        where o.shop_id=p_shop_id and o.state='approved')
      then date_trunc('month',now() at time zone 'Asia/Bangkok')::date end as paid_month
  )
  select coalesce(a.paid_month,date '2000-01-01'),
    case when a.paid_month is null then 10 else 100 end,
    greatest(0,case when a.paid_month is null then 10 else 100 end -
      (select count(*)::integer from reserveflow_private.slip_credit_usage u
       where u.shop_id=p_shop_id and u.credit_source='included'
         and u.allowance_period=coalesce(a.paid_month,date '2000-01-01')))
  from allowance a;
$$;

create or replace function public.consume_booking_slip_credit(p_booking_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare shop uuid; allowance record;
begin
  select b.shop_id into shop from public.bookings b join public.booking_slip_attachments a on a.booking_id=b.id
  where b.id=p_booking_id and a.verification_started_at>now()-interval '1 minute'
    and a.verification_state in ('pending','retry') for update of a;
  if not found then return false; end if;
  if exists(select 1 from reserveflow_private.slip_credit_usage where booking_id=p_booking_id) then return true; end if;
  perform pg_advisory_xact_lock(hashtextextended('slip-credit:'||shop::text,0));
  select * into allowance from reserveflow_private.shop_slip_allowance(shop);
  if allowance.remaining>0 then
    insert into reserveflow_private.slip_credit_usage(booking_id,shop_id,allowance_period,credit_source)
    values(p_booking_id,shop,allowance.period,'included');
  else
    update reserveflow_private.slip_credit_balances set credits=credits-1 where shop_id=shop and credits>0;
    if not found then return false; end if;
    insert into reserveflow_private.slip_credit_usage(booking_id,shop_id,credit_source) values(p_booking_id,shop,'topup');
  end if;
  return true;
end;
$$;

create or replace function public.refund_booking_slip_credit(p_booking_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare usage_record record;
begin
  perform 1 from public.booking_slip_attachments
  where booking_id=p_booking_id and verification_state in ('pending','retry')
    and verification_started_at>now()-interval '1 minute' for update;
  if not found then return; end if;
  delete from reserveflow_private.slip_credit_usage where booking_id=p_booking_id and credit_source is not null
    returning shop_id,credit_source into usage_record;
  if found and usage_record.credit_source='topup' then
    update reserveflow_private.slip_credit_balances set credits=credits+1 where shop_id=usage_record.shop_id;
  end if;
end;
$$;

create or replace function public.find_merchant_booking_history(p_shop_id uuid,p_from date,p_to date,p_search text)
returns table(id uuid,category_code text,resource_code text,starts_at timestamptz,ends_at timestamptz,
  customer_name text,amount numeric,status text)
language plpgsql stable security definer set search_path=''
as $$
declare zone text; term text := lower(left(trim(coalesce(p_search,'')),100));
begin
  if not reserveflow_private.can_read_shop_reports(p_shop_id) then raise insufficient_privilege; end if;
  if p_from is null or p_to is null or not isfinite(p_from) or not isfinite(p_to)
    or p_to-p_from not between 0 and 92 then raise invalid_parameter_value; end if;
  select s.timezone into zone from public.shops s where s.id=p_shop_id;
  return query select b.id,b.category_code,b.resource_code,b.starts_at,b.ends_at,b.customer_name,b.amount,b.status
  from public.bookings b left join public.resources r on (r.shop_id,r.category_code,r.code)=(b.shop_id,b.category_code,b.resource_code)
  where b.shop_id=p_shop_id and b.starts_at>=(p_from+time '06:00') at time zone zone
    and b.starts_at<(p_to+1+time '06:00') at time zone zone
    and (term='' or strpos(lower(concat_ws(' ',b.id::text,b.customer_name,b.resource_code,r.name)),term)>0)
  order by b.starts_at desc,b.id limit 100;
end;
$$;

create table if not exists reserveflow_private.shop_line_customers (
  shop_id uuid not null references public.shops(id) on delete cascade,
  bot_id text not null,
  line_user text not null check(line_user ~ '^U[0-9a-f]{32}$'),
  display_name text,
  picture_url text,
  primary key(shop_id,bot_id,line_user)
);

create or replace function public.shop_customer_profile_token(p_shop_id uuid,p_bot text)
returns text language sql stable security definer set search_path=''
as $$
  select v.decrypted_secret::jsonb->>'token' from reserveflow_private.shop_line_channels c
  join vault.decrypted_secrets v on v.id=c.secret_id where c.shop_id=p_shop_id and c.bot_id=p_bot;
$$;

create or replace function public.save_shop_line_customer(p_shop_id uuid,p_bot text,p_user text,p_name text,p_picture text)
returns void language sql security definer set search_path=''
as $$
  insert into reserveflow_private.shop_line_customers(shop_id,bot_id,line_user,display_name,picture_url)
  select c.shop_id,c.bot_id,p_user,nullif(left(trim(p_name),100),''),
    case when length(p_picture)<=1024 and p_picture like 'https://%' then p_picture end
  from reserveflow_private.shop_line_channels c where c.shop_id=p_shop_id and c.bot_id=p_bot
    and p_user ~ '^U[0-9a-f]{32}$'
  on conflict(shop_id,bot_id,line_user) do update
  set display_name=coalesce(excluded.display_name,shop_line_customers.display_name),
      picture_url=coalesce(excluded.picture_url,shop_line_customers.picture_url);
$$;

create or replace function reserveflow_private.shop_line_customer_directory(p_shop_id uuid)
returns table(line_user text,display_name text,picture_url text)
language sql stable set search_path=''
as $$
  with current_bot as (
    select bot_id from reserveflow_private.shop_line_channels where shop_id=p_shop_id
  ), known as (
    select c.line_user,c.display_name,c.picture_url,0 as priority from reserveflow_private.shop_line_customers c
    join current_bot cb on cb.bot_id=c.bot_id where c.shop_id=p_shop_id
    union all
    select t.line_user,b.customer_name,null,1 from reserveflow_private.booking_passes t
    join current_bot cb on cb.bot_id=t.line_bot join public.bookings b on b.id=t.booking_id
    where b.shop_id=p_shop_id and t.line_user is not null
  )
  select distinct on(k.line_user) k.line_user,coalesce(k.display_name,'ลูกค้า LINE'),k.picture_url
  from known k order by k.line_user,(k.display_name is null),k.priority,k.display_name;
$$;

create or replace function public.search_shop_line_customers(p_shop_id uuid,p_search text)
returns table(line_user text,display_name text,picture_url text)
language plpgsql stable security definer set search_path=''
as $$
declare term text:=lower(left(trim(coalesce(p_search,'')),100));
begin
  if not reserveflow_private.can_read_shop_reports(p_shop_id) then raise insufficient_privilege; end if;
  return query select c.* from reserveflow_private.shop_line_customer_directory(p_shop_id) c
    where term<>'' and (strpos(lower(c.display_name),term)>0 or lower(c.line_user)=term)
    order by c.display_name limit 20;
end;
$$;

create or replace function public.create_merchant_booking_for_line(p_shop_id uuid,p_request jsonb,p_line_user text,p_actual boolean)
returns uuid language plpgsql security definer set search_path=''
as $$
declare r record; recipient record; booking uuid; bot text;
begin
  if not reserveflow_private.can_read_shop_reports(p_shop_id) then raise insufficient_privilege; end if;
  select * into recipient from reserveflow_private.shop_line_customer_directory(p_shop_id) c where c.line_user=p_line_user;
  if not found then raise exception using errcode='22023', message='LINE_CUSTOMER_UNAVAILABLE'; end if;
  select bot_id into bot from reserveflow_private.shop_line_channels where shop_id=p_shop_id for share;
  select * into r from jsonb_to_record(p_request) as input(p_request_id uuid,p_category_code text,p_resource_code text,
    p_date date,p_hour integer,p_minute integer,p_guests integer,p_hours integer,p_tickets integer,p_name text,p_phone text);
  r.p_name := coalesce(nullif(r.p_name,''),recipient.display_name);
  if p_actual then
    booking := public.create_merchant_actual_booking(p_shop_id,r.p_request_id,r.p_category_code,r.p_resource_code,
      r.p_date,r.p_hour,r.p_minute,r.p_guests,r.p_hours,r.p_tickets,r.p_name,r.p_phone);
  else
    booking := public.create_merchant_booking(p_shop_id,r.p_request_id,r.p_category_code,r.p_resource_code,
      r.p_date,r.p_hour,r.p_minute,r.p_guests,r.p_hours,r.p_tickets,r.p_name,r.p_phone);
  end if;
  insert into reserveflow_private.booking_passes(booking_id,line_user,line_bot) values(booking,p_line_user,bot)
  on conflict(booking_id) do nothing;
  if not exists(select 1 from reserveflow_private.booking_passes t
    where t.booking_id=booking and t.line_user=p_line_user and t.line_bot=bot) then
    raise exception using errcode='22023',message='LINE_CUSTOMER_UNAVAILABLE';
  end if;
  perform reserveflow_private.queue_customer_booking_pass(booking);
  return booking;
end;
$$;

create or replace function public.shop_slip_credit_overview(p_shop_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  if p_shop_id is null then
    if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  elsif not reserveflow_private.is_shop_owner(p_shop_id) then
    raise insufficient_privilege;
  end if;
  return jsonb_build_object(
    'offers',(select jsonb_agg(to_jsonb(o) order by o.credits) from reserveflow_private.available_slip_packs() o),
    'allowance',(select to_jsonb(a)-'period' from reserveflow_private.shop_slip_allowance(p_shop_id) a where p_shop_id is not null),
    'offer',(select to_jsonb(o)-'id' from reserveflow_private.slip_credit_offer o),
    'payments_enabled',(select mobile is not null from reserveflow_private.platform_billing),
    'balance',coalesce((select credits from reserveflow_private.slip_credit_balances where shop_id=p_shop_id),0),
    'orders',coalesce((select jsonb_agg(to_jsonb(o)-'slip'-'transfer_reference' order by o.created_at desc)
      from (select t.*,s.name,t.slip is not null as has_slip
        from reserveflow_private.slip_credit_orders t join public.shops s on s.id=t.shop_id
        where (p_shop_id is null and t.state='pending' and t.slip is not null) or t.shop_id=p_shop_id
        order by (t.state='pending') desc,t.created_at desc limit 100) o),'[]'::jsonb));
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
  where b.shop_id=p_shop_id and (role_name<>'staff' or c.template='table')
    and b.status not in ('completed','cancelled')
  order by b.starts_at,b.id;
end;
$$;

revoke all on function public.open_slip_credit_pack(uuid,text),public.save_slip_credit_pack(text,integer,numeric),
  public.find_merchant_booking_history(uuid,date,date,text),public.search_shop_line_customers(uuid,text),
  public.create_merchant_booking_for_line(uuid,jsonb,text,boolean),public.refund_booking_slip_credit(uuid),
  public.shop_customer_profile_token(uuid,text),public.save_shop_line_customer(uuid,text,text,text,text)
  from public,anon,authenticated;
grant execute on function public.open_slip_credit_pack(uuid,text),public.save_slip_credit_pack(text,integer,numeric),
  public.find_merchant_booking_history(uuid,date,date,text),public.search_shop_line_customers(uuid,text),
  public.create_merchant_booking_for_line(uuid,jsonb,text,boolean) to authenticated;
grant execute on function public.refund_booking_slip_credit(uuid),
  public.shop_customer_profile_token(uuid,text),public.save_shop_line_customer(uuid,text,text,text,text) to service_role;


create table if not exists reserveflow_private.booking_payment_quotes (
  booking_id uuid primary key,
  shop_slug text not null,
  phone text not null,
  request_hash bytea not null,
  quoted_at timestamptz not null default now()
);
create index if not exists booking_payment_quotes_by_phone
  on reserveflow_private.booking_payment_quotes(shop_slug,phone,quoted_at);
create index if not exists booking_payment_quotes_by_time
  on reserveflow_private.booking_payment_quotes(quoted_at);

create or replace function public.quote_customer_payment(p_request jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  quote jsonb;
  qr text;
  request_id uuid;
  requested_shop text;
  normalized_phone text;
  fingerprint bytea;
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
  return quote || jsonb_build_object('qr',qr);
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
  if exists(select 1 from reserveflow_private.booking_payment_quotes q where q.booking_id=(p_request->>'p_request_id')::uuid
    and (q.request_hash<>sha256(convert_to(p_request::text,'UTF8'))
      or (q.quoted_at<=now()-interval '24 hours'
        and not exists(select 1 from public.bookings b where b.id=q.booking_id))))
    then raise exception using errcode='22023',message='BOOKING_QUOTE_MISMATCH'; end if;
  booking := reserveflow_private.booking_from_payment_request(p_request);
  booking_id_value := (booking->>'id')::uuid;
  if (booking->>'amount')::numeric is distinct from p_amount then
    raise exception using errcode='22023', message='BOOKING_PRICE_CHANGED';
  end if;
  if exists (
    select 1 from public.booking_slip_attachments a
    where a.booking_id=booking_id_value and a.image=p_image
  ) then
    return reserveflow_private.issue_booking_pass(booking);
  end if;
  if public.booking_promptpay_qr(booking_id_value,p_request->>'p_phone') is null then
    raise exception using errcode='22023', message='BOOKING_PAYMENT_UNAVAILABLE';
  end if;
  perform public.attach_customer_booking_slip(booking_id_value,p_request->>'p_phone',p_image);
  return reserveflow_private.issue_booking_pass(booking);
end;
$$;

create or replace function public.finish_thunder_booking_slip(
  p_booking_id uuid,p_outcome text,p_reference text,p_amount numeric,p_mobile text,p_paid_at timestamptz
) returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  slip public.booking_slip_attachments%rowtype;
  booking public.bookings%rowtype;
  expected_mobile text;
  outcome text := p_outcome;
begin
  if p_outcome not in ('retry','qr_unreadable','not_verified','provider_verified') then
    raise exception using errcode='22023',message='INVALID_VERIFICATION_OUTCOME';
  end if;
  select * into slip from public.booking_slip_attachments where booking_id=p_booking_id for update;
  if not found then return null; end if;
  if slip.verification_state not in ('pending','retry') then
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
  end if;
  if p_outcome='provider_verified' then
    select * into booking from public.bookings where id=p_booking_id for update;
    select mobile into expected_mobile from public.shop_promptpay where shop_id=booking.shop_id for share;
    if p_amount is null or p_amount <= 0 or p_amount > 9999999999.99 or p_amount <> round(p_amount,2)
      or p_reference is null or length(p_reference) not between 1 and 200 then
      outcome := 'retry';
    elsif p_mobile is null or expected_mobile is null or p_mobile <> expected_mobile
      or p_paid_at is null or p_paid_at < coalesce((select q.quoted_at from reserveflow_private.booking_payment_quotes q
          where q.booking_id=booking.id),booking.created_at) or p_paid_at > now()+interval '2 minutes' then
      outcome := case when p_amount <> booking.amount then 'amount_review' else 'receiver_review' end;
    else
      begin
        perform pg_advisory_xact_lock(hashtextextended('payment-reference:'||p_reference,0));
        if exists (select 1 from reserveflow_private.package_orders where transfer_reference=p_reference) then
          raise unique_violation;
        end if;
        update public.booking_slip_attachments set thunder_reference=p_reference where booking_id=p_booking_id;
        if p_amount <> booking.amount then
          outcome := 'amount_review';
        elsif booking.status in ('pending_confirm','pending_payment','slip_review') and booking.starts_at > now() then
          update public.bookings set status='confirmed' where id=p_booking_id;
          outcome := 'confirmed';
        else
          outcome := 'booking_review';
        end if;
      exception when unique_violation then
        outcome := 'duplicate_review';
      end;
    end if;
  end if;
  update public.booking_slip_attachments
  set verification_state=outcome,
    verified_paid_at=case when outcome='confirmed' then p_paid_at end,
    verified_amount=case when outcome in ('confirmed','amount_review','receiver_review','booking_review','duplicate_review')
      then p_amount else null end
  where booking_id=p_booking_id returning * into slip;
  return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
end;
$$;

commit;
