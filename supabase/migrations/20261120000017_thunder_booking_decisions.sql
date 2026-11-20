begin;
alter table public.booking_slip_attachments
  add column verification_state text not null default 'pending',
  add column verification_started_at timestamptz,
  add column verified_amount numeric(12,2),
  add column thunder_reference text unique;

create function public.claim_thunder_booking_slip(p_booking_id uuid, p_phone text, p_staff uuid)
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
  if slip.verification_started_at > now()-interval '1 minute' then
    return jsonb_build_object('state','checking');
  end if;
  update public.booking_slip_attachments set verification_started_at=now() where booking_id=p_booking_id;
  return jsonb_build_object('state','claimed','image',slip.image);
end;
$$;

create function public.finish_thunder_booking_slip(
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
      or p_paid_at is null or p_paid_at < booking.created_at or p_paid_at > now()+interval '2 minutes' then
      outcome := case when p_amount <> booking.amount then 'amount_review' else 'receiver_review' end;
    else
      begin
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
    verified_amount=case when outcome in ('confirmed','amount_review','receiver_review','booking_review','duplicate_review')
      then p_amount else null end
  where booking_id=p_booking_id returning * into slip;
  return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
end;
$$;

revoke all on function public.claim_thunder_booking_slip(uuid,text,uuid),
  public.finish_thunder_booking_slip(uuid,text,text,numeric,text,timestamptz) from public,anon,authenticated;
grant execute on function public.claim_thunder_booking_slip(uuid,text,uuid),
  public.finish_thunder_booking_slip(uuid,text,text,numeric,text,timestamptz) to service_role;

commit;
