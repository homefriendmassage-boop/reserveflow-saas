begin;

alter table public.shop_promptpay drop constraint if exists shop_promptpay_mobile_check;
alter table public.shop_promptpay add constraint shop_promptpay_proxy_check
  check (mobile ~ '^0[689][0-9]{8}$' or mobile ~ '^[0-9]{13}$');

create function public.booking_promptpay_qr(p_booking_id uuid,p_phone text)
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
    and b.created_at>now()-interval '24 hours' and b.starts_at>now()
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
revoke all on function public.booking_promptpay_qr(uuid,text) from public,anon,authenticated;
grant execute on function public.booking_promptpay_qr(uuid,text) to anon,authenticated;

create or replace function public.save_shop_promptpay(p_shop_id uuid,p_mobile text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  mobile text := regexp_replace(coalesce(p_mobile,''),'[[:space:]-]','','g');
begin
  if not exists (select 1 from public.shop_members where shop_id=p_shop_id
    and user_id=(select auth.uid()) and role='owner') then
    raise exception using errcode='42501',message='MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if mobile = '' then
    delete from public.shop_promptpay where shop_id=p_shop_id;
    return;
  end if;
  if mobile !~ '^0[689][0-9]{8}$' and mobile !~ '^[0-9]{13}$' then
    raise exception using errcode='22023',message='INVALID_PROMPTPAY_PROXY';
  end if;
  insert into public.shop_promptpay as p(shop_id,mobile) values(p_shop_id,mobile)
  on conflict(shop_id) do update set mobile=excluded.mobile;
end;
$$;

create or replace function public.booking_catalog(p_shop_slug text)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'name', s.name,
    'timezone', s.timezone,
    'slip_attachments_enabled', true,
    'promptpay_enabled', exists(select 1 from public.shop_promptpay p where p.shop_id=s.id),
    'promptpay_mobile', (select p.mobile from public.shop_promptpay p where p.shop_id=s.id and length(p.mobile)=10),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', c.code, 'name', c.name, 'template', c.template,
        'price', c.price, 'service_fee', c.service_fee,
        'resources', coalesce((
          select jsonb_agg(jsonb_build_object(
            'code', r.code, 'name', r.name, 'description', r.description, 'capacity', r.capacity, 'position', r.display->>'position', 'photo', r.display->>'photo'
          ) order by r.code)
          from public.resources r
          where (r.shop_id, r.category_code) = (c.shop_id, c.code) and not (r.display @> '{"archived":true}')
        ), '[]'::jsonb)
      ) order by c.sort_order, c.code)
      from public.categories c
      where c.shop_id = s.id and c.visible
    ), '[]'::jsonb)
  )
  from public.shops s
  where s.slug = p_shop_slug and s.public_booking_enabled and reserveflow_private.shop_booking_active(s.id);
$$;

commit;
