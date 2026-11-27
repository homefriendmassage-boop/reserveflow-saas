begin;

alter table reserveflow_private.booking_passes add column pending_line_queued_at timestamptz;

create function public.booking_line_friend_id(p_shop_slug text)
returns text language sql stable security definer set search_path='' as $$
  select c.friend_basic_id
  from reserveflow_private.shop_line_channels c join public.shops s on s.id=c.shop_id
  where s.slug=p_shop_slug and s.public_booking_enabled and c.booking_liff_id is not null;
$$;

revoke all on function public.booking_line_friend_id(text) from public,anon,authenticated;
grant execute on function public.booking_line_friend_id(text) to anon,authenticated;

create or replace function reserveflow_private.queue_customer_booking_pass(p_booking uuid)
returns void language sql set search_path=''
as $$
  with eligible as (
    select t.booking_id,t.view_token,t.line_bot,
      case when b.status in ('pending_confirm','slip_review') then 'pending' else 'confirmed' end as stage
    from reserveflow_private.booking_passes t join public.bookings b on b.id=t.booking_id
    join reserveflow_private.shop_line_channels c on c.shop_id=b.shop_id and c.bot_id=t.line_bot
    where t.booking_id=p_booking and t.line_user is not null and (
      b.status in ('pending_confirm','slip_review') and b.ends_at>now()
      or b.status in ('confirmed','checked_in','completed') and b.ends_at+interval '24 hours'>now()
    )
  ), claimed as (
    update reserveflow_private.booking_passes t set
      pending_line_queued_at=case when e.stage='pending' then now() else t.pending_line_queued_at end,
      line_queued_at=case when e.stage='confirmed' then now() else t.line_queued_at end
    from eligible e
    where t.booking_id=e.booking_id and (
      e.stage='pending' and t.pending_line_queued_at is null
      or e.stage='confirmed' and t.line_queued_at is null
    )
    returning t.booking_id,t.view_token,t.line_bot,e.stage
  )
  insert into reserveflow_private.line_outbox(kind,customer_booking_id,sender_bot_id,payload)
  select 'booking_pass',booking_id,line_bot,
    reserveflow_private.booking_pass_details(booking_id) ||
      jsonb_build_object('pass_token',view_token,'notification_stage',stage)
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
        and (
          (q.payload->>'notification_stage'='pending' and b.status in ('pending_confirm','slip_review') and b.ends_at>now())
          or (q.payload->>'notification_stage' is distinct from 'pending'
            and b.status in ('confirmed','checked_in','completed') and b.ends_at+interval '24 hours'>now())
        ))
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
      and coalesce(q.payload->>'notification_stage'='pending',false)
        = (b.status in ('pending_confirm','slip_review'))
    order by q.next_at desc limit 1
  ) delivery on true
  where t.view_token=p_token and now()<=b.ends_at+interval '30 days';
$$;

notify pgrst,'reload schema';
commit;
