begin;

alter table reserveflow_private.platform_billing add column if not exists bank_holder text;
alter table reserveflow_private.platform_billing add column if not exists bank_account text;
alter table reserveflow_private.package_orders add column if not exists slip_submitted_at timestamptz;
alter table reserveflow_private.slip_credit_orders add column if not exists slip_submitted_at timestamptz;

create or replace function reserveflow_private.stamp_platform_slip_time()
returns trigger language plpgsql set search_path=''
as $$
begin
  if new.slip is not null and old.slip is distinct from new.slip then
    new.slip_submitted_at := statement_timestamp();
  end if;
  return new;
end;
$$;
drop trigger if exists stamp_platform_slip_time on reserveflow_private.package_orders;
create trigger stamp_platform_slip_time before update of slip on reserveflow_private.package_orders
for each row execute function reserveflow_private.stamp_platform_slip_time();
drop trigger if exists stamp_platform_slip_time on reserveflow_private.slip_credit_orders;
create trigger stamp_platform_slip_time before update of slip on reserveflow_private.slip_credit_orders
for each row execute function reserveflow_private.stamp_platform_slip_time();

create or replace function public.platform_payment_recipient()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return (select jsonb_build_object('holder',bank_holder,'account',bank_account)
    from reserveflow_private.platform_billing where id);
end;
$$;

create or replace function public.save_platform_payment_recipient(p_holder text,p_account text)
returns void language plpgsql security definer set search_path=''
as $$
declare
  holder_value text := nullif(btrim(p_holder),'');
  account_value text := nullif(regexp_replace(p_account,'[[:space:]-]','','g'),'');
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if (holder_value is null)<>(account_value is null)
    or length(holder_value)>120 or account_value !~ '^[0-9]{6,20}$' then
    raise exception using errcode='22023',message='INVALID_PLATFORM_RECIPIENT';
  end if;
  update reserveflow_private.platform_billing set bank_holder=holder_value,bank_account=account_value where id;
end;
$$;

create or replace function reserveflow_private.platform_slip_duplicate(p_image text,p_reference text default null)
returns boolean language sql stable set search_path=''
as $$
  select exists(select 1 from reserveflow_private.package_orders
      where state='approved' and (slip=p_image or transfer_reference=p_reference))
    or exists(select 1 from reserveflow_private.slip_credit_orders
      where state='approved' and (slip=p_image or transfer_reference=p_reference))
    or exists(select 1 from public.booking_slip_attachments
      where thunder_reference=p_reference or (image=p_image and thunder_reference is not null));
$$;

