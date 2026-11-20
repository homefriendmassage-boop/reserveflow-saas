begin;

create table reserveflow_private.shop_line_channels (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  secret_id uuid not null,
  bot_id text not null unique check(bot_id ~ '^U[0-9a-f]{32}$'),
  bot_name text not null
);

alter table reserveflow_private.line_targets add column bot_id text;
alter table reserveflow_private.line_outbox add column sender_bot_id text;

create function reserveflow_private.stamp_line_sender()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  select t.bot_id into new.sender_bot_id from reserveflow_private.line_targets t where t.id=new.target_id;
  return new;
end;
$$;
create trigger stamp_line_sender before insert on reserveflow_private.line_outbox
for each row execute function reserveflow_private.stamp_line_sender();

create function public.shop_line_channel_status(p_shop_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  perform reserveflow_private.line_scope(p_shop_id);
  return coalesce((select jsonb_build_object('bot_name',bot_name) from reserveflow_private.shop_line_channels
    where shop_id=p_shop_id),'{}'::jsonb);
end;
$$;

create function public.save_shop_line_channel(
  p_shop_id uuid,p_owner uuid,p_secret text,p_token text,p_bot_id text,p_bot_name text
) returns void language plpgsql security definer set search_path=''
as $$
declare
  previous reserveflow_private.shop_line_channels%rowtype;
  vault_id uuid;
  credentials text := jsonb_build_object('secret',p_secret,'token',p_token)::text;
begin
  if not exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=p_owner and role='owner') then
    raise insufficient_privilege;
  end if;
  if not coalesce(p_secret ~ '^[a-fA-F0-9]{32}$',false) or not coalesce(length(p_token) between 20 and 4096,false)
    or not coalesce(p_bot_id ~ '^U[0-9a-f]{32}$',false) or not coalesce(length(p_bot_name) between 1 and 200,false) then
    raise invalid_parameter_value;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('line-pairing:'||p_shop_id::text,0));
  select * into previous from reserveflow_private.shop_line_channels where shop_id=p_shop_id;
  if previous.secret_id is null then
    vault_id := vault.create_secret(credentials);
  else
    vault_id := previous.secret_id;
    perform vault.update_secret(vault_id,credentials);
  end if;
  insert into reserveflow_private.shop_line_channels(shop_id,secret_id,bot_id,bot_name)
  values(p_shop_id,vault_id,p_bot_id,p_bot_name)
  on conflict(shop_id) do update set bot_id=excluded.bot_id,bot_name=excluded.bot_name;
  if previous.bot_id is distinct from p_bot_id then
    delete from reserveflow_private.line_pairing where owner_scope=p_shop_id::text;
    update reserveflow_private.line_outbox q set attempts=8
    from reserveflow_private.line_targets t where q.target_id=t.id and t.owner_scope=p_shop_id::text
      and q.delivered_at is null and t.bot_id is distinct from p_bot_id;
    update reserveflow_private.line_targets set bot_id=null where owner_scope=p_shop_id::text;
  end if;
end;
$$;

create function public.shop_line_webhook_credentials(p_shop_id uuid)
returns table(bot_id text,channel_secret text)
language sql stable security definer set search_path='' as $$
  select s.bot_id,(v.decrypted_secret::jsonb)->>'secret'
  from reserveflow_private.shop_line_channels s join vault.decrypted_secrets v on v.id=s.secret_id
  where s.shop_id=p_shop_id;
$$;

create or replace function public.create_line_pairing(p_shop_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
  scope text := reserveflow_private.line_scope(p_shop_id);
  pairing_code uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('line-pairing:'||scope,0));
  if p_shop_id is not null and not exists(select 1 from reserveflow_private.shop_line_channels where shop_id=p_shop_id) then
    raise exception using errcode='22023',message='LINE_SHOP_CHANNEL_REQUIRED';
  end if;
  delete from reserveflow_private.line_pairing where owner_scope=scope or expires_at<=now();
  insert into reserveflow_private.line_pairing(owner_scope,requested_by)
  values(scope,auth.uid()) returning code into pairing_code;
  return pairing_code;
end;
$$;

create function public.redeem_scoped_line_pairing(p_code uuid,p_target text,p_target_type text,p_shop_id uuid,p_bot_id text)
returns void language plpgsql security definer set search_path=''
as $$
declare
  scope text := coalesce(p_shop_id::text,'platform');
  pairing reserveflow_private.line_pairing%rowtype;
