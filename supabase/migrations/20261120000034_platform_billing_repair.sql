begin;

do $$
begin
  if to_regclass('reserveflow_private.slip_credit_packs') is null
    or to_regprocedure('public.save_slip_credit_pack(text,integer,numeric)') is null then
    raise exception 'Run ReserveFlow SQL file 33 in this project before file 34';
  end if;
end;
$$;

alter table reserveflow_private.platform_billing drop constraint if exists platform_billing_mobile_check;
alter table reserveflow_private.platform_billing add constraint platform_billing_mobile_check
  check(mobile ~ '^(0[689][0-9]{8}|[0-9]{13})$');

insert into reserveflow_private.platform_billing(id,prices)
values(true,'{"monthly":299,"quarterly":849,"half_year":1590,"yearly":2990}'::jsonb)
on conflict(id) do update set prices=excluded.prices||platform_billing.prices;

insert into reserveflow_private.slip_credit_offer(credits,amount) values(100,100) on conflict do nothing;
insert into reserveflow_private.slip_credit_packs(code,credits,amount)
values ('standard',500,450),('volume',1000,800) on conflict(code) do nothing;

create or replace function public.save_platform_package_settings(p_mobile text,p_prices jsonb,p_referral numeric)
returns void language plpgsql security definer set search_path=''
as $$
declare proxy text := nullif(regexp_replace(coalesce(p_mobile,''),'[[:space:]-]','','g'),'');
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if proxy is not null and proxy !~ '^(0[689][0-9]{8}|[0-9]{13})$' then
    raise exception using errcode='22023',message='INVALID_PLATFORM_PROMPTPAY';
  end if;
  if p_referral is null or p_referral not between 0 and 100 then
    raise exception using errcode='22023',message='INVALID_PLATFORM_REFERRAL';
  end if;
  if jsonb_typeof(p_prices) is distinct from 'object' then
    raise exception using errcode='22023',message='INVALID_PLATFORM_PRICES';
  end if;
  if exists(select 1 from jsonb_each(p_prices) entry
    where entry.key not in ('monthly','quarterly','half_year','yearly')
      or case when jsonb_typeof(entry.value)='number'
        then (entry.value::text)::numeric not between 1 and 10000000 else true end) then
    raise exception using errcode='22023',message='INVALID_PLATFORM_PRICES';
  end if;
  insert into reserveflow_private.platform_billing(id,mobile,prices,referral_percent)
  values(true,proxy,p_prices,p_referral)
  on conflict(id) do update set mobile=excluded.mobile,prices=excluded.prices,referral_percent=excluded.referral_percent;
end;
$$;

revoke all on function public.save_platform_package_settings(text,jsonb,numeric) from public,anon,authenticated;
grant execute on function public.save_platform_package_settings(text,jsonb,numeric) to authenticated;
notify pgrst,'reload schema';
commit;
