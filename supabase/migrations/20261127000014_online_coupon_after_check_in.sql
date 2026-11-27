begin;

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
  if not found or booking.booking_channel is distinct from 'online' or selection.terms->>'mode'<>'gift' or booking.status not in ('checked_in','completed')
    or not reserveflow_private.rf_promotion_checked_in(booking.id)
    or cutoff<=now()
    or not exists(select 1 from public.booking_slip_attachments a where a.booking_id=p_booking_id
      and a.thunder_reference is not null and (
        (a.verification_state='confirmed' and a.verified_amount=booking.amount and a.verified_paid_at is not null)
        or (a.verification_state='amount_review' and a.receiver_verified
          and a.verified_amount>0 and a.verified_amount<>booking.amount)
      )) then return null; end if;

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

-- Catch up still-valid, checked-in online bookings under the new payment rule.
-- Voucher and notification uniqueness make repeated synchronization safe.
do $$
declare booking_id uuid;
begin
  for booking_id in
    select b.id from public.bookings b
    join public.shops s on s.id=b.shop_id
    join reserveflow_private.rf_promotion_check_ins c on c.booking_id=b.id
    join reserveflow_private.rf_promotion_selections p on p.booking_id=b.id
    where b.booking_channel='online' and p.terms->>'mode'='gift'
      and b.status in ('checked_in','completed')
      and ((reserveflow_private.rf_coupon_day_start(b.starts_at,s.timezone)+interval '1 day')
        at time zone s.timezone)>now()
    order by b.id
  loop
    perform reserveflow_private.rf_sync_promotion_voucher(booking_id);
  end loop;
end;
$$;

notify pgrst,'reload schema';
commit;
