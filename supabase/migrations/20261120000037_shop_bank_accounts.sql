begin;

create table if not exists reserveflow_private.shop_bank_accounts (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  bank_name text not null check(length(bank_name) between 1 and 100),
  holder_name text not null check(length(holder_name) between 1 and 120),
  account_number text not null check(account_number ~ '^[0-9]{6,20}$')
);

create or replace function reserveflow_private.booking_bank_account(p_booking_id uuid)
returns jsonb language sql stable set search_path=''
as $$
  select to_jsonb(a)-'shop_id' from reserveflow_private.shop_bank_accounts a
  join public.bookings b on b.shop_id=a.shop_id where b.id=p_booking_id and b.amount>0;
$$;

create or replace function public.get_shop_bank_account(p_shop_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
  return (select to_jsonb(a)-'shop_id' from reserveflow_private.shop_bank_accounts a where a.shop_id=p_shop_id);
end;
$$;

create or replace function public.save_shop_bank_account(p_shop_id uuid,p_bank text,p_holder text,p_number text)
returns void language plpgsql security definer set search_path=''
as $$
declare
  bank text := btrim(coalesce(p_bank,''));
  holder text := btrim(coalesce(p_holder,''));
  number_value text := regexp_replace(coalesce(p_number,''),'[[:space:]-]','','g');
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
  if bank='' and holder='' and number_value='' then
    delete from reserveflow_private.shop_bank_accounts where shop_id=p_shop_id;
    return;
  end if;
  if length(bank) not between 1 and 100 or length(holder) not between 1 and 120 or number_value !~ '^[0-9]{6,20}$' then
    raise exception using errcode='22023',message='INVALID_SHOP_BANK_ACCOUNT';
  end if;
  insert into reserveflow_private.shop_bank_accounts(shop_id,bank_name,holder_name,account_number)
  values(p_shop_id,bank,holder,number_value)
  on conflict(shop_id) do update set bank_name=excluded.bank_name,holder_name=excluded.holder_name,
    account_number=excluded.account_number;
end;
$$;

revoke all on function public.get_shop_bank_account(uuid),public.save_shop_bank_account(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.get_shop_bank_account(uuid),public.save_shop_bank_account(uuid,text,text,text) to authenticated;

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
begin
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
  return quote || jsonb_build_object('qr',qr,'bank_account',bank_account);
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
  if public.booking_promptpay_qr(booking_id_value,p_request->>'p_phone') is null
    and reserveflow_private.booking_bank_account(booking_id_value) is null then
    raise exception using errcode='22023', message='BOOKING_PAYMENT_UNAVAILABLE';
  end if;
  perform public.attach_customer_booking_slip(booking_id_value,p_request->>'p_phone',p_image);
  return reserveflow_private.issue_booking_pass(booking);
end;
$$;

create or replace function public.claim_thunder_booking_slip(p_booking_id uuid, p_phone text, p_staff uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  slip public.booking_slip_attachments%rowtype;
begin
  select a.* into slip from public.booking_slip_attachments a
  join public.bookings b on b.id=a.booking_id
  where a.booking_id=p_booking_id and (
    (p_staff is null and b.customer_phone=regexp_replace(p_phone,'[[:space:]-]','','g')
      and b.created_at > now()-interval '24 hours') or exists (
      select 1 from public.shop_members m where m.shop_id=b.shop_id and m.user_id=p_staff
        and m.role in ('owner','admin','cashier')))
  for update of a;
  if not found then return null; end if;
  if slip.verification_state not in ('pending','retry') then
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
  end if;
  if reserveflow_private.booking_bank_account(p_booking_id) is not null and not exists(
    select 1 from public.bookings b join public.shop_promptpay p on p.shop_id=b.shop_id where b.id=p_booking_id
  ) then return jsonb_build_object('state','manual_review'); end if;
  if slip.verification_started_at > now()-interval '1 minute' then
    return jsonb_build_object('state','checking');
  end if;
  update public.booking_slip_attachments set verification_started_at=now() where booking_id=p_booking_id;
  return jsonb_build_object('state','claimed','image',slip.image);
end;
$$;

notify pgrst,'reload schema';
commit;