begin
  if not coalesce((p_target_type='user' and p_target ~ '^U[0-9a-f]{32}$')
    or (p_target_type='group' and p_target ~ '^C[0-9a-f]{32}$'),false) then return; end if;
  perform pg_advisory_xact_lock(hashtextextended('line-pairing:'||scope,0));
  if p_shop_id is null and p_target_type<>'user' then return; end if;
  if p_shop_id is not null and not exists(select 1 from reserveflow_private.shop_line_channels
    where shop_id=p_shop_id and bot_id=p_bot_id) then return; end if;
  delete from reserveflow_private.line_pairing where code=p_code and expires_at>now() and owner_scope=scope
    returning * into pairing;
  if not found then return; end if;
  if p_shop_id is null then
    if not exists(select 1 from reserveflow_private.platform_admins where user_id=pairing.requested_by) then return; end if;
  elsif not exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=pairing.requested_by and role='owner') then return; end if;
  insert into reserveflow_private.line_targets(owner_scope,target,target_type,bot_id)
  values(scope,p_target,p_target_type,p_bot_id)
  on conflict(owner_scope,target) do update set bot_id=excluded.bot_id,created_at=now();
end;
$$;

-- Earlier webhook deployments can continue receiving platform pairing only.
create or replace function public.redeem_line_pairing(p_code uuid,p_target text,p_target_type text)
returns void language sql security definer set search_path='' as $$
  select public.redeem_scoped_line_pairing(p_code,p_target,p_target_type,null,null);
$$;

create function reserveflow_private.line_target_is_current(p_target reserveflow_private.line_targets)
returns boolean language sql stable security definer set search_path='' as $$
  select p_target.owner_scope='platform' or exists(select 1 from reserveflow_private.shop_line_channels s
     where s.shop_id::text=p_target.owner_scope and s.bot_id=p_target.bot_id);
$$;

create or replace function public.list_line_targets(p_shop_id uuid)
returns table(id uuid,target_type text,created_at timestamptz)
language plpgsql stable security definer set search_path=''
as $$
declare scope text := reserveflow_private.line_scope(p_shop_id);
begin
  return query select t.id,t.target_type,t.created_at from reserveflow_private.line_targets t
  where t.owner_scope=scope and reserveflow_private.line_target_is_current(t) order by t.created_at desc;
end;
$$;

create or replace function reserveflow_private.queue_line_booking()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  insert into reserveflow_private.line_outbox(target_id,kind,payload)
  select t.id,'booking',jsonb_build_object('name',s.name,'resource',new.resource_code,
    'date',to_char(new.starts_at at time zone s.timezone,'DD/MM/YYYY HH24:MI'),
    'time_zone',s.timezone,'booking_id',new.id)
  from public.shops s join reserveflow_private.line_targets t on t.owner_scope=s.id::text
  where s.id=new.shop_id and reserveflow_private.line_target_is_current(t);
  return new;
end;
$$;
create or replace function public.claim_line_notifications()
returns table (id uuid, target text, kind text, payload jsonb, lease_id uuid)
language sql security definer set search_path = ''
as $$
  with ready as (
    select q.id from reserveflow_private.line_outbox q
    where exists(select 1 from reserveflow_private.line_targets t where t.id=q.target_id and t.owner_scope='platform')
      and q.delivered_at is null and q.next_at <= now() and q.attempts < 8
    order by q.next_at, q.id limit 20 for update skip locked
  ), claimed as (
    update reserveflow_private.line_outbox q set attempts = q.attempts + 1,
      next_at = now() + interval '5 minutes', lease_id = gen_random_uuid()
    from ready where q.id = ready.id returning q.*
  )
  select c.id,t.target,c.kind,c.payload,c.lease_id from claimed c
    join reserveflow_private.line_targets t on t.id = c.target_id;