create or replace function public.claim_platform_slip(p_kind text,p_order_id uuid,p_actor uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare purchase record; check_row reserveflow_private.platform_slip_checks%rowtype; new_lease uuid;
begin
  perform reserveflow_private.lock_platform_payment(p_kind,p_order_id);
  select * into purchase from reserveflow_private.platform_payment(p_kind,p_order_id);
  if not found or not (
    exists(select 1 from reserveflow_private.platform_admins where user_id=p_actor) or
    exists(select 1 from public.shop_members where shop_id=purchase.shop_id and user_id=p_actor and role='owner')
  ) then raise insufficient_privilege; end if;
  select * into check_row from reserveflow_private.platform_slip_checks where kind=p_kind and order_id=p_order_id;
  if purchase.state<>'pending' then
    return jsonb_build_object('state',coalesce(case when purchase.state='rejected'
      and check_row.state in ('duplicate_rejected','date_rejected','receiver_rejected') then check_row.state end,purchase.state));
  end if;
  if purchase.slip is null then raise invalid_parameter_value; end if;
  if reserveflow_private.platform_slip_duplicate(purchase.slip) then
    perform reserveflow_private.apply_platform_payment(p_kind,p_order_id,false,null);
    insert into reserveflow_private.platform_slip_checks(kind,order_id,state)
    values(p_kind,p_order_id,'duplicate_rejected')
    on conflict(kind,order_id) do update set state=excluded.state,lease=null;
    return jsonb_build_object('state','duplicate_rejected');
  end if;
  if check_row.state='checking' and check_row.leased_at>now()-interval '1 minute' then
    return jsonb_build_object('state','checking');
  end if;
  new_lease := gen_random_uuid();
  insert into reserveflow_private.platform_slip_checks(kind,order_id,lease,leased_at,state)
  values(p_kind,p_order_id,new_lease,now(),'checking') on conflict(kind,order_id)
  do update set lease=excluded.lease,leased_at=excluded.leased_at,state=excluded.state;
  return jsonb_build_object('state','claimed','lease',new_lease,'image',purchase.slip);
end;
$$;

-- Retire the earlier service function so an older Edge revision cannot approve without both recipient fields.
drop function if exists public.finish_platform_slip(text,uuid,uuid,text,text,numeric,text,timestamptz);

create or replace function public.finish_platform_slip(
  p_kind text,p_order_id uuid,p_lease uuid,p_outcome text,p_reference text,p_amount numeric,
  p_receiver text,p_paid_at timestamptz,p_holder text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  purchase record;
  billing record;
  submitted_at timestamptz;
  outcome text := p_outcome;
  verified_reference text;
  supplied_holder text := nullif(lower(regexp_replace(btrim(p_holder),'[[:space:]]+',' ','g')),'');
  supplied_account text := regexp_replace(p_receiver,'[[:space:]-]','','g');
begin
  perform reserveflow_private.lock_platform_payment(p_kind,p_order_id);
  select * into purchase from reserveflow_private.platform_payment(p_kind,p_order_id);
  if not found then raise invalid_parameter_value; end if;
  if purchase.state<>'pending' then return jsonb_build_object('state',purchase.state); end if;
  if not exists(select 1 from reserveflow_private.platform_slip_checks
    where kind=p_kind and order_id=p_order_id and lease=p_lease and state='checking') then
    return jsonb_build_object('state','checking');
  end if;
  if p_outcome='provider_verified' then
    if p_reference is not null and length(btrim(p_reference)) between 4 and 200 then
      verified_reference := btrim(p_reference);
    end if;
    select bank_holder,bank_account into billing from reserveflow_private.platform_billing where id for share;
    if p_kind='subscription' then
      select slip_submitted_at into submitted_at from reserveflow_private.package_orders where id=p_order_id;
    else
      select slip_submitted_at into submitted_at from reserveflow_private.slip_credit_orders where id=p_order_id;
    end if;
    if reserveflow_private.platform_slip_duplicate(purchase.slip,verified_reference) then
      outcome := 'duplicate_rejected';
    elsif p_paid_at is not null and (
      (p_paid_at at time zone 'Asia/Bangkok')::date<>(coalesce(submitted_at,purchase.created_at) at time zone 'Asia/Bangkok')::date
      or p_paid_at>now()+interval '2 minutes'
    ) then
      outcome := 'date_rejected';
    elsif billing.bank_account is not null and billing.bank_holder is not null
      and supplied_account ~ '^[0-9]{6,20}$' and supplied_holder is not null
      and (supplied_account<>billing.bank_account
        or supplied_holder<>lower(regexp_replace(btrim(billing.bank_holder),'[[:space:]]+',' ','g'))) then
      outcome := 'receiver_rejected';
    elsif p_amount is distinct from purchase.amount then
      outcome := 'amount_review';
    elsif billing.bank_account is null or billing.bank_holder is null or supplied_account is null
      or supplied_account !~ '^[0-9]{6,20}$' or supplied_holder is null
      or p_paid_at is null or verified_reference is null then
      outcome := 'receiver_review';
    else
      begin
        update reserveflow_private.platform_slip_checks set provider_reference=verified_reference
        where kind=p_kind and order_id=p_order_id;
        perform reserveflow_private.apply_platform_payment(p_kind,p_order_id,true,verified_reference);
        outcome := 'approved';
      exception when unique_violation then
        outcome := 'duplicate_rejected';
      end;
    end if;
  elsif p_outcome is null or p_outcome not in ('qr_unreadable','not_verified','not_configured','thunder_limit','thunder_access','retry') then
    outcome := 'retry';
  end if;
  if outcome in ('duplicate_rejected','date_rejected','receiver_rejected') then
    perform reserveflow_private.apply_platform_payment(p_kind,p_order_id,false,null);
  end if;
  update reserveflow_private.platform_slip_checks set state=outcome,lease=null,
    provider_reference=coalesce(verified_reference,provider_reference)
  where kind=p_kind and order_id=p_order_id;
  return jsonb_build_object('state',outcome,'amount',p_amount);
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
      from (select t.*,s.name,t.slip is not null as has_slip,
        (select v.state from reserveflow_private.platform_slip_checks v where v.kind='credits' and v.order_id=t.id) as slip_status
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
    'orders',coalesce((select jsonb_agg((to_jsonb(o)-'slip') || jsonb_build_object('has_slip',o.slip is not null,'slip_status',
      (select v.state from reserveflow_private.platform_slip_checks v where v.kind='subscription' and v.order_id=o.id)) order by o.created_at desc) from (
      select * from reserveflow_private.package_orders where shop_id=p_shop_id order by created_at desc limit 10
    ) o),'[]'::jsonb),
    'unpaid_referral',coalesce((select sum(amount) from reserveflow_private.referral_credits where shop_id=p_shop_id and paid_at is null),0));
end;
$$;

create or replace function public.review_package_order(p_order_id uuid,p_approve boolean,p_reference text)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if p_approve and not exists(select 1 from reserveflow_private.platform_billing
    where id and bank_holder is not null and bank_account is not null) then
    raise exception using errcode='22023',message='PLATFORM_RECIPIENT_REQUIRED';
  end if;
  perform reserveflow_private.apply_platform_payment('subscription',p_order_id,p_approve,p_reference);
end;
$$;

create or replace function public.review_slip_credit_order(p_order_id uuid,p_approve boolean,p_reference text)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if p_approve and not exists(select 1 from reserveflow_private.platform_billing
    where id and bank_holder is not null and bank_account is not null) then
    raise exception using errcode='22023',message='PLATFORM_RECIPIENT_REQUIRED';
  end if;
  perform reserveflow_private.apply_platform_payment('credits',p_order_id,p_approve,p_reference);
end;
$$;

revoke all on function public.platform_payment_recipient(),public.save_platform_payment_recipient(text,text),
  public.finish_platform_slip(text,uuid,uuid,text,text,numeric,text,timestamptz,text) from public,anon,authenticated;
grant execute on function public.platform_payment_recipient(),public.save_platform_payment_recipient(text,text) to authenticated;
grant execute on function public.finish_platform_slip(text,uuid,uuid,text,text,numeric,text,timestamptz,text) to service_role;
notify pgrst,'reload schema';
commit;
