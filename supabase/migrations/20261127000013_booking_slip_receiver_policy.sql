begin;

alter table public.booking_slip_attachments
  add column receiver_verified boolean not null default false;

-- Earlier amount-review decisions did not always check the recipient first.
update public.booking_slip_attachments
set verification_state='retry',verification_started_at=null
where verification_state in ('amount_review','receiver_review');

create function reserveflow_private.require_booking_slip_amount_review(p_booking_id uuid)
returns void language plpgsql set search_path='' as $$
begin
  if not exists(select 1 from public.booking_slip_attachments a where a.booking_id=p_booking_id
    and a.verification_state='amount_review' and a.receiver_verified and a.thunder_reference is not null)
    then raise exception using errcode='22023',message='BOOKING_SLIP_APPROVAL_NOT_ALLOWED'; end if;
end;
$$;

revoke all on function reserveflow_private.require_booking_slip_amount_review(uuid) from public,anon,authenticated;

create function public.finish_booking_slip_checked(
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

revoke all on function public.finish_booking_slip_checked(uuid,text,text,numeric,text,text[],timestamptz)
  from public,anon,authenticated;
grant execute on function public.finish_booking_slip_checked(uuid,text,text,numeric,text,text[],timestamptz) to service_role;

-- Older verifier deployments cannot confirm a booking without recipient evidence.
create or replace function public.finish_thunder_booking_slip(
  p_booking_id uuid,p_outcome text,p_reference text,p_amount numeric,p_mobile text,p_paid_at timestamptz
) returns jsonb language sql security definer set search_path='' as $$
  select public.finish_booking_slip_checked(p_booking_id,
    case when p_outcome='provider_verified' then 'retry' else p_outcome end,
    p_reference,p_amount,null,null,p_paid_at);
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
  if slip.verification_started_at > now()-interval '1 minute' then
    return jsonb_build_object('state','checking');
  end if;
  update public.booking_slip_attachments set verification_started_at=now() where booking_id=p_booking_id;
  return jsonb_build_object('state','claimed','image',slip.image);
end;
$$;

create or replace function public.change_merchant_table_booking_status(
  p_shop_id uuid, p_booking_id uuid, p_status text
)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  booking record;
  role_name text;
begin
  select role into role_name from public.shop_members where shop_id=p_shop_id and user_id=(select auth.uid());
  if role_name is null then raise insufficient_privilege; end if;

  select b.status, b.starts_at,c.template into booking
  from public.bookings b join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
  where b.id = p_booking_id and b.shop_id = p_shop_id
  for update of b;
  if not found or p_status is null or p_status not in ('cancelled', 'completed', 'confirmed') then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_STATUS';
  end if;
  if role_name='staff' and (p_status<>'completed' or booking.template not in ('table','seat') or booking.status not in ('checked_in','completed')) then
    raise exception using errcode='42501',message='MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if booking.status = p_status then return; end if;
  if not (
    (p_status = 'cancelled' and booking.status not in ('cancelled', 'completed'))
    or (p_status = 'completed' and booking.status in ('confirmed', 'checked_in') and booking.starts_at <= statement_timestamp())
    or (p_status = 'confirmed' and booking.status = 'pending_confirm' and booking.starts_at > statement_timestamp())
  ) then
    raise exception using errcode = '22023', message = 'INVALID_BOOKING_STATUS';
  end if;

  if p_status='confirmed' then perform reserveflow_private.require_booking_slip_amount_review(p_booking_id); end if;
  update public.bookings set status = p_status where id = p_booking_id and shop_id = p_shop_id;
end;
$$;

create or replace function public.confirm_counter_booking_payment(p_shop_id uuid,p_booking_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare reservation record;
begin
  if not exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=auth.uid()
    and role in ('owner','admin','cashier')) then raise insufficient_privilege; end if;
  select b.status,b.starts_at,b.ends_at,c.walk_in into reservation
  from public.bookings b join reserveflow_private.counter_booking_payments c on c.booking_id=b.id
  where b.id=p_booking_id and b.shop_id=p_shop_id for update of b;
  if not found then raise invalid_parameter_value; end if;
  if reservation.status in ('confirmed','checked_in') then return; end if;
  if reservation.status<>'slip_review' or reservation.ends_at<=now()
    or not exists(select 1 from public.booking_slip_attachments where booking_id=p_booking_id) then
    raise exception using errcode='22023',message='SLIP_BOOKING_UNAVAILABLE';
  end if;
  perform reserveflow_private.require_booking_slip_amount_review(p_booking_id);
  update public.bookings set status='confirmed' where id=p_booking_id;
  if reservation.walk_in then
    update public.bookings set status='checked_in' where id=p_booking_id;
  end if;
end;
$$;

notify pgrst,'reload schema';
commit;
