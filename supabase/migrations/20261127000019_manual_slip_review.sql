begin;

alter table public.shops add column if not exists slip_manual_only boolean not null default false;
alter table public.booking_slip_attachments
  add column if not exists manual_reviewed_at timestamptz,
  add column if not exists manual_reviewed_by uuid,
  add column if not exists manual_amount numeric,
  add column if not exists manual_reference text;
create unique index if not exists booking_slip_manual_reference_unique
  on public.booking_slip_attachments(manual_reference) where manual_reference is not null;

create or replace function public.set_shop_slip_manual_only(p_shop_id uuid,p_enabled boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) and not reserveflow_private.is_platform_admin()
    then raise insufficient_privilege; end if;
  update public.shops set slip_manual_only=p_enabled where id=p_shop_id;
end;
$$;

revoke all on function public.set_shop_slip_manual_only(uuid,boolean) from public,anon,authenticated;
grant execute on function public.set_shop_slip_manual_only(uuid,boolean) to authenticated;

create or replace function reserveflow_private.guard_automatic_payment_reference()
returns trigger language plpgsql security definer set search_path='' as $$
declare ref text;
begin
  ref := case when tg_table_name='package_orders' then to_jsonb(new)->>'transfer_reference'
    else to_jsonb(new)->>'thunder_reference' end;
  if ref is null then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended('payment-reference:'||ref,0));
  if exists(select 1 from public.booking_slip_attachments a where a.manual_reference=ref)
    then raise unique_violation; end if;
  return new;
end;
$$;
revoke all on function reserveflow_private.guard_automatic_payment_reference() from public,anon,authenticated;

drop trigger if exists guard_manual_reference_for_booking on public.booking_slip_attachments;
create trigger guard_manual_reference_for_booking before update of thunder_reference on public.booking_slip_attachments
  for each row execute function reserveflow_private.guard_automatic_payment_reference();
drop trigger if exists guard_manual_reference_for_package on reserveflow_private.package_orders;
create trigger guard_manual_reference_for_package before insert or update of transfer_reference on reserveflow_private.package_orders
  for each row execute function reserveflow_private.guard_automatic_payment_reference();

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
  if slip.manual_reviewed_at is not null then return jsonb_build_object('state','manual_confirmed'); end if;
  if exists(select 1 from public.bookings b join public.shops s on s.id=b.shop_id
    where b.id=p_booking_id and s.slip_manual_only) then return jsonb_build_object('state','manual_review'); end if;
  if slip.verification_state not in ('pending','retry')
    and not (p_staff is not null and slip.verification_state='receiver_review') then
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount,'reason',slip.receiver_review_reason);
  end if;
  if slip.verification_started_at > now()-interval '1 minute' then
    return jsonb_build_object('state','checking');
  end if;
  update public.booking_slip_attachments set verification_started_at=now(),verification_state=case
    when slip.verification_state='receiver_review' then 'retry' else slip.verification_state end
  where booking_id=p_booking_id;
  return jsonb_build_object('state','claimed','image',slip.image);
end;
$$;

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
      and ((a.manual_reviewed_at is not null and a.manual_amount=booking.amount)
      or (a.thunder_reference is not null and (
        (a.verification_state='confirmed' and a.verified_amount=booking.amount and a.verified_paid_at is not null)
        or (a.verification_state='amount_review' and a.receiver_verified
          and a.verified_amount>0 and a.verified_amount<>booking.amount)
      )))) then return null; end if;

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

create or replace function public.confirm_merchant_slip_manually(
  p_shop_id uuid,p_booking_id uuid,p_amount numeric,p_reference text
) returns void language plpgsql security definer set search_path='' as $$
declare
  booking public.bookings%rowtype;
  slip public.booking_slip_attachments%rowtype;
  ref text := btrim(p_reference);
begin
  if not exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=auth.uid()
    and role in ('owner','admin','cashier')) then raise insufficient_privilege; end if;
  if not exists(select 1 from public.shops where id=p_shop_id and slip_manual_only for share)
    then raise exception 'MANUAL_SLIP_REVIEW_DISABLED'; end if;
  select * into booking from public.bookings where id=p_booking_id and shop_id=p_shop_id for update;
  if not found then raise exception 'SLIP_BOOKING_UNAVAILABLE'; end if;
  select * into slip from public.booking_slip_attachments where booking_id=p_booking_id for update;
  if not found or booking.status='cancelled' then raise exception 'SLIP_BOOKING_UNAVAILABLE'; end if;
  if slip.manual_reviewed_at is not null or slip.verification_state='confirmed' then return; end if;
  if booking.status not in ('pending_confirm','pending_payment','slip_review','confirmed','checked_in','completed')
    or (booking.status in ('pending_confirm','pending_payment','slip_review') and booking.ends_at<=now())
    then raise exception 'SLIP_BOOKING_UNAVAILABLE'; end if;
  if booking.amount<=0 or p_amount is distinct from booking.amount then raise exception 'BOOKING_PRICE_CHANGED'; end if;
  if ref is null or length(ref) not between 6 and 200 then raise exception 'INVALID_MANUAL_PAYMENT_REFERENCE'; end if;
  perform pg_advisory_xact_lock(hashtextextended('payment-reference:'||ref,0));
  if exists(select 1 from public.booking_slip_attachments a
      where a.booking_id<>p_booking_id and (a.manual_reference=ref or a.thunder_reference=ref))
    or exists(select 1 from reserveflow_private.package_orders where transfer_reference=ref)
    then raise exception 'MANUAL_PAYMENT_REFERENCE_USED'; end if;

  update public.booking_slip_attachments set manual_reviewed_at=now(),manual_reviewed_by=auth.uid(),
    manual_reference=ref,manual_amount=p_amount where booking_id=p_booking_id;
  if booking.status in ('pending_confirm','pending_payment','slip_review') then
    update public.bookings set status='confirmed' where id=p_booking_id;
    if exists(select 1 from reserveflow_private.counter_booking_payments c where c.booking_id=p_booking_id and c.walk_in)
      then update public.bookings set status='checked_in' where id=p_booking_id; end if;
  end if;
  perform reserveflow_private.rf_sync_promotion_voucher(p_booking_id);
end;
$$;

revoke all on function public.confirm_merchant_slip_manually(uuid,uuid,numeric,text) from public,anon,authenticated;
grant execute on function public.confirm_merchant_slip_manually(uuid,uuid,numeric,text) to authenticated;

notify pgrst,'reload schema';
commit;
