begin;

create table if not exists reserveflow_private.booking_passes (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  view_token uuid not null unique default gen_random_uuid(),
  scan_token uuid not null unique default gen_random_uuid(),
  line_token uuid not null unique default gen_random_uuid(),
  line_user text check(line_user ~ '^U[0-9a-f]{32}$'),
  line_bot text,
  line_queued_at timestamptz
);

alter table reserveflow_private.line_outbox alter column target_id drop not null;
alter table reserveflow_private.line_outbox add column if not exists customer_booking_id uuid
  references reserveflow_private.booking_passes(booking_id) on delete cascade;
alter table reserveflow_private.line_outbox drop constraint if exists line_outbox_kind_check;
alter table reserveflow_private.line_outbox add constraint line_outbox_kind_check
  check(kind in ('shop','booking','referral','daily_report','booking_pass'));
alter table reserveflow_private.line_outbox drop constraint if exists line_outbox_recipient_check;
alter table reserveflow_private.line_outbox add constraint line_outbox_recipient_check
  check ((kind='booking_pass' and target_id is null and customer_booking_id is not null)
    or (kind<>'booking_pass' and target_id is not null and customer_booking_id is null));

create or replace function reserveflow_private.issue_booking_pass(p_booking jsonb)
returns jsonb language plpgsql set search_path=''
as $$
declare
  booking uuid := (p_booking->>'id')::uuid;
  ticket uuid;
begin
  insert into reserveflow_private.booking_passes(booking_id) values(booking)
    on conflict(booking_id) do nothing;
  select view_token into ticket from reserveflow_private.booking_passes where booking_id=booking;
  return p_booking || jsonb_build_object('pass_token',ticket);
end;
$$;

