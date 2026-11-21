begin;

create or replace function public.save_slip_credit_pack(p_code text,p_credits integer,p_amount numeric)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if p_credits is null or p_credits not between 1 and 100000 or p_amount is null
    or p_amount not between 0.01 and 9999999999.99 or p_amount<>round(p_amount,2) then
    raise exception using errcode='22023',message='INVALID_SLIP_PACK_PRICE';
  end if;
  if p_code='starter' then
    insert into reserveflow_private.slip_credit_offer(id,credits,amount) values(true,p_credits,p_amount)
    on conflict(id) do update set credits=excluded.credits,amount=excluded.amount;
    return;
  end if;
  update reserveflow_private.slip_credit_packs set credits=p_credits,amount=p_amount where code=p_code;
  if not found then raise exception using errcode='22023',message='SLIP_PACK_NOT_FOUND'; end if;
end;
$$;

create table if not exists reserveflow_private.referral_share_settings (
  id boolean primary key default true check(id),
  liff_id text check(liff_id ~ '^[0-9]{6,16}-[A-Za-z0-9]{4,24}$')
);

create or replace function public.platform_referral_share_liff()
returns text language sql stable security definer set search_path=''
as $$
  select liff_id from reserveflow_private.referral_share_settings where id;
$$;

create or replace function public.save_platform_referral_share_liff(p_liff_id text)
returns void language plpgsql security definer set search_path=''
as $$
declare configured text := nullif(btrim(p_liff_id),'');
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if configured is not null and configured !~ '^[0-9]{6,16}-[A-Za-z0-9]{4,24}$' then
    raise exception using errcode='22023',message='INVALID_REFERRAL_LIFF';
  end if;
  insert into reserveflow_private.referral_share_settings(id,liff_id) values(true,configured)
  on conflict(id) do update set liff_id=excluded.liff_id;
end;
$$;

revoke all on function public.platform_referral_share_liff(), public.save_platform_referral_share_liff(text) from public,anon,authenticated;
grant execute on function public.platform_referral_share_liff() to anon,authenticated;
grant execute on function public.save_platform_referral_share_liff(text) to authenticated;
notify pgrst,'reload schema';

commit;
