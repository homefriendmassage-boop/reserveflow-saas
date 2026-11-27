begin;

-- Existing bookings get a channel only when an original booking record establishes it.
alter table public.bookings add column booking_channel text check (booking_channel in ('online','staff'));
alter table public.bookings alter column booking_channel set default 'staff';

update public.bookings b set booking_channel='staff'
where exists(select 1 from reserveflow_private.counter_booking_payments p where p.booking_id=b.id)
   or exists(select 1 from reserveflow_private.merchant_cash_payments p where p.booking_id=b.id);

update public.bookings b set booking_channel='online'
where b.booking_channel is null and (
  exists(select 1 from reserveflow_private.rf_promotion_selections p where p.booking_id=b.id)
  or exists(select 1 from reserveflow_private.booking_payment_quotes q join public.shops s on s.slug=q.shop_slug
    where q.booking_id=b.id and s.id=b.shop_id and q.phone=b.customer_phone)
);

create or replace function reserveflow_private.booking_from_payment_request(p_request jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare
  terms jsonb;
  saved jsonb;
begin
  terms := reserveflow_private.rf_promotion_terms(p_request,false);
  saved := reserveflow_private.rf_submit_customer_booking(
    (p_request->>'p_request_id')::uuid,p_request->>'p_shop_slug',
    p_request->>'p_category_code',p_request->>'p_resource_code',
    (p_request->>'p_date')::date,(p_request->>'p_hour')::integer,(p_request->>'p_hours')::integer,
    (p_request->>'p_guests')::integer,(p_request->>'p_tickets')::integer,
    p_request->>'p_name',p_request->>'p_phone',p_request->>'p_note',(p_request->>'p_minute')::integer,
    (terms->>'amount')::numeric);
  update public.bookings set booking_channel='online'
  where id=(saved->>'id')::uuid and booking_channel is distinct from 'online';
  if terms is not null then
    update reserveflow_private.rf_promotion_selections set booking_id=(saved->>'id')::uuid
      where request_id=(p_request->>'p_request_id')::uuid and booking_id is null;
    return saved || jsonb_build_object('promotion',terms);
  end if;
  return saved;
end;
$$;

create or replace function reserveflow_private.booking_pass_details(p_booking uuid)
returns jsonb language sql stable set search_path=''
as $$
  select jsonb_build_object('booking_id',b.id,'shop',s.name,'item',r.name,'category',c.name,
    'date',to_char((b.starts_at at time zone s.timezone)-interval '6 hours','DD/MM/YYYY'),
    'period',to_char(b.starts_at at time zone s.timezone,'HH24:MI')||
      case when (b.starts_at at time zone s.timezone)::time<time '06:00' then ' (+1 วัน)' else '' end||' – '||
      to_char(b.ends_at at time zone s.timezone,'HH24:MI')||
      case when ((b.starts_at at time zone s.timezone)-interval '6 hours')::date<>(b.ends_at at time zone s.timezone)::date
        then ' (+1 วัน)' else '' end,
    'hours',extract(epoch from b.ends_at-b.starts_at)/3600,'amount',b.amount,'status',b.status,
    'booking_channel',b.booking_channel,
    'package_name',p.terms->>'name',
    'package_hours',p.terms->>'hours',
    'package_extra_hours',p.terms->>'extra_hours',
    'package_gift',p.terms->>'gift',
    'gift_coupon_status',case when p.terms->>'mode'='gift' then case
      when b.status='cancelled' or v.status='void' then 'void'
      when v.status='redeemed' then 'redeemed'
      when coalesce(v.expires_at,
        (reserveflow_private.rf_coupon_day_start(b.starts_at,s.timezone)+interval '1 day') at time zone s.timezone
      )<=now() then 'expired'
      when not reserveflow_private.rf_promotion_checked_in(b.id) then 'check_in_required'
      when v.id is null then 'payment_review'
      when binding.booking_id is null then 'not_linked'
      when delivery.status='sent' then 'sent'
      when delivery.status='failed' and delivery.attempts>=5 then 'failed'
      else 'queued' end end,
    'package_savings',greatest(0,(p.terms->>'regular_rate')::numeric*(p.terms->>'hours')::integer
      -(p.terms->>'price')::numeric))
  from public.bookings b join public.shops s on s.id=b.shop_id
  join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
  join public.resources r on (r.shop_id,r.category_code,r.code)=(b.shop_id,b.category_code,b.resource_code)
  left join reserveflow_private.rf_promotion_selections p on p.booking_id=b.id
  left join public.rf_promotion_vouchers v on v.booking_id=b.id and v.offer_id=p.offer_id
  left join reserveflow_private.rf_promotion_line_bindings binding on binding.booking_id=b.id
  left join public.rf_promotion_events delivery on delivery.voucher_id=v.id and delivery.kind='issued'
  where b.id=p_booking;
$$;

-- Enrich queued messages while leaving historical delivery records intact.
update reserveflow_private.line_outbox q
set payload=q.payload || (select jsonb_object_agg(d.key,d.value)
  from jsonb_each(reserveflow_private.booking_pass_details(q.customer_booking_id)) d
  where d.key in ('booking_channel','package_name','package_hours','package_extra_hours','package_gift','package_savings'))
where q.kind='booking_pass' and q.delivered_at is null and q.customer_booking_id is not null
  and reserveflow_private.booking_pass_details(q.customer_booking_id) is not null;

notify pgrst,'reload schema';
commit;
