begin;

-- Keep an explicit check-in record so completing a booking directly cannot release a gift.
create table reserveflow_private.rf_promotion_check_ins (
  booking_id uuid primary key references public.bookings(id) on delete cascade
);

-- Bookings currently checked in have already met the new requirement.
insert into reserveflow_private.rf_promotion_check_ins(booking_id)
select b.id from public.bookings b join reserveflow_private.rf_promotion_selections s on s.booking_id=b.id
where b.status='checked_in' and s.terms->>'mode'='gift';

create function reserveflow_private.rf_promotion_checked_in(p_booking_id uuid)
returns boolean language sql stable set search_path='' as $$
  select exists(select 1 from reserveflow_private.rf_promotion_check_ins where booking_id=p_booking_id);
$$;

revoke all on function reserveflow_private.rf_promotion_checked_in(uuid) from public,anon,authenticated;

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
  if not found or selection.terms->>'mode'<>'gift' or booking.status not in ('checked_in','completed')
    or not reserveflow_private.rf_promotion_checked_in(booking.id)
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

create or replace function reserveflow_private.rf_sync_promotion_on_booking()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status='checked_in' and exists (
    select 1 from reserveflow_private.rf_promotion_selections
    where booking_id=new.id and terms->>'mode'='gift'
  ) then
    insert into reserveflow_private.rf_promotion_check_ins(booking_id)
    values(new.id) on conflict do nothing;
  end if;
  perform reserveflow_private.rf_sync_promotion_voucher(new.id);
  return null;
end;
$$;

create or replace function public.rf_issue_promotion_voucher(
  p_booking_id uuid,p_offer_id uuid,p_line_user_id text,p_expires_at timestamptz
) returns uuid language plpgsql security definer set search_path='' as $$
declare voucher uuid;
begin
  if not exists(select 1 from reserveflow_private.rf_promotion_selections where booking_id=p_booking_id and offer_id=p_offer_id)
    or (p_line_user_id is not null and not exists(select 1 from reserveflow_private.rf_promotion_line_bindings
      where booking_id=p_booking_id and line_user=p_line_user_id)) then raise exception 'PROMOTION_BOOKING_MISMATCH'; end if;
  if not reserveflow_private.rf_promotion_checked_in(p_booking_id) then raise exception 'PROMOTION_CHECK_IN_REQUIRED'; end if;
  voucher := reserveflow_private.rf_sync_promotion_voucher(p_booking_id);
  if voucher is null then raise exception 'PROMOTION_PAYMENT_NOT_VERIFIED'; end if;
  return voucher;
end;
$$;

create or replace function public.rf_booking_voucher(p_pass uuid)
returns uuid language sql stable security definer set search_path='' as $$
  select v.token from reserveflow_private.booking_passes p join public.rf_promotion_vouchers v on v.booking_id=p.booking_id
  join reserveflow_private.rf_promotion_selections s on s.booking_id=v.booking_id and s.offer_id=v.offer_id
  where p.view_token=p_pass and v.status='issued' and reserveflow_private.rf_promotion_checked_in(v.booking_id) and v.expires_at>now();
$$;

create or replace function public.rf_promotion_qr_available(p_token uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.rf_promotion_vouchers v
    join reserveflow_private.rf_promotion_selections s on s.booking_id=v.booking_id and s.offer_id=v.offer_id
    where v.token=p_token and v.status='issued' and reserveflow_private.rf_promotion_checked_in(v.booking_id) and v.expires_at>now());
$$;

