begin;

create or replace function public.get_customer_booking_pass(p_token uuid)
returns jsonb language sql stable security definer set search_path=''
as $$
  select reserveflow_private.booking_pass_details(b.id) || jsonb_build_object(
    'scan_token',case when b.status in ('pending_payment','pending_confirm','slip_review','confirmed')
      and now()<b.ends_at then t.scan_token end,
    'line_code',case when c.bot_id is not null and (t.line_user is null or t.line_bot is distinct from c.bot_id)
      and b.ends_at>now() and b.status in ('pending_payment','pending_confirm','slip_review','confirmed') then t.line_token end,
    'line_linked',t.line_user is not null and t.line_bot=c.bot_id,
    'line_delivery',case when delivery.delivered_at is not null then 'accepted'
      when delivery.attempts>=8 then 'failed' when delivery.attempts is not null then 'queued' end,
    'bot_name',c.bot_name,'expired',now()>=b.ends_at)
  from reserveflow_private.booking_passes t join public.bookings b on b.id=t.booking_id
  left join reserveflow_private.shop_line_channels c on c.shop_id=b.shop_id
  left join lateral (
    select q.delivered_at,q.attempts from reserveflow_private.line_outbox q
    where q.customer_booking_id=t.booking_id and q.kind='booking_pass' and q.sender_bot_id=c.bot_id
    order by q.next_at desc limit 1
  ) delivery on true
  where t.view_token=p_token and now()<=b.ends_at+interval '30 days';
$$;

commit;