create or replace function public.submit_customer_payment(p_request jsonb,p_amount numeric,p_image text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  booking jsonb;
  booking_id_value uuid;
  image_bytes bytea;
begin
  if not coalesce(length(p_image) <= 1450000
      and p_image ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$',false) then
    raise exception using errcode='22023', message='INVALID_SLIP_ATTACHMENT';
  end if;
  image_bytes := decode(split_part(p_image,',',2),'base64');
  if octet_length(image_bytes)>1048576 or not (case split_part(p_image,';',1)
    when 'data:image/jpeg' then substring(image_bytes,1,3)=decode('ffd8ff','hex')
    when 'data:image/png' then substring(image_bytes,1,8)=decode('89504e470d0a1a0a','hex')
    when 'data:image/webp' then substring(image_bytes,1,4)=decode('52494646','hex')
      and substring(image_bytes,9,4)=decode('57454250','hex')
    else false end) then
    raise exception using errcode='22023', message='INVALID_SLIP_ATTACHMENT';
  end if;
  booking := reserveflow_private.booking_from_payment_request(p_request);
  booking_id_value := (booking->>'id')::uuid;
  if (booking->>'amount')::numeric is distinct from p_amount then
    raise exception using errcode='22023', message='BOOKING_PRICE_CHANGED';
  end if;
  if exists (
    select 1 from public.booking_slip_attachments a
    where a.booking_id=booking_id_value and a.image=p_image
  ) then
    return reserveflow_private.issue_booking_pass(booking);
  end if;
  if public.booking_promptpay_qr(booking_id_value,p_request->>'p_phone') is null then
    raise exception using errcode='22023', message='BOOKING_PAYMENT_UNAVAILABLE';
  end if;
  perform public.attach_customer_booking_slip(booking_id_value,p_request->>'p_phone',p_image);
  return reserveflow_private.issue_booking_pass(booking);
end;
$$;

create or replace function reserveflow_private.booking_pass_details(p_booking uuid)
returns jsonb language sql stable set search_path=''
as $$
  select jsonb_build_object('booking_id',b.id,'shop',s.name,'item',r.name,'category',c.name,
    'date',to_char(b.starts_at at time zone s.timezone,'DD/MM/YYYY'),
    'period',to_char(b.starts_at at time zone s.timezone,'HH24:MI')||' – '||
      to_char(b.ends_at at time zone s.timezone,'HH24:MI')||
      case when (b.starts_at at time zone s.timezone)::date<>(b.ends_at at time zone s.timezone)::date
        then ' (+1 วัน)' else '' end,
    'hours',extract(epoch from b.ends_at-b.starts_at)/3600,'amount',b.amount,'status',b.status)
  from public.bookings b join public.shops s on s.id=b.shop_id
  join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
  join public.resources r on (r.shop_id,r.category_code,r.code)=(b.shop_id,b.category_code,b.resource_code)
  where b.id=p_booking;
$$;

create or replace function public.get_customer_booking_pass(p_token uuid)
returns jsonb language sql stable security definer set search_path=''
as $$
  select reserveflow_private.booking_pass_details(b.id) || jsonb_build_object(
    'scan_token',case when b.status='confirmed' and now()<b.ends_at then t.scan_token end,
    'line_code',case when c.bot_id is not null and (t.line_user is null or t.line_bot is distinct from c.bot_id)
      and b.ends_at>now() and b.status in ('pending_payment','pending_confirm','slip_review','confirmed') then t.line_token end,
    'line_linked',t.line_user is not null and t.line_bot=c.bot_id,
    'bot_name',c.bot_name,'expired',now()>=b.ends_at)
  from reserveflow_private.booking_passes t join public.bookings b on b.id=t.booking_id
  left join reserveflow_private.shop_line_channels c on c.shop_id=b.shop_id
  where t.view_token=p_token and now()<=b.ends_at+interval '30 days';
$$;

create or replace function public.get_merchant_booking_pass(p_token uuid)
returns jsonb language sql stable security definer set search_path=''
as $$
  select (case when m.role='staff' then reserveflow_private.booking_pass_details(b.id)-'amount'
    else reserveflow_private.booking_pass_details(b.id) end) || jsonb_build_object('shop_id',b.shop_id,
    'can_check_in',b.status='confirmed' and now()>=b.starts_at-interval '30 minutes' and now()<b.ends_at)
  from reserveflow_private.booking_passes t join public.bookings b on b.id=t.booking_id
  join public.shop_members m on m.shop_id=b.shop_id and m.user_id=(select auth.uid())
  where t.scan_token=p_token;
$$;

create or replace function public.check_in_booking_pass(p_token uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare pass jsonb := public.get_merchant_booking_pass(p_token);
begin
  if pass is null then raise insufficient_privilege; end if;
  update public.bookings set status='checked_in'
  where id=(pass->>'booking_id')::uuid and shop_id=(pass->>'shop_id')::uuid
    and status='confirmed' and statement_timestamp()>=starts_at-interval '30 minutes'
    and statement_timestamp()<ends_at;
  if not found and not exists(select 1 from public.bookings
    where id=(pass->>'booking_id')::uuid and status='checked_in') then
    raise exception using errcode='22023',message='INVALID_CHECK_IN';
  end if;
end;
$$;

create or replace function reserveflow_private.queue_customer_booking_pass(p_booking uuid)
returns void language sql set search_path=''
as $$
  with claimed as (
    update reserveflow_private.booking_passes t set line_queued_at=now()
    from public.bookings b join reserveflow_private.shop_line_channels c on c.shop_id=b.shop_id
    where t.booking_id=p_booking and b.id=t.booking_id and b.status='confirmed' and b.ends_at>now()
      and t.line_queued_at is null and t.line_user is not null and t.line_bot=c.bot_id
    returning t.booking_id,t.view_token,t.line_bot
  )
  insert into reserveflow_private.line_outbox(kind,customer_booking_id,sender_bot_id,payload)
  select 'booking_pass',booking_id,line_bot,
    reserveflow_private.booking_pass_details(booking_id)||jsonb_build_object('pass_token',view_token)
  from claimed;
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
  where t.line_token=p_token and b.shop_id=p_shop_id and b.ends_at>now()
    and b.status in ('pending_payment','pending_confirm','slip_review','confirmed')
  for update of b;
  if not found then return; end if;
  update reserveflow_private.booking_passes set line_user=p_user,line_bot=p_bot,line_queued_at=null
  where booking_id=booking and (line_user is null or line_bot is distinct from p_bot);
  perform reserveflow_private.queue_customer_booking_pass(booking);
end;
$$;

create or replace function reserveflow_private.booking_confirmed_pass()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  perform reserveflow_private.queue_customer_booking_pass(new.id);
  return new;
end;
$$;
drop trigger if exists booking_confirmed_pass on public.bookings;
create trigger booking_confirmed_pass after update of status on public.bookings for each row
when (new.status='confirmed' and old.status is distinct from new.status)
execute function reserveflow_private.booking_confirmed_pass();

create or replace function reserveflow_private.stamp_line_sender()
returns trigger language plpgsql set search_path=''
as $$
begin
  if new.target_id is not null then
    select t.bot_id into new.sender_bot_id from reserveflow_private.line_targets t where t.id=new.target_id;
  end if;
  return new;
end;
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
        and b.status='confirmed' and b.ends_at>now())
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

revoke all on function public.get_customer_booking_pass(uuid),public.get_merchant_booking_pass(uuid),
  public.check_in_booking_pass(uuid),public.link_customer_booking_pass(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.get_customer_booking_pass(uuid) to anon,authenticated;
grant execute on function public.get_merchant_booking_pass(uuid),public.check_in_booking_pass(uuid) to authenticated;
grant execute on function public.link_customer_booking_pass(uuid,uuid,text,text) to service_role;

commit;
