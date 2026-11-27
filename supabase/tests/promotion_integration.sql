-- Run only against a disposable database with all migrations installed.
begin;

insert into auth.users(id) values('85510000-0000-4000-8000-000000000001'),('85510000-0000-4000-8000-000000000002');
insert into public.shops(id,slug,name,public_booking_enabled) values
('85510000-0000-4000-8000-000000000003','promo-test-a','Promo test A',true),
('85510000-0000-4000-8000-000000000004','promo-test-b','Promo test B',true);
insert into public.shop_members(shop_id,user_id,role) values
('85510000-0000-4000-8000-000000000003','85510000-0000-4000-8000-000000000001','owner'),
('85510000-0000-4000-8000-000000000004','85510000-0000-4000-8000-000000000002','owner');

do $$
declare
  shop uuid := '85510000-0000-4000-8000-000000000003';
  shop_b uuid := '85510000-0000-4000-8000-000000000004';
  account uuid := '85510000-0000-4000-8000-000000000001';
  stranger uuid := '85510000-0000-4000-8000-000000000002';
  booking uuid := '85510000-0000-4000-8000-000000000005';
  second_booking uuid := '85510000-0000-4000-8000-000000000006';
  offer uuid;
  discount uuid;
  token uuid;
  second_token uuid;
  v_id uuid;
  pass uuid;
  request jsonb;
  quote jsonb;
  job record;
  merchant_booking uuid;
  scan uuid;
  image text := 'data:image/png;base64,iVBORw0KGgo=';
  expiry date := (now() at time zone 'Asia/Bangkok')::date + 1;
  client_liff text := '2012709644-AaBbCcDd';
