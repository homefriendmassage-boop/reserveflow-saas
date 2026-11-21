begin;

create table if not exists reserveflow_private.slip_allowance_settings (
  id boolean primary key default true check(id),
  paid_monthly integer not null check(paid_monthly between 0 and 100000),
  starter_total integer not null check(starter_total between 0 and 100000)
);
insert into reserveflow_private.slip_allowance_settings(paid_monthly,starter_total)
values(100,10) on conflict do nothing;

create table if not exists reserveflow_private.shop_special_entitlements (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  monthly_quota integer check(monthly_quota between 0 and 100000),
  quota_until date,
  access_until date,
  reason text not null default '',
  updated_by uuid,
  updated_at timestamptz not null default now()
);

alter table reserveflow_private.slip_credit_packs add column if not exists label text;
alter table reserveflow_private.slip_credit_packs add column if not exists shop_id uuid
  references public.shops(id) on delete cascade;
alter table reserveflow_private.slip_credit_packs add column if not exists enabled boolean not null default true;

create or replace function public.platform_slip_allowance_settings()
returns jsonb language sql stable security definer set search_path=''
as $$
  select jsonb_build_object('paid_monthly',paid_monthly,'starter_total',starter_total)
  from reserveflow_private.slip_allowance_settings where id;
$$;

create or replace function public.save_platform_slip_allowance_settings(p_paid integer,p_starter integer)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if p_paid is null or p_paid not between 0 and 100000 or p_starter is null or p_starter not between 0 and 100000 then
    raise exception using errcode='22023',message='INVALID_SLIP_QUOTA';
  end if;
  update reserveflow_private.slip_allowance_settings set paid_monthly=p_paid,starter_total=p_starter where id;
end;
$$;

