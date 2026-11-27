begin;

alter table public.rf_promotion_vouchers add column valid_from timestamptz;

create function reserveflow_private.rf_coupon_day_start(p_start timestamptz,p_timezone text)
returns timestamp language sql immutable set search_path='' as $$
  select (((p_start at time zone p_timezone) - interval '6 hours')::date + time '06:00');
$$;

update public.rf_promotion_vouchers v
set valid_from=reserveflow_private.rf_coupon_day_start(b.starts_at,s.timezone) at time zone s.timezone,
    expires_at=least(v.expires_at,(reserveflow_private.rf_coupon_day_start(b.starts_at,s.timezone)+interval '1 day') at time zone s.timezone)
from public.bookings b join public.shops s on s.id=b.shop_id
where v.booking_id=b.id and v.status='issued';

create or replace function reserveflow_private.rf_sync_promotion_voucher(p_booking_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  booking public.bookings%rowtype;
  selection reserveflow_private.rf_promotion_selections%rowtype;
  binding reserveflow_private.rf_promotion_line_bindings%rowtype;
  voucher uuid;
  tz text;
  day_start timestamp;
  cutoff timestamptz;
begin
  select * into booking from public.bookings where id=p_booking_id for update;
  if not found then return null; end if;
  if booking.status='cancelled' or exists(select 1 from reserveflow_private.rf_promotion_refunds r where r.booking_id=p_booking_id) then
    update public.rf_promotion_vouchers set status='void' where booking_id=p_booking_id and status='issued';
    return null;
  end if;
  select timezone into tz from public.shops where id=booking.shop_id;
  day_start:=reserveflow_private.rf_coupon_day_start(booking.starts_at,tz);
  cutoff:=(day_start+interval '1 day') at time zone tz;
  select * into selection from reserveflow_private.rf_promotion_selections where booking_id=p_booking_id;
  if not found or selection.terms->>'mode'<>'gift' or booking.status not in ('confirmed','checked_in','completed')
    or cutoff<=now()
    or not exists(select 1 from public.booking_slip_attachments a where a.booking_id=p_booking_id
      and a.verification_state='confirmed' and a.verified_amount=booking.amount and a.verified_paid_at is not null
      and a.thunder_reference is not null) then return null; end if;

  select * into binding from reserveflow_private.rf_promotion_line_bindings where booking_id=p_booking_id;
  insert into public.rf_promotion_vouchers(shop_id,booking_id,offer_id,line_user_id,valid_from,expires_at)
    values(booking.shop_id,p_booking_id,selection.offer_id,binding.line_user,day_start at time zone tz,cutoff)
  on conflict(booking_id,offer_id) do nothing;
  select id into voucher from public.rf_promotion_vouchers where booking_id=p_booking_id and offer_id=selection.offer_id;
  if binding.line_user is not null then
    update public.rf_promotion_vouchers set line_user_id=binding.line_user where id=voucher and line_user_id is null;
    insert into public.rf_promotion_events(voucher_id,kind)
      select v.id,'issued' from public.rf_promotion_vouchers v where v.id=voucher and v.status='issued'
      on conflict do nothing;
  end if;
  return voucher;
end;
$$;

create or replace function public.rf_preview_promotion_voucher(p_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v record;
begin
  select voucher.status,voucher.valid_from,voucher.expires_at,voucher.redeemed_at,s.terms into v
  from public.rf_promotion_vouchers voucher join reserveflow_private.rf_promotion_selections s on s.booking_id=voucher.booking_id
  join public.shop_members m on m.shop_id=voucher.shop_id and m.user_id=auth.uid()
  where voucher.token=p_token and m.role in ('owner','admin','cashier','staff');
  if not found then return jsonb_build_object('valid',false,'reason','NOT_FOUND'); end if;
  return jsonb_build_object('valid',v.status='issued' and v.expires_at>now() and (v.valid_from is null or v.valid_from<=now()),
    'status',case when v.expires_at<=now() and v.status='issued' then 'expired'
      when v.status='issued' and v.valid_from>now() then 'not_yet_valid' else v.status end,
    'offer',v.terms->>'name','gift',v.terms->>'gift','hours',v.terms->'hours',
    'valid_from',v.valid_from,'expires_at',v.expires_at,'redeemed_at',v.redeemed_at);
end;
$$;

create or replace function public.rf_redeem_promotion_voucher(p_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v record;
begin
  -- Match the booking-to-voucher lock order in cancellation and issuance.
  perform 1 from public.bookings b join public.rf_promotion_vouchers voucher on voucher.booking_id=b.id
  join public.shop_members m on m.shop_id=b.shop_id and m.user_id=auth.uid()
  where voucher.token=p_token and m.role in ('owner','admin','cashier','staff') for update of b;
  if not found then return jsonb_build_object('ok',false,'reason','NOT_FOUND'); end if;
  select id,booking_id,status,expires_at,valid_from into v from public.rf_promotion_vouchers where token=p_token for update;
  if v.status<>'issued' or v.expires_at<=clock_timestamp() or v.valid_from>clock_timestamp() then
    return jsonb_build_object('ok',false,'reason',case when v.status='redeemed' then 'ALREADY_REDEEMED'
      when v.expires_at<=clock_timestamp() then 'EXPIRED' when v.valid_from>clock_timestamp() then 'NOT_YET_VALID' else 'NOT_ACTIVE' end);
  end if;
  update public.rf_promotion_vouchers set status='redeemed',redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where id=v.id;
  insert into public.rf_promotion_events(voucher_id,kind)
    select v.id,'redeemed' where exists(select 1 from reserveflow_private.rf_promotion_line_bindings l where l.booking_id=v.booking_id)
    on conflict do nothing;
  return jsonb_build_object('ok',true,'status','redeemed');
end;
$$;

create or replace function public.rf_save_category_promotion_offer(
  p_shop_id uuid,p_category_code text,p_id uuid,p_name text,p_hours integer,p_mode text,p_price numeric,
  p_gift_name text,p_gift_value numeric,p_active boolean,p_starts_at timestamptz,p_ends_at timestamptz,p_usage_limit integer
)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  result uuid;
  hourly_rate numeric;
begin
  if not reserveflow_private.is_platform_admin() and not exists(
    select 1 from public.shop_members where shop_id=p_shop_id and user_id=auth.uid()
      and role in ('owner','admin')) then raise insufficient_privilege; end if;
  select price into hourly_rate from public.categories
    where shop_id=p_shop_id and code=p_category_code and template in ('seat','vip','staff');
  if not found then raise exception 'PROMOTION_CATEGORY_REQUIRED'; end if;
  if p_price is null or (p_mode='gift' and p_price<>hourly_rate*p_hours)
    or (p_mode='discount' and p_price>hourly_rate*p_hours) then
    raise exception 'PROMOTION_CATEGORY_PRICE_INVALID';
  end if;
  result:=public.rf_save_promotion_offer(p_shop_id,p_id,p_name,p_hours,p_mode,p_price,p_gift_name,
    p_gift_value,p_active,null,null,null);
  update public.rf_promotion_offers set category_code=p_category_code where id=result and shop_id=p_shop_id;
  return result;
end;
$$;

revoke all on function reserveflow_private.rf_coupon_day_start(timestamptz,text) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
