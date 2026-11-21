begin;

create or replace function public.get_customer_booking_pass(p_token uuid)
returns jsonb language sql stable security definer set search_path=''
as $$
  select reserveflow_private.booking_pass_details(b.id) || jsonb_build_object(
    'scan_token',case when b.status in ('pending_payment','pending_confirm','slip_review','confirmed')
      and now()<b.ends_at then t.scan_token end,
    'line_code',case when c.bot_id is not null and (t.line_user is null or t.line_bot is distinct from c.bot_id)
      and (b.status in ('pending_payment','pending_confirm','slip_review') and b.ends_at>now()
      or b.status in ('confirmed','checked_in','completed') and b.ends_at+interval '24 hours'>now()) then t.line_token end,
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

create or replace function public.link_customer_booking_pass(p_token uuid,p_shop_id uuid,p_bot text,p_user text)
returns void language plpgsql security definer set search_path=''
as $$
declare booking uuid;
begin
  if p_user is null or p_user !~ '^U[0-9a-f]{32}$' then return; end if;
  select b.id into booking from public.bookings b
  join reserveflow_private.booking_passes t on t.booking_id=b.id
  join reserveflow_private.shop_line_channels c on c.shop_id=b.shop_id and c.bot_id=p_bot
  where t.line_token=p_token and b.shop_id=p_shop_id
    and (b.status in ('pending_payment','pending_confirm','slip_review') and b.ends_at>now()
      or b.status in ('confirmed','checked_in','completed') and b.ends_at+interval '24 hours'>now())
  for update of b;
  if not found then return; end if;
  update reserveflow_private.booking_passes set line_user=p_user,line_bot=p_bot,line_queued_at=null
  where booking_id=booking and (line_user is null or line_bot is distinct from p_bot);
  perform reserveflow_private.queue_customer_booking_pass(booking);
end;
$$;

create or replace function reserveflow_private.queue_customer_booking_pass(p_booking uuid)
returns void language sql set search_path=''
as $$
  with claimed as (
    update reserveflow_private.booking_passes t set line_queued_at=now()
    from public.bookings b join reserveflow_private.shop_line_channels c on c.shop_id=b.shop_id
    where t.booking_id=p_booking and b.id=t.booking_id and b.status in ('confirmed','checked_in','completed') and b.ends_at+interval '24 hours'>now()
      and t.line_queued_at is null and t.line_user is not null and t.line_bot=c.bot_id
    returning t.booking_id,t.view_token,t.line_bot
  )
  insert into reserveflow_private.line_outbox(kind,customer_booking_id,sender_bot_id,payload)
  select 'booking_pass',booking_id,line_bot,
    reserveflow_private.booking_pass_details(booking_id)||jsonb_build_object('pass_token',view_token)
  from claimed;
$$;

create or replace function public.claim_line_notifications_scoped(p_platform_enabled boolean)
returns table (id uuid,target text,kind text,payload jsonb,lease_id uuid,owner_scope text,access_token text)
language sql security definer set search_path=''
as $$
  with ready as (
    select q.id,coalesce(t.target,p.line_user) target,coalesce(t.owner_scope,b.shop_id::text) scope,
      s.secret_id
    from reserveflow_private.line_outbox q
    left join reserveflow_private.line_targets t on t.id=q.target_id
    left join reserveflow_private.booking_passes p on p.booking_id=q.customer_booking_id
    left join public.bookings b on b.id=p.booking_id
    left join reserveflow_private.shop_line_channels s
      on s.shop_id::text=coalesce(t.owner_scope,b.shop_id::text) and s.bot_id=q.sender_bot_id
    where (
      (t.id is not null and reserveflow_private.line_target_is_current(t)
        and q.sender_bot_id is not distinct from t.bot_id and (t.owner_scope<>'platform' or p_platform_enabled))
      or (q.kind='booking_pass' and p.line_user is not null and p.line_bot=s.bot_id
        and b.status in ('confirmed','checked_in','completed') and b.ends_at+interval '24 hours'>now())
    ) and q.delivered_at is null and q.next_at<=now() and q.attempts<8
    order by q.next_at,q.id limit 20 for update of q skip locked
  ), claimed as (
    update reserveflow_private.line_outbox q set attempts=q.attempts+1,
      next_at=now()+interval '5 minutes',lease_id=gen_random_uuid()
    from ready where q.id=ready.id returning q.*,ready.target,ready.scope,ready.secret_id
  )
  select c.id,c.target,c.kind,c.payload,c.lease_id,c.scope,(v.decrypted_secret::jsonb)->>'token'
  from claimed c left join vault.decrypted_secrets v on v.id=c.secret_id;
$$;

commit;