create or replace function public.platform_shop_special_entitlement(p_shop_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return (select to_jsonb(e)-'updated_by' from reserveflow_private.shop_special_entitlements e where e.shop_id=p_shop_id);
end;
$$;

create or replace function public.save_platform_shop_special_entitlement(
  p_shop_id uuid,p_monthly integer,p_quota_until date,p_access_until date,p_reason text
)
returns void language plpgsql security definer set search_path=''
as $$
declare today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if (p_monthly is not null and p_monthly not between 0 and 100000)
    or (p_quota_until is not null and (p_monthly is null or not isfinite(p_quota_until) or p_quota_until<today))
    or (p_access_until is not null and (not isfinite(p_access_until) or p_access_until<today))
    or length(coalesce(p_reason,''))>300 then
    raise exception using errcode='22023',message='INVALID_SPECIAL_ENTITLEMENT';
  end if;
  if p_monthly is null and p_access_until is null then
    delete from reserveflow_private.shop_special_entitlements where shop_id=p_shop_id;
    return;
  end if;
  insert into reserveflow_private.shop_special_entitlements(shop_id,monthly_quota,quota_until,access_until,reason,updated_by)
  values(p_shop_id,p_monthly,p_quota_until,p_access_until,btrim(coalesce(p_reason,'')),auth.uid())
  on conflict(shop_id) do update set monthly_quota=excluded.monthly_quota,quota_until=excluded.quota_until,
    access_until=excluded.access_until,reason=excluded.reason,updated_by=excluded.updated_by,updated_at=now();
end;
$$;

create or replace function reserveflow_private.shop_booking_active(p_shop_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$
  select exists(select 1 from reserveflow_private.shop_special_entitlements where shop_id=p_shop_id
    and access_until>=(now() at time zone 'Asia/Bangkok')::date)
    or not exists(select 1 from reserveflow_private.shop_subscriptions
      where shop_id=p_shop_id and expires_at<=now());
$$;

create or replace function reserveflow_private.shop_slip_allowance(p_shop_id uuid)
returns table(period date,included_limit integer,remaining integer)
language sql stable set search_path=''
as $$
  with context as (
    select date_trunc('month',now() at time zone 'Asia/Bangkok')::date as month_start,
      e.monthly_quota,
      (exists(select 1 from reserveflow_private.shop_subscriptions s
        where s.shop_id=p_shop_id and s.expires_at>now())
      and exists(select 1 from reserveflow_private.package_orders o
        where o.shop_id=p_shop_id and o.state='approved')) as paid,
      a.paid_monthly,a.starter_total
    from reserveflow_private.slip_allowance_settings a
    left join reserveflow_private.shop_special_entitlements e on e.shop_id=p_shop_id
      and (e.quota_until is null or e.quota_until>=(now() at time zone 'Asia/Bangkok')::date)
    where a.id
  ), allowance as (
    select case when c.paid or c.monthly_quota is not null then c.month_start else date '2000-01-01' end as cycle,
      coalesce(c.monthly_quota,case when c.paid then c.paid_monthly else c.starter_total end) as quota
    from context c
  )
  select a.cycle,a.quota,greatest(0,a.quota-(select count(*)::integer
    from reserveflow_private.slip_credit_usage u where u.shop_id=p_shop_id
      and u.credit_source='included' and u.allowance_period=a.cycle))
  from allowance a;
$$;

create or replace function reserveflow_private.slip_packs_for_shop(p_shop_id uuid)
returns table(code text,credits integer,amount numeric,label text,shop_id uuid,enabled boolean)
language sql stable set search_path=''
as $$
  select 'starter',o.credits,o.amount,null::text,null::uuid,true from reserveflow_private.slip_credit_offer o
  union all
  select p.code,p.credits,p.amount,p.label,p.shop_id,p.enabled
  from reserveflow_private.slip_credit_packs p
  where p_shop_id is null or (p.enabled and (p.shop_id is null or p.shop_id=p_shop_id));
$$;

create or replace function public.save_custom_slip_credit_pack(
  p_code text,p_label text,p_credits integer,p_amount numeric,p_shop_id uuid,p_enabled boolean
)
returns void language plpgsql security definer set search_path=''
as $$
declare code_value text := coalesce(nullif(trim(p_code),''),'custom-'||gen_random_uuid()::text);
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if code_value='starter' then
    perform public.save_slip_credit_pack('starter',p_credits,p_amount);
    return;
  end if;
  if length(trim(coalesce(p_label,''))) not between 1 and 100 or p_enabled is null
    or p_credits is null or p_credits not between 1 and 100000 or p_amount is null
    or p_amount not between 0.01 and 9999999999.99 or p_amount<>round(p_amount,2) then
    raise exception using errcode='22023',message='INVALID_SLIP_PACK_PRICE';
  end if;
  insert into reserveflow_private.slip_credit_packs as p(code,credits,amount,label,shop_id,enabled)
  values(code_value,p_credits,p_amount,btrim(p_label),p_shop_id,p_enabled)
  on conflict(code) do update set credits=excluded.credits,amount=excluded.amount,label=excluded.label,
    shop_id=excluded.shop_id,enabled=excluded.enabled;
end;
$$;

create or replace function public.open_slip_credit_pack(p_shop_id uuid,p_code text)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
  if not exists(select 1 from reserveflow_private.slip_packs_for_shop(p_shop_id) where code=p_code) then
    raise exception using errcode='22023',message='SLIP_PACK_NOT_FOUND';
  end if;
  insert into reserveflow_private.slip_credit_orders(shop_id,credits,amount,receiving_mobile)
  select p_shop_id,o.credits,o.amount,b.mobile from reserveflow_private.slip_packs_for_shop(p_shop_id) o
  cross join reserveflow_private.platform_billing b where o.code=p_code and b.mobile is not null
  on conflict(shop_id) where state='pending' do nothing;
end;
$$;

create or replace function public.shop_slip_credit_overview(p_shop_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  if p_shop_id is null then
    if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  elsif not reserveflow_private.is_shop_owner(p_shop_id) then
    raise insufficient_privilege;
  end if;
  return jsonb_build_object(
    'offers',(select jsonb_agg(to_jsonb(o) order by o.credits) from reserveflow_private.slip_packs_for_shop(p_shop_id) o),
    'custom_packs_enabled',true,
    'allowance',(select to_jsonb(a)-'period' from reserveflow_private.shop_slip_allowance(p_shop_id) a where p_shop_id is not null),
    'offer',(select to_jsonb(o)-'id' from reserveflow_private.slip_credit_offer o),
    'payments_enabled',(select mobile is not null from reserveflow_private.platform_billing),
    'balance',coalesce((select credits from reserveflow_private.slip_credit_balances where shop_id=p_shop_id),0),
    'orders',coalesce((select jsonb_agg(to_jsonb(o)-'slip'-'transfer_reference' order by o.created_at desc)
      from (select t.*,s.name,t.slip is not null as has_slip
        from reserveflow_private.slip_credit_orders t join public.shops s on s.id=t.shop_id
        where (p_shop_id is null and t.state='pending' and t.slip is not null) or t.shop_id=p_shop_id
        order by (t.state='pending') desc,t.created_at desc limit 100) o),'[]'::jsonb));
end;
$$;

create or replace function public.shop_package_overview(p_shop_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
  return jsonb_build_object(
    'special_access_until',(select access_until from reserveflow_private.shop_special_entitlements where shop_id=p_shop_id),
    'expires_at',(select expires_at from reserveflow_private.shop_subscriptions where shop_id=p_shop_id),
    'orders',coalesce((select jsonb_agg((to_jsonb(o)-'slip') || jsonb_build_object('has_slip',o.slip is not null) order by o.created_at desc) from (
      select * from reserveflow_private.package_orders where shop_id=p_shop_id order by created_at desc limit 10
    ) o),'[]'::jsonb),
    'unpaid_referral',coalesce((select sum(amount) from reserveflow_private.referral_credits where shop_id=p_shop_id and paid_at is null),0));
end;
$$;

revoke all on function public.platform_slip_allowance_settings(),public.save_platform_slip_allowance_settings(integer,integer),
  public.platform_shop_special_entitlement(uuid),public.save_platform_shop_special_entitlement(uuid,integer,date,date,text),
  public.save_custom_slip_credit_pack(text,text,integer,numeric,uuid,boolean) from public,anon,authenticated;
grant execute on function public.platform_slip_allowance_settings() to anon,authenticated;
grant execute on function public.save_platform_slip_allowance_settings(integer,integer),
  public.platform_shop_special_entitlement(uuid),public.save_platform_shop_special_entitlement(uuid,integer,date,date,text),
  public.save_custom_slip_credit_pack(text,text,integer,numeric,uuid,boolean) to authenticated;
notify pgrst,'reload schema';
commit;