$$;
create or replace function public.claim_line_notifications_scoped(p_platform_enabled boolean)
returns table (id uuid, target text, kind text, payload jsonb, lease_id uuid, owner_scope text, access_token text)
language sql security definer set search_path = ''
as $$
  with ready as (
    select q.id from reserveflow_private.line_outbox q
    join reserveflow_private.line_targets t on t.id=q.target_id
    where reserveflow_private.line_target_is_current(t)
      and q.sender_bot_id is not distinct from t.bot_id
      and (t.owner_scope<>'platform' or p_platform_enabled)
      and q.delivered_at is null and q.next_at <= now() and q.attempts < 8
    order by q.next_at, q.id limit 20 for update of q skip locked
  ), claimed as (
    update reserveflow_private.line_outbox q set attempts = q.attempts + 1,
      next_at = now() + interval '5 minutes', lease_id = gen_random_uuid()
    from ready where q.id = ready.id returning q.*
  )
  select c.id,t.target,c.kind,c.payload,c.lease_id,t.owner_scope,(v.decrypted_secret::jsonb)->>'token' from claimed c
    join reserveflow_private.line_targets t on t.id = c.target_id
    left join reserveflow_private.shop_line_channels s on s.shop_id::text=t.owner_scope and s.bot_id=t.bot_id
    left join vault.decrypted_secrets v on v.id=s.secret_id;
$$;

create or replace function public.shop_daily_report_groups(p_shop_id uuid)
returns table(id uuid,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.can_read_shop_reports(p_shop_id) then raise insufficient_privilege; end if;
  return query select t.id,t.created_at from reserveflow_private.line_targets t
  where t.owner_scope=p_shop_id::text and t.target_type='group' and reserveflow_private.line_target_is_current(t) order by t.created_at;
end;
$$;

create or replace function public.send_shop_daily_report(p_shop_id uuid,p_date date,p_target_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  report jsonb := public.shop_daily_report(p_shop_id,p_date);
  outbox_id uuid;
begin
  if not exists(select 1 from reserveflow_private.line_targets t where id=p_target_id and reserveflow_private.line_target_is_current(t)
    and owner_scope=p_shop_id::text and target_type='group') then raise insufficient_privilege; end if;
  perform pg_advisory_xact_lock(hashtextextended('daily-report:'||p_target_id::text||':'||p_date::text,0));
  select id into outbox_id from reserveflow_private.line_outbox
  where target_id=p_target_id and kind='daily_report' and sender_bot_id=(select bot_id from reserveflow_private.line_targets where id=p_target_id) and payload->>'date'=p_date::text and payload=report
    and coalesce(delivered_at,next_at)>now()-interval '30 seconds' and attempts<8
  limit 1;
  if found then return outbox_id; end if;
  insert into reserveflow_private.line_outbox(target_id,kind,payload)
  values(p_target_id,'daily_report',report) returning id into outbox_id;
  return outbox_id;
end;
$$;

create or replace function public.send_referral_flex(p_shop_id uuid,p_target_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare target_scope text;
begin
  if p_shop_id is null then
    if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
    target_scope := 'platform';
  else
    if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
    target_scope := p_shop_id::text;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('referral-flex:'||p_target_id::text,0));
  if exists(select 1 from reserveflow_private.line_outbox where target_id=p_target_id and kind='referral'
    and sender_bot_id is not distinct from (select bot_id from reserveflow_private.line_targets where id=p_target_id)
    and next_at>now()-interval '30 seconds') then return; end if;
  insert into reserveflow_private.line_outbox(target_id,kind,payload)
  select id,'referral',jsonb_build_object('ref',p_shop_id,'name',coalesce((select name from public.shops where id=p_shop_id),'ReserveFlow'))
  from reserveflow_private.line_targets t where owner_scope=target_scope and reserveflow_private.line_target_is_current(t) and id=p_target_id;
  if not found then raise insufficient_privilege; end if;
end;
$$;

revoke all on function public.shop_line_channel_status(uuid) from public,anon,authenticated;
grant execute on function public.shop_line_channel_status(uuid) to authenticated;
revoke all on function public.save_shop_line_channel(uuid,uuid,text,text,text,text),
  public.shop_line_webhook_credentials(uuid),public.redeem_scoped_line_pairing(uuid,text,text,uuid,text),
  public.claim_line_notifications_scoped(boolean) from public,anon,authenticated;
grant execute on function public.save_shop_line_channel(uuid,uuid,text,text,text,text),
  public.shop_line_webhook_credentials(uuid),public.redeem_scoped_line_pairing(uuid,text,text,uuid,text),
  public.claim_line_notifications_scoped(boolean) to service_role;

commit;
