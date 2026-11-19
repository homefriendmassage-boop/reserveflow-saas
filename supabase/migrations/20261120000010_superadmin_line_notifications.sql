begin;
create schema if not exists reserveflow_private;
revoke all on schema reserveflow_private from public, anon, authenticated;

create table reserveflow_private.platform_admins (user_id uuid primary key references auth.users(id) on delete cascade);
insert into reserveflow_private.platform_admins
select id from auth.users where id = '70900f9a-8a21-425f-95ba-ddac9b4e4612';

create table reserveflow_private.line_targets (
  id uuid primary key default gen_random_uuid(),
  owner_scope text not null,
  target text not null,
  target_type text not null check (target_type in ('user','group')),
  created_at timestamptz not null default now(),
  unique (owner_scope, target)
);
create table reserveflow_private.line_pairing (
  code uuid primary key default gen_random_uuid(),
  owner_scope text not null,
  requested_by uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null default (now() + interval '15 minutes')
);
create table reserveflow_private.line_outbox (
  id uuid primary key default gen_random_uuid(),
  target_id uuid not null references reserveflow_private.line_targets(id) on delete cascade,
  kind text not null check (kind in ('shop','booking')),
  payload jsonb not null,
  attempts integer not null default 0,
  next_at timestamptz not null default now(),
  lease_id uuid,
  delivered_at timestamptz,
  last_status integer
);
create index line_outbox_pending_idx on reserveflow_private.line_outbox(next_at)
  where delivered_at is null and attempts < 8;