begin
  insert into public.categories(shop_id,code,name,template,price,service_fee,hour_promotions)
    values (shop,'seat','Seat','seat',120,20,'{"3":300}'),(shop_b,'seat','Other','seat',120,20,'{}');
  insert into public.resources(shop_id,category_code,code,name) values
    (shop,'seat','S1','Seat 1'),(shop,'seat','S2','Seat 2'),(shop_b,'seat','S1','Other seat');
  insert into public.shop_promptpay(shop_id,mobile) values(shop,'0891234567'),(shop_b,'0891112222');
  insert into reserveflow_private.shop_bank_accounts(shop_id,bank_name,holder_name,account_number)
    values(shop,'Test bank','Test Recipient','1234567890');
  insert into reserveflow_private.shop_line_channels(shop_id,secret_id,bot_id,bot_name,booking_liff_id)
    values(shop,vault.create_secret('{"token":"fake-oa-a"}'),'U'||repeat('7',32),'OA A',client_liff),
      (shop_b,vault.create_secret('{"token":"fake-oa-b"}'),'U'||repeat('8',32),'OA B','2012709645-DdCcBbAa');
  set local role authenticated;
  perform set_config('request.jwt.claim.sub',account::text,true);
  offer:=public.rf_save_promotion_offer(shop,null,'Gift 3 hours',3,'gift',360,'One drink',40,true,null,null,1);
  discount:=public.rf_save_promotion_offer(shop,null,'Discount 3 hours',3,'discount',300,null,0,true);
  begin
    perform public.rf_save_promotion_offer(shop,null,'Stacked',3,'discount',300,'Gift',20,true);
    raise exception 'accepted stacked promotion';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub',stranger::text,true);
  begin
    perform public.rf_save_promotion_offer(shop,offer,'Cross tenant',3,'gift',360,'Gift',20,true);
    raise exception 'accepted cross-tenant edit';
  exception when insufficient_privilege then null; end;
  begin
    perform public.set_merchant_promotions_online_only(shop,true);
    raise exception 'accepted cross-tenant policy update';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',account::text,true);
  perform public.set_merchant_promotions_online_only(shop,true);
  merchant_booking:=public.create_merchant_booking(shop,gen_random_uuid(),'seat','S2',expiry,8,0,
    null,3,null,'Counter guest','0891234567');
  reset role;
  if (select amount from public.bookings where id=merchant_booking) is distinct from 380::numeric then
    raise exception 'online-only policy allowed a counter discount'; end if;
  if reserveflow_private.booking_pass_details(merchant_booking)->>'booking_channel' is distinct from 'staff'
    then raise exception 'staff booking not marked as staff'; end if;
  set local role anon;
  if jsonb_array_length(public.rf_booking_offers('promo-test-a','seat',3))<>2
    or jsonb_array_length(public.rf_booking_offers('promo-test-b','seat',3))<>0 then
    raise exception 'wrong public offer scope';
  end if;
  request:=jsonb_build_object('p_request_id',booking,'p_shop_slug','promo-test-a','p_category_code','seat',
    'p_resource_code','S1','p_date',expiry,'p_hour',12,'p_minute',0,'p_hours',3,'p_name','Customer',
    'p_phone','0891234567','offer_id',offer,'price',1);
  begin
    perform public.quote_customer_payment(request||jsonb_build_object('p_shop_slug','promo-test-b'));
    raise exception 'accepted foreign offer';
  exception when raise_exception then if sqlerrm<>'PROMOTION_UNAVAILABLE' then raise; end if; end;
  quote:=public.quote_customer_payment(request||jsonb_build_object('p_request_id',gen_random_uuid(),'offer_id',discount));
  if (quote->>'amount')::numeric<>320 then raise exception 'discount total does not match'; end if;
  quote:=public.quote_customer_payment(request||jsonb_build_object('p_request_id',gen_random_uuid(),'offer_id',discount,'p_hours',4));
  if (quote->>'amount')::numeric<>440 or (quote->'promotion'->>'extra_hours')::integer<>1
    then raise exception 'extended promotion total does not match'; end if;
  quote:=public.quote_customer_payment(request);
  if (quote->>'amount')::numeric<>380 or quote->>'qr' not like '%5406380.00%' then
    raise exception 'gift stacked a discount or wrong QR amount';
  end if;
  begin
    perform public.quote_customer_payment(request||jsonb_build_object('p_request_id',gen_random_uuid()));
    raise exception 'quota not reserved';
  exception when raise_exception then if sqlerrm<>'PROMOTION_SOLD_OUT' then raise; end if; end;
  begin
    perform public.submit_customer_payment(request,1,image);
    raise exception 'accepted forged total';
  exception when invalid_parameter_value then if sqlerrm<>'BOOKING_PRICE_CHANGED' then raise; end if; end;
  set local role service_role;
  perform set_config('request.jwt.claim.sub','',true);
  pass := (public.submit_verified_liff_booking(request,380,image,client_liff,'U'||repeat('1',32))->>'pass_token')::uuid;
  reset role;
  if public.rf_booking_voucher(pass) is not null then raise exception 'voucher issued for pending payment'; end if;
  perform reserveflow_private.queue_customer_booking_pass(booking);
  if (select count(*) from reserveflow_private.line_outbox q where q.customer_booking_id=booking
    and q.payload->>'notification_stage'='pending') <> 1 then
    raise exception 'pending Flex did not queue once';
  end if;
  update public.bookings set status='confirmed' where id=booking;
  if public.rf_booking_voucher(pass) is not null then raise exception 'status alone issued voucher'; end if;
  update public.bookings set status='pending_confirm' where id=booking;
  begin
    set local role service_role;
    if public.finish_booking_slip_checked(booking,'provider_verified','wrong-receiver',379,
      '9999999999',array['Wrong Name'],now())->>'reason' is distinct from 'receiver_account_mismatch'
      then raise exception 'wrong recipient was classified as an amount mismatch'; end if;
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',account::text,true);
    begin
      perform public.change_merchant_table_booking_status(shop,booking,'confirmed');
      raise exception 'staff confirmed a rejected receiver';
    exception when invalid_parameter_value then
      if sqlerrm<>'BOOKING_SLIP_APPROVAL_NOT_ALLOWED' then raise; end if;
    end;
    raise sqlstate 'RF913';
  exception when sqlstate 'RF913' then null;
  end;
  begin
    set local role service_role;
    if public.finish_booking_slip_checked(booking,'provider_verified','wrong-name',380,
      '1234567890',array['Wrong Name'],now())->>'reason' is distinct from 'receiver_name_mismatch'
      then raise exception 'account match bypassed the receiver name'; end if;
    if public.claim_thunder_booking_slip(booking,'0891234567',null)->>'state' is distinct from 'receiver_review'
      then raise exception 'customer could restart a rejected recipient check'; end if;
    if public.claim_thunder_booking_slip(booking,null,account)->>'state' is distinct from 'claimed'
      then raise exception 'authorized staff could not retry a rejected recipient check'; end if;
    raise sqlstate 'RF913';
  exception when sqlstate 'RF913' then null;
  end;
  begin
    set local role service_role;
    if public.finish_booking_slip_checked(booking,'provider_verified','amount-only',379,
      '1234567890',array['Test Recipient'],now())->>'state' is distinct from 'amount_review'
      then raise exception 'valid recipient amount mismatch not sent to staff'; end if;
    reset role;
    if (select status from public.bookings where id=booking)<>'pending_confirm'
      then raise exception 'amount mismatch was automatically approved'; end if;
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',account::text,true);
    perform public.change_merchant_table_booking_status(shop,booking,'confirmed');
    reset role;
    if (select status from public.bookings where id=booking)<>'confirmed'
      then raise exception 'staff could not approve an amount mismatch'; end if;
    if public.rf_booking_voucher(pass) is not null then raise exception 'approval issued coupon before check-in'; end if;
    select scan_token into scan from reserveflow_private.booking_passes where booking_id=booking;
    update public.bookings set starts_at=now()+interval '5 minutes',ends_at=now()+interval '3 hours 5 minutes'
      where id=booking;
    set local role authenticated;
    perform set_config('request.jwt.claim.sub',account::text,true);
    perform public.check_in_booking_pass(scan);
    reset role;
    if public.rf_booking_voucher(pass) is null then raise exception 'staff check-in did not release online coupon'; end if;
    if not exists(select 1 from public.rf_promotion_events where kind='issued')
      then raise exception 'online coupon was not queued after staff check-in'; end if;
    raise sqlstate 'RF913';
  exception when sqlstate 'RF913' then null;
  end;
  set local role service_role;
  if public.finish_booking_slip_checked(booking,'provider_verified','promo-fixture-verified',380,
    '1234567890',array['Test Recipient'],now())->>'state'<>'confirmed' then
    raise exception 'existing verifier did not confirm payment';
  end if;
  reset role;
  if public.booking_resource_next_start('promo-test-a','seat','S1',expiry,time '12:00',3)
    is distinct from '15:00' then raise exception 'next booking start did not respect existing slot'; end if;
  if (select count(*) from reserveflow_private.line_outbox q where q.customer_booking_id=booking
    and q.payload->>'notification_stage'='confirmed') <> 1 then
    raise exception 'confirmed Flex did not queue once';
  end if;
  if (select count(*) from reserveflow_private.line_outbox q where q.customer_booking_id=booking
    and q.payload @> jsonb_build_object('booking_channel','online','package_name','Gift 3 hours',
      'package_hours','3','package_gift','One drink')
    and q.payload->>'notification_stage' in ('pending','confirmed')) <> 2 then
    raise exception 'booking channel and package were not included in both Flex messages';
  end if;
  if public.rf_booking_voucher(pass) is not null or exists (
    select 1 from public.rf_promotion_vouchers where booking_id=booking
  ) then raise exception 'confirmed payment released a coupon before check-in'; end if;
  if exists(select 1 from public.rf_promotion_events) then
    raise exception 'coupon notification queued before check-in'; end if;
  update public.bookings set status='checked_in' where id=booking;
  token:=public.rf_booking_voucher(pass);
  if token is null or not public.rf_promotion_qr_available(token) then raise exception 'verified voucher missing'; end if;
  set local role service_role;
  v_id:=public.rf_issue_promotion_voucher(booking,offer,'U'||repeat('1',32),now()+interval '1 day');
  if v_id is distinct from public.rf_issue_promotion_voucher(booking,offer,null,now()) then raise exception 'issuance not idempotent'; end if;
  select * into job from public.rf_claim_promotion_events(1);
  if job.access_token is distinct from 'fake-oa-a' or job.line_user_id is distinct from 'U'||repeat('1',32)
    then raise exception 'LINE routed to wrong account'; end if;
  if not public.rf_finish_promotion_event(job.id,job.lease_id,false,'500') then raise exception 'failed job not tracked'; end if;
  reset role;
  update public.rf_promotion_events set next_attempt_at=now() where id=job.id;
  set local role service_role;
  select * into job from public.rf_claim_promotion_events(1);
  if not public.rf_finish_promotion_event(job.id,job.lease_id,true,null) then raise exception 'retry did not complete'; end if;
  set local role authenticated;
  perform set_config('request.jwt.claim.sub',stranger::text,true);
  if public.rf_preview_promotion_voucher(token)->>'valid'<>'false'
    or public.rf_redeem_promotion_voucher(token)->>'ok'<>'false' then raise exception 'cross-tenant voucher access'; end if;
  perform set_config('request.jwt.claim.sub',account::text,true);
  if public.rf_preview_promotion_voucher(token)->>'status' is distinct from 'not_yet_valid'
    or public.rf_redeem_promotion_voucher(token)->>'reason' is distinct from 'NOT_YET_VALID'
    then raise exception 'future coupon accepted'; end if;
  reset role;
  if not exists (
    select 1 from public.rf_promotion_vouchers v where v.booking_id=booking
      and v.valid_from=(expiry + time '06:00') at time zone 'Asia/Bangkok'
      and v.expires_at=(expiry + 1 + time '06:00') at time zone 'Asia/Bangkok'
  ) then raise exception 'incorrect coupon business day'; end if;
  update public.rf_promotion_vouchers v set valid_from=now()-interval '1 minute' where v.booking_id=booking;
  set local role authenticated;
  if public.rf_preview_promotion_voucher(token)->>'valid'<>'true'
    or public.rf_preview_promotion_voucher(token)->>'valid'<>'true' then raise exception 'preview consumed token'; end if;
  if public.rf_redeem_promotion_voucher(token)->>'ok'<>'true'
    or public.rf_redeem_promotion_voucher(token)->>'reason'<>'ALREADY_REDEEMED' then raise exception 'duplicate redemption'; end if;
  if public.rf_booking_voucher(pass) is not null then raise exception 'used QR still visible'; end if;
  reset role;

  update public.rf_promotion_offers set usage_limit=4 where id=offer;
  set local role anon;
  request:=request||jsonb_build_object('p_request_id',second_booking,'p_resource_code','S2');
  perform public.quote_customer_payment(request);
  pass:=(public.submit_customer_payment(request,380,image)->>'pass_token')::uuid;
  reset role;
  update public.bookings set status='confirmed' where id=second_booking;
  update public.bookings set status='completed' where id=second_booking;
  if public.rf_booking_voucher(pass) is not null then raise exception 'completion bypassed check-in'; end if;
  update public.bookings set status='confirmed',starts_at=now()+interval '5 minutes',
    ends_at=now()+interval '3 hours 5 minutes' where id=second_booking;
  select scan_token into scan from reserveflow_private.booking_passes where booking_id=second_booking;
  set local role authenticated;
  perform set_config('request.jwt.claim.sub',account::text,true);
  perform public.check_in_booking_pass(scan);
  reset role;
  if public.rf_booking_voucher(pass) is not null then raise exception 'check-in issued coupon without verified payment'; end if;
  set local role service_role;
  if public.finish_booking_slip_checked(second_booking,'provider_verified','promo-fixture-second',380,
    '1234567890',array['Test Recipient'],now())->>'state' is distinct from 'confirmed'
    then raise exception 'valid slip did not confirm after check-in'; end if;
  reset role;
  if (select status from public.bookings where id=second_booking) <> 'checked_in'
    then raise exception 'slip retry changed the check-in status'; end if;
  update public.bookings set status='completed' where id=second_booking;
  second_token:=public.rf_booking_voucher(pass);
  if second_token is null then raise exception 'website booking lacks coupon'; end if;
  if public.get_customer_booking_pass(pass)->>'gift_coupon_status' is distinct from 'not_linked'
    then raise exception 'customer pass did not distinguish coupon from LINE delivery'; end if;
  set local role authenticated;
  perform set_config('request.jwt.claim.sub',stranger::text,true);
  begin
    perform public.rf_archive_promotion_offer(shop,offer);
    raise exception 'cross-tenant promotion deletion';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.sub',account::text,true);
  perform public.rf_archive_promotion_offer(shop,offer);
  perform public.rf_archive_promotion_offer(shop,offer);
  if exists(select 1 from public.rf_promotion_offers where id=offer)
    then raise exception 'deleted promotion still visible to merchant'; end if;
  reset role;
  if exists(select 1 from jsonb_array_elements(public.rf_booking_offers(request->>'p_shop_slug','seat',3)) as x
    where x->>'id'=offer::text) then raise exception 'deleted promotion still available'; end if;
  if public.rf_booking_voucher(pass) is distinct from second_token then
    raise exception 'deleting promotion removed existing coupon';
  end if;
  update public.rf_promotion_vouchers set expires_at=now()-interval '1 second' where booking_id=second_booking;
  if public.rf_promotion_qr_available(second_token) then raise exception 'expired QR still rendered'; end if;
  set local role authenticated;
  perform set_config('request.jwt.claim.sub',account::text,true);
  if public.rf_redeem_promotion_voucher(second_token)->>'reason'<>'EXPIRED' then raise exception 'expired QR accepted'; end if;
  reset role;
  update public.rf_promotion_vouchers set expires_at=now()+interval '1 day' where booking_id=second_booking;
  set local role service_role;
  perform public.rf_record_booking_refund(second_booking,'refund-fixture');
  reset role;
  if (select status from public.rf_promotion_vouchers where booking_id=second_booking)<>'void' then raise exception 'refund left usable voucher'; end if;
  delete from reserveflow_private.rf_promotion_refunds where booking_id=second_booking;
  update public.rf_promotion_vouchers set status='issued' where booking_id=second_booking;
  update public.bookings set status='cancelled' where id=second_booking;
  if public.rf_promotion_qr_available(second_token) then raise exception 'cancelled QR still rendered'; end if;
end;
$$;

-- The shell concurrency test keeps the fixture in a disposable database and launches two sessions.
\if :{?promo_concurrency}
update public.rf_promotion_vouchers set status='issued',redeemed_at=null,redeemed_by=null
where booking_id='85510000-0000-4000-8000-000000000005';
commit;
\else
rollback;
\endif