create or replace function public.rf_preview_promotion_voucher(p_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v record;
begin
  select voucher.status,voucher.valid_from,voucher.expires_at,voucher.redeemed_at,voucher.booking_id,s.terms into v
  from public.rf_promotion_vouchers voucher join reserveflow_private.rf_promotion_selections s on s.booking_id=voucher.booking_id
  join public.shop_members m on m.shop_id=voucher.shop_id and m.user_id=auth.uid()
  where voucher.token=p_token and m.role in ('owner','admin','cashier','staff');
  if not found then return jsonb_build_object('valid',false,'reason','NOT_FOUND'); end if;
  return jsonb_build_object('valid',v.status='issued' and reserveflow_private.rf_promotion_checked_in(v.booking_id) and v.expires_at>now() and (v.valid_from is null or v.valid_from<=now()),
    'status',case when v.expires_at<=now() and v.status='issued' then 'expired'
      when v.status='issued' and not reserveflow_private.rf_promotion_checked_in(v.booking_id) then 'check_in_required'
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
  if v.status<>'issued' or v.expires_at<=clock_timestamp() or v.valid_from>clock_timestamp()
    or not reserveflow_private.rf_promotion_checked_in(v.booking_id) then
    return jsonb_build_object('ok',false,'reason',case when v.status='redeemed' then 'ALREADY_REDEEMED'
      when v.expires_at<=clock_timestamp() then 'EXPIRED'
      when v.status='issued' and not reserveflow_private.rf_promotion_checked_in(v.booking_id) then 'CHECK_IN_REQUIRED'
      when v.valid_from>clock_timestamp() then 'NOT_YET_VALID' else 'NOT_ACTIVE' end);
  end if;
  update public.rf_promotion_vouchers set status='redeemed',redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where id=v.id;
  insert into public.rf_promotion_events(voucher_id,kind)
    select v.id,'redeemed' where exists(select 1 from reserveflow_private.rf_promotion_line_bindings l where l.booking_id=v.booking_id)
    on conflict do nothing;
  return jsonb_build_object('ok',true,'status','redeemed');
end;
$$;

create or replace function public.rf_claim_promotion_events(p_limit integer default 5)
returns table(id uuid,lease_id uuid,kind text,token uuid,shop_name text,offer_name text,gift_name text,expires_at timestamptz,line_user_id text,access_token text)
language sql security definer set search_path='' as $$
  with due as (
    select e.id,s.name shop_name,h.terms,v.token,v.expires_at,l.line_user,
      (secret.decrypted_secret::jsonb)->>'token' access_token
    from public.rf_promotion_events e
    join public.rf_promotion_vouchers v on v.id=e.voucher_id
    join public.shops s on s.id=v.shop_id
    join reserveflow_private.rf_promotion_selections h on h.booking_id=v.booking_id and h.offer_id=v.offer_id
    join reserveflow_private.rf_promotion_line_bindings l on l.booking_id=v.booking_id and l.line_user=v.line_user_id
    join reserveflow_private.shop_line_channels c on c.shop_id=v.shop_id and c.bot_id=l.bot_id
    join vault.decrypted_secrets secret on secret.id=c.secret_id
    where e.attempts<5 and ((e.status in ('pending','failed') and e.next_attempt_at<=now())
      or (e.status='processing' and e.leased_until<now()))
      and (e.kind='issued' and reserveflow_private.rf_promotion_checked_in(v.booking_id) and v.status='issued' and v.expires_at>now() or e.kind='redeemed' and v.status='redeemed')
      and not exists(select 1 from reserveflow_private.rf_promotion_refunds r where r.booking_id=v.booking_id)
    order by e.created_at,e.id for update of e skip locked limit least(greatest(p_limit,1),5)
  ), claimed as (
    update public.rf_promotion_events e set status='processing',attempts=e.attempts+1,
      lease_id=gen_random_uuid(),leased_until=now()+interval '3 minutes'
    from due d where e.id=d.id
    returning e.id,e.lease_id,e.kind,d.token,d.shop_name,d.terms,d.expires_at,d.line_user,d.access_token
  )
  select c.id,c.lease_id,c.kind,c.token,c.shop_name,c.terms->>'name',c.terms->>'gift',c.expires_at,c.line_user,c.access_token
  from claimed c;
$$;

notify pgrst,'reload schema';
commit;