create function public.platform_shop_overview()
returns table (shop_id uuid, slug text, name text, public_booking_enabled boolean, created_at timestamptz, staff_count bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not exists (select 1 from reserveflow_private.platform_admins where user_id = (select auth.uid())) then
    raise exception using errcode = '42501', message = 'PLATFORM_ADMIN_REQUIRED';
  end if;
  return query select s.id,s.slug,s.name,s.public_booking_enabled,s.created_at,
    (select count(*) from public.shop_members m where m.shop_id = s.id)
  from public.shops s order by s.created_at desc, s.id limit 250;
end;
$$;

create function reserveflow_private.line_scope(p_shop_id uuid)
returns text
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_shop_id is null then
    if exists (select 1 from reserveflow_private.platform_admins where user_id = (select auth.uid())) then
      return 'platform';
    end if;
  elsif exists (select 1 from public.shop_members where shop_id = p_shop_id
    and user_id = (select auth.uid()) and role = 'owner') then
    return p_shop_id::text;
  end if;
  raise exception using errcode = '42501', message = 'LINE_SETTINGS_FORBIDDEN';
end;
$$;

create function public.create_line_pairing(p_shop_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  scope text := reserveflow_private.line_scope(p_shop_id);
  pairing_code uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('line-pairing:' || scope, 0));
  delete from reserveflow_private.line_pairing where owner_scope = scope or expires_at <= now();
  insert into reserveflow_private.line_pairing (owner_scope, requested_by)
    values (scope, auth.uid()) returning code into pairing_code;
  return pairing_code;
end;
$$;

create function public.list_line_targets(p_shop_id uuid)
returns table (id uuid, target_type text, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
declare scope text := reserveflow_private.line_scope(p_shop_id);
begin
  return query select t.id,t.target_type,t.created_at
    from reserveflow_private.line_targets t where t.owner_scope = scope
    order by t.created_at desc;
end;
$$;

create function public.remove_line_target(p_shop_id uuid, p_target_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare scope text := reserveflow_private.line_scope(p_shop_id);
begin
  delete from reserveflow_private.line_targets where owner_scope = scope and id = p_target_id;
end;
$$;

create function public.redeem_line_pairing(p_code uuid, p_target text, p_target_type text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare pairing reserveflow_private.line_pairing%rowtype;
begin
  if p_target_type is null or p_target_type not in ('user','group') or p_target is null
    or (p_target_type = 'user' and p_target !~ '^U[0-9a-f]{32}$')
    or (p_target_type = 'group' and p_target !~ '^C[0-9a-f]{32}$') then return; end if;

  delete from reserveflow_private.line_pairing where code = p_code and expires_at > now()
    and (owner_scope <> 'platform' or p_target_type = 'user')
    returning * into pairing;
  if not found then return; end if;
  if pairing.owner_scope = 'platform' then
    if not exists (select 1 from reserveflow_private.platform_admins where user_id = pairing.requested_by)
      then return; end if;
  elsif not exists (select 1 from public.shop_members where shop_id::text = pairing.owner_scope
    and user_id = pairing.requested_by and role = 'owner') then return;
  end if;
  insert into reserveflow_private.line_targets (owner_scope,target,target_type)
    values (pairing.owner_scope,p_target,p_target_type) on conflict (owner_scope,target) do nothing;
end;
$$;

create function reserveflow_private.queue_line_shop()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into reserveflow_private.line_outbox (target_id,kind,payload)
    select id,'shop',jsonb_build_object('name',new.name,'slug',new.slug)
    from reserveflow_private.line_targets where owner_scope = 'platform';
  return new;
end;
$$;
create trigger reserveflow_line_new_shop after insert on public.shops
for each row execute function reserveflow_private.queue_line_shop();

create function reserveflow_private.queue_line_booking()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into reserveflow_private.line_outbox (target_id,kind,payload)
    select t.id,'booking',jsonb_build_object('name',s.name,'resource',new.resource_code,
      'date',to_char(new.starts_at at time zone s.timezone,'DD/MM/YYYY HH24:MI'),
      'time_zone',s.timezone,'booking_id',new.id)
    from public.shops s join reserveflow_private.line_targets t on t.owner_scope = s.id::text
    where s.id = new.shop_id;
  return new;
end;
$$;
create trigger reserveflow_line_new_booking after insert on public.bookings
for each row execute function reserveflow_private.queue_line_booking();

create function public.claim_line_notifications()
returns table (id uuid, target text, kind text, payload jsonb, lease_id uuid)
language sql security definer set search_path = ''
as $$
  with ready as (
    select q.id from reserveflow_private.line_outbox q
    where q.delivered_at is null and q.next_at <= now() and q.attempts < 8
    order by q.next_at, q.id limit 20 for update skip locked
  ), claimed as (
    update reserveflow_private.line_outbox q set attempts = q.attempts + 1,
      next_at = now() + interval '5 minutes', lease_id = gen_random_uuid()
    from ready where q.id = ready.id returning q.*
  )
  select c.id,t.target,c.kind,c.payload,c.lease_id from claimed c
    join reserveflow_private.line_targets t on t.id = c.target_id;
$$;

create function public.finish_line_notification(p_id uuid,p_lease_id uuid,p_status integer,p_delivered boolean,p_retry boolean)
returns void language sql security definer set search_path = ''
as $$
  update reserveflow_private.line_outbox set
    delivered_at = case when p_delivered then now() else null end,
    last_status = p_status,
    next_at = now() + make_interval(mins => least(60, 2 ^ least(attempts, 6))::integer),
    attempts = case when not p_delivered and not p_retry then 8 else attempts end,
    lease_id = null
  where id = p_id and lease_id = p_lease_id and delivered_at is null;
$$;

revoke all on function public.platform_shop_overview(),public.create_line_pairing(uuid),
  public.list_line_targets(uuid),public.remove_line_target(uuid,uuid) from public, anon, authenticated;
grant execute on function public.platform_shop_overview(),public.create_line_pairing(uuid),
  public.list_line_targets(uuid),public.remove_line_target(uuid,uuid) to authenticated;
revoke all on function public.redeem_line_pairing(uuid,text,text),public.claim_line_notifications(),
  public.finish_line_notification(uuid,uuid,integer,boolean,boolean) from public, anon, authenticated;
grant execute on function public.redeem_line_pairing(uuid,text,text),public.claim_line_notifications(),
  public.finish_line_notification(uuid,uuid,integer,boolean,boolean) to service_role;
commit;
