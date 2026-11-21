begin;

create table if not exists reserveflow_private.platform_slip_checks (
  kind text not null check(kind in ('subscription','credits')),
  order_id uuid not null,
  lease uuid,
  leased_at timestamptz,
  state text not null default 'checking',
  provider_reference text,
  primary key(kind,order_id)
);

create or replace function reserveflow_private.platform_payment(p_kind text,p_order_id uuid)
returns table(shop_id uuid,amount numeric,receiving_mobile text,created_at timestamptz,state text,slip text)
language sql stable set search_path=''
as $$
  select o.shop_id,o.amount,o.receiving_mobile,o.created_at,o.state,o.slip
  from reserveflow_private.package_orders o where p_kind='subscription' and o.id=p_order_id
  union all
  select o.shop_id,o.amount,o.receiving_mobile,o.created_at,o.state,o.slip
  from reserveflow_private.slip_credit_orders o where p_kind='credits' and o.id=p_order_id;
$$;

create or replace function reserveflow_private.lock_platform_payment(p_kind text,p_order_id uuid)
returns void language plpgsql set search_path=''
as $$
begin
  if p_kind='subscription' then
    perform 1 from reserveflow_private.package_orders where id=p_order_id for update;
  elsif p_kind='credits' then
    perform 1 from reserveflow_private.slip_credit_orders where id=p_order_id for update;
  end if;
end;
$$;

create or replace function reserveflow_private.apply_platform_payment(
  p_kind text,p_order_id uuid,p_approve boolean,p_reference text
) returns void language plpgsql set search_path=''
as $$
declare
  purchase record;
  reference text;
  image_hash text;
  subscription record;
  credit_count integer;
  referrer uuid;
begin
  perform reserveflow_private.lock_platform_payment(p_kind,p_order_id);
  select * into purchase from reserveflow_private.platform_payment(p_kind,p_order_id);
  if not found or purchase.slip is null or p_approve is null then raise invalid_parameter_value; end if;
  if purchase.state=(case when p_approve then 'approved' else 'rejected' end) then return; end if;
  if purchase.state<>'pending' then raise invalid_parameter_value; end if;
  if not p_approve then
    if p_kind='subscription' then
      update reserveflow_private.package_orders set state='rejected' where id=p_order_id;
    else
      update reserveflow_private.slip_credit_orders set state='rejected' where id=p_order_id;
    end if;
    return;
  end if;

  image_hash := encode(sha256(convert_to(purchase.slip,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended('platform-slip-image:'||image_hash,0));
  if exists(select 1 from reserveflow_private.package_orders where state='approved' and slip=purchase.slip)
    or exists(select 1 from reserveflow_private.slip_credit_orders where state='approved' and slip=purchase.slip) then
    raise unique_violation using message='DUPLICATE_PLATFORM_SLIP';
  end if;
  reference := coalesce(
    (select provider_reference from reserveflow_private.platform_slip_checks where kind=p_kind and order_id=p_order_id),
    nullif(btrim(p_reference),''),
    'manual:'||image_hash);
  if length(reference) not between 4 and 200 then raise invalid_parameter_value; end if;
  perform pg_advisory_xact_lock(hashtextextended('payment-reference:'||reference,0));
  if exists(select 1 from reserveflow_private.package_orders where transfer_reference=reference)
    or exists(select 1 from reserveflow_private.slip_credit_orders where transfer_reference=reference)
    or exists(select 1 from public.booking_slip_attachments where thunder_reference=reference) then
    raise unique_violation using message='DUPLICATE_PLATFORM_SLIP';
  end if;

  if p_kind='subscription' then
    update reserveflow_private.package_orders set state='approved',transfer_reference=reference
    where id=p_order_id returning months,referral_percent into subscription;
    insert into reserveflow_private.shop_subscriptions as s(shop_id,expires_at)
    values(purchase.shop_id,now()+make_interval(months=>subscription.months))
    on conflict(shop_id) do update
      set expires_at=greatest(s.expires_at,now())+make_interval(months=>subscription.months)
    returning referrer_shop into referrer;
    if referrer is not null and subscription.referral_percent>0 then
      insert into reserveflow_private.referral_credits(order_id,shop_id,amount)
      values(p_order_id,referrer,round(purchase.amount*subscription.referral_percent/100,2));
    end if;
  else
    update reserveflow_private.slip_credit_orders set state='approved',transfer_reference=reference
    where id=p_order_id returning credits into credit_count;
    insert into reserveflow_private.slip_credit_balances as balance(shop_id,credits)
    values(purchase.shop_id,credit_count)
    on conflict(shop_id) do update set credits=balance.credits+excluded.credits;
  end if;
end;
$$;

create or replace function public.review_package_order(p_order_id uuid,p_approve boolean,p_reference text)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  perform reserveflow_private.apply_platform_payment('subscription',p_order_id,p_approve,p_reference);
end;
$$;

create or replace function public.review_slip_credit_order(p_order_id uuid,p_approve boolean,p_reference text)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  perform reserveflow_private.apply_platform_payment('credits',p_order_id,p_approve,p_reference);
end;
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
  if purchase.state<>'pending' then return jsonb_build_object('state',purchase.state); end if;
  if purchase.slip is null then raise invalid_parameter_value; end if;
  select * into check_row from reserveflow_private.platform_slip_checks where kind=p_kind and order_id=p_order_id;
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

create or replace function public.finish_platform_slip(
  p_kind text,p_order_id uuid,p_lease uuid,p_outcome text,p_reference text,p_amount numeric,
  p_receiver text,p_paid_at timestamptz
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare purchase record; outcome text := p_outcome; verified_reference text;
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
    if p_amount is distinct from purchase.amount then
      outcome := 'amount_review';
    elsif p_receiver is distinct from purchase.receiving_mobile or p_paid_at is null
      or p_paid_at<purchase.created_at or p_paid_at>now()+interval '2 minutes' or verified_reference is null then
      outcome := 'receiver_review';
    else
      begin
        update reserveflow_private.platform_slip_checks set provider_reference=verified_reference
        where kind=p_kind and order_id=p_order_id;
        perform reserveflow_private.apply_platform_payment(p_kind,p_order_id,true,verified_reference);
        outcome := 'approved';
      exception when unique_violation then
        outcome := 'duplicate_review';
      end;
    end if;
  elsif p_outcome is null or p_outcome not in ('qr_unreadable','not_verified','not_configured','thunder_limit','thunder_access','retry') then
    outcome := 'retry';
  end if;
  update reserveflow_private.platform_slip_checks set state=outcome,lease=null,
    provider_reference=coalesce(verified_reference,provider_reference)
  where kind=p_kind and order_id=p_order_id;
  return jsonb_build_object('state',outcome,'amount',p_amount);
end;
$$;

revoke all on function public.claim_platform_slip(text,uuid,uuid),
  public.finish_platform_slip(text,uuid,uuid,text,text,numeric,text,timestamptz) from public,anon,authenticated;
grant execute on function public.claim_platform_slip(text,uuid,uuid),
  public.finish_platform_slip(text,uuid,uuid,text,text,numeric,text,timestamptz) to service_role;
notify pgrst,'reload schema';
commit;
