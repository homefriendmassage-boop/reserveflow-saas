begin;

create or replace function public.finish_booking_slip_checked(
  p_booking_id uuid,p_outcome text,p_reference text,p_amount numeric,p_account text,
  p_receiver_names text[],p_paid_at timestamptz
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  slip public.booking_slip_attachments%rowtype;
  booking public.bookings%rowtype;
  expected reserveflow_private.shop_bank_accounts%rowtype;
  outcome text := p_outcome;
  matched boolean := false;
  walk_in boolean := false;
begin
  if p_outcome not in ('retry','qr_unreadable','not_verified','provider_verified') then
    raise exception using errcode='22023',message='INVALID_VERIFICATION_OUTCOME';
  end if;
  select * into booking from public.bookings where id=p_booking_id for update;
  if not found then return null; end if;
  select * into slip from public.booking_slip_attachments where booking_id=p_booking_id for update;
  if not found then return null; end if;
  if slip.verification_state not in ('pending','retry') then
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
  end if;

  if p_outcome='provider_verified' then
    select * into expected from reserveflow_private.shop_bank_accounts
    where shop_id=booking.shop_id for share;
    if p_amount is null or p_amount<=0 or p_amount>9999999999.99 or p_amount<>round(p_amount,2)
      or p_reference is null or length(p_reference) not between 1 and 200 then
      outcome := 'retry';
    elsif expected.shop_id is null or p_account is distinct from expected.account_number
      or not exists(select 1 from unnest(p_receiver_names) as names(value)
        where regexp_replace(lower(value),'[[:space:]]','','g')
          = regexp_replace(lower(expected.holder_name),'[[:space:]]','','g'))
      or p_paid_at is null or p_paid_at<coalesce((select q.quoted_at from reserveflow_private.booking_payment_quotes q
        where q.booking_id=booking.id),booking.created_at) or p_paid_at>now()+interval '2 minutes' then
      outcome := 'receiver_review';
    else
      begin
        perform pg_advisory_xact_lock(hashtextextended('payment-reference:'||p_reference,0));
        if exists(select 1 from reserveflow_private.package_orders where transfer_reference=p_reference) then
          raise unique_violation;
        end if;
        update public.booking_slip_attachments set thunder_reference=p_reference where booking_id=p_booking_id;
        matched := true;
        select coalesce((select c.walk_in from reserveflow_private.counter_booking_payments c where c.booking_id=booking.id),false)
          into walk_in;
        if p_amount<>booking.amount then
          outcome := 'amount_review';
        elsif booking.status in ('pending_confirm','pending_payment','slip_review')
          and (booking.starts_at>now() or (walk_in and booking.ends_at>now())) then
          update public.bookings set status='confirmed' where id=p_booking_id;
          if walk_in then update public.bookings set status='checked_in' where id=p_booking_id; end if;
          outcome := 'confirmed';
        elsif booking.status in ('confirmed','checked_in','completed') then
          -- Confirm the payment evidence independently of the service status.
          outcome := 'confirmed';
        else
          outcome := 'booking_review';
        end if;
      exception when unique_violation then
        matched := false;
        outcome := 'duplicate_review';
      end;
    end if;
  end if;
  update public.booking_slip_attachments
  set verification_state=outcome,receiver_verified=matched,
    verified_paid_at=case when outcome='confirmed' then p_paid_at end,
    verified_amount=case when outcome in ('confirmed','amount_review','receiver_review','booking_review','duplicate_review')
      then p_amount else null end
  where booking_id=p_booking_id returning * into slip;
  return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
end;
$$;

-- Allow a fresh check for evidence previously held only by the booking-status rule.
update public.booking_slip_attachments a
set verification_state='retry', verification_started_at=null
from public.bookings b
where a.booking_id=b.id and b.status in ('confirmed','checked_in','completed')
  and a.verification_state='booking_review' and a.receiver_verified
  and a.verified_amount=b.amount and a.thunder_reference is not null;

notify pgrst,'reload schema';
commit;
