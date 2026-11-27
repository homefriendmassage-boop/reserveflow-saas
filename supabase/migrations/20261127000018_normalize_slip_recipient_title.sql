begin;

-- Compare the full name without formatting or conventional personal titles.
create or replace function reserveflow_private.booking_receiver_name_key(p_name text)
returns text language sql immutable strict set search_path='' as $$
  select nullif(regexp_replace(
    regexp_replace(
      regexp_replace(lower(normalize(btrim(p_name), NFC)), '^(นางสาว|นาง|นาย|น\.ส\.)[[:space:]]*', ''),
      '^(mr|mrs|ms|miss)([.][[:space:]]*|[[:space:]]+)', ''),
    '[[:space:]]','','g'), '');
$$;

revoke all on function reserveflow_private.booking_receiver_name_key(text) from public,anon,authenticated;

create or replace function public.finish_booking_slip_checked(
  p_booking_id uuid,p_outcome text,p_reference text,p_amount numeric,p_account text,
  p_receiver_names text[],p_paid_at timestamptz
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  slip public.booking_slip_attachments%rowtype;
  booking public.bookings%rowtype;
  expected reserveflow_private.shop_bank_accounts%rowtype;
  outcome text := p_outcome;
  reason text;
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
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount,'reason',slip.receiver_review_reason);
  end if;

  if p_outcome='provider_verified' then
    select * into expected from reserveflow_private.shop_bank_accounts
    where shop_id=booking.shop_id for share;
    reason := case
      when expected.shop_id is null then 'bank_account_missing'
      when p_account is null then 'receiver_account_unavailable'
      when p_account <> expected.account_number then 'receiver_account_mismatch'
      when not exists(select 1 from unnest(p_receiver_names) as names(value)
        where nullif(btrim(value),'') is not null) then 'receiver_name_unavailable'
      when not exists(select 1 from unnest(p_receiver_names) as names(value)
        where reserveflow_private.booking_receiver_name_key(value)
          = reserveflow_private.booking_receiver_name_key(expected.holder_name)) then 'receiver_name_mismatch'
      when p_paid_at is null then 'payment_time_unavailable'
      when p_paid_at < coalesce((select q.quoted_at from reserveflow_private.booking_payment_quotes q
        where q.booking_id=booking.id),booking.created_at) then 'payment_before_quote'
      when p_paid_at > now()+interval '2 minutes' then 'payment_time_future'
    end;
    if p_amount is null or p_amount<=0 or p_amount>9999999999.99 or p_amount<>round(p_amount,2)
      or p_reference is null or length(p_reference) not between 1 and 200 then
      outcome := 'retry';
      reason := null;
    elsif reason is not null then
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
  set verification_state=outcome,receiver_verified=matched,receiver_review_reason=reason,
    verified_paid_at=case when outcome='confirmed' then p_paid_at end,
    verified_amount=case when outcome in ('confirmed','amount_review','receiver_review','booking_review','duplicate_review')
      then p_amount else null end
  where booking_id=p_booking_id returning * into slip;
  return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount,'reason',slip.receiver_review_reason);
end;
$$;

create or replace function public.finish_booking_slip_checked(
  p_booking_id uuid,p_outcome text,p_reference text,p_amount numeric,p_account text,
  p_receiver_names text[],p_paid_at timestamptz,p_promptpay text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  slip public.booking_slip_attachments%rowtype;
  booking public.bookings%rowtype;
  expected reserveflow_private.shop_bank_accounts%rowtype;
  outcome text := p_outcome;
  reason text;
  expected_promptpay text;
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
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount,'reason',slip.receiver_review_reason);
  end if;

  if p_outcome='provider_verified' then
    select * into expected from reserveflow_private.shop_bank_accounts
    where shop_id=booking.shop_id for share;
    select mobile into expected_promptpay from public.shop_promptpay where shop_id=booking.shop_id for share;
    reason := case
      when expected.shop_id is null then 'bank_account_missing'
      when p_account is null and p_promptpay is null then 'receiver_account_unavailable'
      when p_account is not null and p_account <> expected.account_number then 'receiver_account_mismatch'
      when p_account is null and p_promptpay is distinct from expected_promptpay then 'receiver_account_mismatch'
      when not exists(select 1 from unnest(p_receiver_names) as names(value)
        where nullif(btrim(value),'') is not null) then 'receiver_name_unavailable'
      when not exists(select 1 from unnest(p_receiver_names) as names(value)
        where reserveflow_private.booking_receiver_name_key(value)
          = reserveflow_private.booking_receiver_name_key(expected.holder_name)) then 'receiver_name_mismatch'
      when p_paid_at is null then 'payment_time_unavailable'
      when p_paid_at < coalesce((select q.quoted_at from reserveflow_private.booking_payment_quotes q
        where q.booking_id=booking.id),booking.created_at) then 'payment_before_quote'
      when p_paid_at > now()+interval '2 minutes' then 'payment_time_future'
    end;
    if p_amount is null or p_amount<=0 or p_amount>9999999999.99 or p_amount<>round(p_amount,2)
      or p_reference is null or length(p_reference) not between 1 and 200 then
      outcome := 'retry';
      reason := null;
    elsif reason is not null then
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
  set verification_state=outcome,receiver_verified=matched,receiver_review_reason=reason,
    verified_paid_at=case when outcome='confirmed' then p_paid_at end,
    verified_amount=case when outcome in ('confirmed','amount_review','receiver_review','booking_review','duplicate_review')
      then p_amount else null end
  where booking_id=p_booking_id returning * into slip;
  return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount,'reason',slip.receiver_review_reason);
end;
$$;

notify pgrst,'reload schema';
commit;
