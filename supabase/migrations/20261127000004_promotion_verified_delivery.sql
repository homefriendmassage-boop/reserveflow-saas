begin;

create function reserveflow_private.rf_sync_promotion_voucher(p_booking_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  booking public.bookings%rowtype;
  selection reserveflow_private.rf_promotion_selections%rowtype;
  binding reserveflow_private.rf_promotion_line_bindings%rowtype;
  voucher uuid;
begin
  select * into booking from public.bookings where id=p_booking_id for update;
  if not found then return null; end if;
  if booking.status='cancelled' or exists(select 1 from reserveflow_private.rf_promotion_refunds r where r.booking_id=p_booking_id) then
    update public.rf_promotion_vouchers set status='void' where booking_id=p_booking_id and status='issued';
    return null;
  end if;
  select * into selection from reserveflow_private.rf_promotion_selections where booking_id=p_booking_id;
  if not found or selection.terms->>'mode'<>'gift' or booking.status not in ('confirmed','checked_in','completed')
    or booking.ends_at+interval '1 day'<=now()
    or not exists(select 1 from public.booking_slip_attachments a where a.booking_id=p_booking_id
      and a.verification_state='confirmed' and a.verified_amount=booking.amount and a.verified_paid_at is not null
      and a.thunder_reference is not null) then return null; end if;

  select * into binding from reserveflow_private.rf_promotion_line_bindings where booking_id=p_booking_id;
  insert into public.rf_promotion_vouchers(shop_id,booking_id,offer_id,line_user_id,expires_at)
    values(booking.shop_id,p_booking_id,selection.offer_id,binding.line_user,booking.ends_at+interval '1 day')
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

-- Keep the existing service entry point, but derive the offer, owner and expiry from verified records.
create or replace function public.rf_issue_promotion_voucher(
  p_booking_id uuid,p_offer_id uuid,p_line_user_id text,p_expires_at timestamptz
) returns uuid language plpgsql security definer set search_path='' as $$
declare voucher uuid;
begin
  if not exists(select 1 from reserveflow_private.rf_promotion_selections where booking_id=p_booking_id and offer_id=p_offer_id)
    or (p_line_user_id is not null and not exists(select 1 from reserveflow_private.rf_promotion_line_bindings
      where booking_id=p_booking_id and line_user=p_line_user_id)) then raise exception 'PROMOTION_BOOKING_MISMATCH'; end if;
  voucher := reserveflow_private.rf_sync_promotion_voucher(p_booking_id);
  if voucher is null then raise exception 'PROMOTION_PAYMENT_NOT_VERIFIED'; end if;
  return voucher;
end;
$$;

create function reserveflow_private.rf_sync_promotion_on_booking()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform reserveflow_private.rf_sync_promotion_voucher(new.id);
  return null;
end;
$$;
create function reserveflow_private.rf_sync_promotion_on_payment()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform reserveflow_private.rf_sync_promotion_voucher(new.booking_id);
  return null;
end;
$$;
create trigger rf_sync_promo_booking after update of status on public.bookings for each row
when (old.status is distinct from new.status) execute function reserveflow_private.rf_sync_promotion_on_booking();
create trigger rf_sync_promo_slip after update of verification_state on public.booking_slip_attachments for each row
when (new.verification_state='confirmed') execute function reserveflow_private.rf_sync_promotion_on_payment();
create trigger rf_sync_promo_line after insert on reserveflow_private.rf_promotion_line_bindings for each row
execute function reserveflow_private.rf_sync_promotion_on_payment();

create function public.rf_record_booking_refund(p_booking_id uuid,p_reference text)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform 1 from public.bookings where id=p_booking_id for update;
  if not found then raise invalid_parameter_value; end if;
  insert into reserveflow_private.rf_promotion_refunds(booking_id,reference)
    values(p_booking_id,btrim(p_reference)) on conflict do nothing;
  perform reserveflow_private.rf_sync_promotion_voucher(p_booking_id);
end;
$$;

create or replace function public.rf_preview_promotion_voucher(p_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v record;
begin
  select voucher.status,voucher.expires_at,voucher.redeemed_at,s.terms into v
  from public.rf_promotion_vouchers voucher join reserveflow_private.rf_promotion_selections s on s.booking_id=voucher.booking_id
  join public.shop_members m on m.shop_id=voucher.shop_id and m.user_id=auth.uid()
  where voucher.token=p_token and m.role in ('owner','admin','cashier','staff');
  if not found then return jsonb_build_object('valid',false,'reason','NOT_FOUND'); end if;
  return jsonb_build_object('valid',v.status='issued' and v.expires_at>now(),
    'status',case when v.expires_at<=now() and v.status='issued' then 'expired' else v.status end,
    'offer',v.terms->>'name','gift',v.terms->>'gift','hours',v.terms->'hours',
    'expires_at',v.expires_at,'redeemed_at',v.redeemed_at);
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
  select id,booking_id,status,expires_at into v from public.rf_promotion_vouchers where token=p_token for update;
  if v.status<>'issued' or v.expires_at<=clock_timestamp() then
    return jsonb_build_object('ok',false,'reason',case when v.status='redeemed' then 'ALREADY_REDEEMED'
      when v.expires_at<=clock_timestamp() then 'EXPIRED' else 'NOT_ACTIVE' end);
  end if;
  update public.rf_promotion_vouchers set status='redeemed',redeemed_at=clock_timestamp(),redeemed_by=auth.uid() where id=v.id;
  insert into public.rf_promotion_events(voucher_id,kind)
    select v.id,'redeemed' where exists(select 1 from reserveflow_private.rf_promotion_line_bindings l where l.booking_id=v.booking_id)
    on conflict do nothing;
  return jsonb_build_object('ok',true,'status','redeemed');
end;
$$;

create function public.rf_booking_voucher(p_pass uuid)
returns uuid language sql stable security definer set search_path='' as $$
  select v.token from reserveflow_private.booking_passes p join public.rf_promotion_vouchers v on v.booking_id=p.booking_id
  join reserveflow_private.rf_promotion_selections s on s.booking_id=v.booking_id and s.offer_id=v.offer_id
  where p.view_token=p_pass and v.status='issued' and v.expires_at>now();
$$;
create function public.rf_promotion_qr_available(p_token uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.rf_promotion_vouchers v
    join reserveflow_private.rf_promotion_selections s on s.booking_id=v.booking_id and s.offer_id=v.offer_id
    where v.token=p_token and v.status='issued' and v.expires_at>now());
$$;

drop function public.rf_claim_promotion_events(integer);
create function public.rf_claim_promotion_events(p_limit integer default 5)
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
      and (e.kind='issued' and v.status='issued' and v.expires_at>now() or e.kind='redeemed' and v.status='redeemed')
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

create or replace function public.submit_verified_liff_booking(
  p_request jsonb,p_amount numeric,p_image text,p_liff_id text,p_line_user text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  config record;
  saved jsonb;
  booking uuid;
begin
  if not coalesce(p_line_user ~ '^U[0-9a-f]{32}$',false) then raise invalid_parameter_value; end if;
  select s.id,c.bot_id into config from public.shops s
  join reserveflow_private.shop_line_channels c on c.shop_id=s.id
  where s.slug=p_request->>'p_shop_slug' and s.public_booking_enabled and c.booking_liff_id=p_liff_id
  for share of c;
  if not found then raise exception using message='BOOKING_LINE_UNAVAILABLE'; end if;

  saved := public.submit_customer_payment(p_request,p_amount,p_image);
  booking := (saved->>'id')::uuid;
  if not exists(select 1 from public.bookings where id=booking and shop_id=config.id) then
    raise insufficient_privilege;
  end if;
  update reserveflow_private.booking_passes set line_user=p_line_user,line_bot=config.bot_id,line_queued_at=null
  where booking_id=booking and (line_user is null or line_bot is distinct from config.bot_id);
  if not exists(select 1 from reserveflow_private.booking_passes
    where booking_id=booking and line_user=p_line_user and line_bot=config.bot_id) then
    raise exception using message='BOOKING_LINE_ALREADY_LINKED';
  end if;
  insert into reserveflow_private.rf_promotion_line_bindings(booking_id,line_user,bot_id)
    select booking,p_line_user,config.bot_id where p_request->>'offer_id' is not null
    on conflict(booking_id) do update set line_user=excluded.line_user,bot_id=excluded.bot_id
    where rf_promotion_line_bindings.bot_id is distinct from excluded.bot_id;
  if p_request->>'offer_id' is not null then
    perform reserveflow_private.rf_sync_promotion_voucher(booking);
  end if;
  perform reserveflow_private.queue_customer_booking_pass(booking);
  return saved || jsonb_build_object('line_linked',true);
end;
$$;

revoke all on function reserveflow_private.rf_sync_promotion_voucher(uuid),
  reserveflow_private.rf_sync_promotion_on_booking(),reserveflow_private.rf_sync_promotion_on_payment(),
  public.rf_record_booking_refund(uuid,text),public.rf_booking_voucher(uuid),
  public.rf_promotion_qr_available(uuid),public.rf_claim_promotion_events(integer) from public,anon,authenticated;
grant execute on function public.rf_record_booking_refund(uuid,text),public.rf_promotion_qr_available(uuid),
  public.rf_claim_promotion_events(integer) to service_role;
grant execute on function public.rf_booking_voucher(uuid) to anon,authenticated;
notify pgrst,'reload schema';
commit;
