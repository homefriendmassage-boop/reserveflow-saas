begin;

create or replace function reserveflow_private.register_owned_shop(p_name text,p_slug text,p_additional boolean,p_plan text)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  account_id uuid := auth.uid();
  new_shop_id uuid;
  requested_slug text := lower(btrim(p_slug));
begin
  if account_id is null then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 100
    or requested_slug is null or requested_slug !~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' then
    raise exception using errcode = '22023', message = 'INVALID_SHOP_REGISTRATION';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('shop-registration:' || account_id::text, 0));
  select s.id into new_shop_id from public.shops s
    join public.shop_members m on m.shop_id = s.id
    where s.slug = requested_slug and m.user_id = account_id and m.role = 'owner';
  if found then return new_shop_id; end if;

  if p_additional then
    if not reserveflow_private.is_platform_admin()
      and not exists(select 1 from public.shop_members where user_id=account_id and role='owner') then
      raise exception using errcode='42501',message='SHOP_OWNER_REQUIRED';
    end if;
  elsif exists(select 1 from public.shop_members where user_id=account_id) then
    raise exception using errcode='22023',message='SHOP_MEMBERSHIP_EXISTS';
  end if;

  insert into public.shops (name, slug)
  values (btrim(p_name), requested_slug)
  on conflict (slug) do nothing
  returning id into new_shop_id;
  if not found then
    raise exception using errcode = '23505', message = 'SHOP_SLUG_TAKEN';
  end if;

  insert into public.shop_members (shop_id, user_id, role) values (new_shop_id, account_id, 'owner');
  insert into public.categories (shop_id, code, name, template, sort_order) values
    (new_shop_id, 'table', 'จองโต๊ะ', 'table', 0);
  insert into public.resources (shop_id,category_code,code,name,capacity,display)
  select new_shop_id,'table',r.code,'โต๊ะ '||r.code,r.capacity,
    jsonb_build_object('x',r.x,'y',r.y,'w',84,'h',72)
  from (values
    ('T01',20,33.33,2),('T02',40,33.33,4),('T03',60,33.33,4),
    ('T04',80,33.33,6),('T05',20,66.67,6),('T06',40,66.67,8)
  ) r(code,x,y,capacity);
  insert into public.layouts (shop_id,category_code,width,height,aspect,decorations)
  values(new_shop_id,'table',960,540,'wide',
    '[{"type":"entrance","label":"ทางเข้า","x":10,"y":82,"w":90,"h":40}]'::jsonb);
  if p_additional and p_plan is not null then perform public.open_package_order(new_shop_id,p_plan); end if;
  return new_shop_id;
end;
$$;

alter table public.shops add column platform_booking_suspended boolean not null default false;

create function reserveflow_private.enforce_shop_booking_suspension()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.platform_booking_suspended and new.public_booking_enabled then
    raise exception using message='PLATFORM_SHOP_BOOKING_SUSPENDED';
  end if;
  return new;
end;
$$;

create trigger enforce_shop_booking_suspension
before update on public.shops for each row
execute function reserveflow_private.enforce_shop_booking_suspension();

drop function public.platform_shop_overview();
create function public.platform_shop_overview()
returns table (shop_id uuid, slug text, name text, public_booking_enabled boolean, created_at timestamptz, staff_count bigint, platform_booking_suspended boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not exists (select 1 from reserveflow_private.platform_admins where user_id = (select auth.uid())) then
    raise exception using errcode = '42501', message = 'PLATFORM_ADMIN_REQUIRED';
  end if;
  return query select s.id,s.slug,s.name,s.public_booking_enabled,s.created_at,
    (select count(*) from public.shop_members m where m.shop_id = s.id), s.platform_booking_suspended
  from public.shops s order by s.created_at desc, s.id;
end;
$$;

create function public.set_platform_shop_booking(p_shop_id uuid,p_enabled boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if p_enabled is null then raise invalid_parameter_value; end if;
  update public.shops set platform_booking_suspended=not p_enabled,public_booking_enabled=p_enabled
    where id=p_shop_id;
  if not found then raise exception using message='PLATFORM_SHOP_NOT_FOUND'; end if;
end;
$$;

-- Keep only fingerprints of accepted transfers so deletion cannot make them reusable.
create table reserveflow_private.deleted_shop_payment_fingerprints (
  kind text not null,
  fingerprint bytea not null,
  primary key(kind,fingerprint)
);

create function reserveflow_private.prevent_deleted_shop_payment_reuse()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  payment jsonb := to_jsonb(new);
begin
  if exists(select 1 from reserveflow_private.deleted_shop_payment_fingerprints
    where (kind='reference' and fingerprint=sha256(convert_to(coalesce(payment->>'transfer_reference',payment->>'thunder_reference'),'UTF8')))
       or (kind='image' and fingerprint=sha256(convert_to(coalesce(payment->>'slip',payment->>'image'),'UTF8')))) then
    raise unique_violation;
  end if;
  return new;
end;
$$;

create trigger reject_deleted_shop_payment before update of state,transfer_reference
on reserveflow_private.package_orders for each row when (new.state='approved')
execute function reserveflow_private.prevent_deleted_shop_payment_reuse();
create trigger reject_deleted_shop_payment before update of state,transfer_reference
on reserveflow_private.slip_credit_orders for each row when (new.state='approved')
execute function reserveflow_private.prevent_deleted_shop_payment_reuse();
create trigger reject_deleted_shop_payment before update of thunder_reference
on public.booking_slip_attachments for each row when (new.thunder_reference is not null)
execute function reserveflow_private.prevent_deleted_shop_payment_reuse();

create function public.delete_platform_shop(p_shop_id uuid,p_confirm_slug text)
returns void language plpgsql security definer set search_path='' as $$
declare
  shop public.shops%rowtype;
  line_secret uuid;
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  perform pg_advisory_xact_lock(hashtextextended('line-pairing:'||p_shop_id::text,0));
  select * into shop from public.shops where id=p_shop_id for update;
  if not found then raise exception using message='PLATFORM_SHOP_NOT_FOUND'; end if;
  if not shop.platform_booking_suspended then raise exception using message='PLATFORM_SHOP_CLOSE_FIRST'; end if;
  if p_confirm_slug is distinct from shop.slug then raise exception using message='PLATFORM_SHOP_CONFIRM_SLUG'; end if;

  perform 1 from reserveflow_private.package_orders where shop_id=shop.id for update;
  perform 1 from reserveflow_private.slip_credit_orders where shop_id=shop.id for update;
  perform 1 from public.bookings where shop_id=shop.id for update;
  perform 1 from public.booking_slip_attachments a join public.bookings b on b.id=a.booking_id
    where b.shop_id=shop.id for update of a;

  insert into reserveflow_private.deleted_shop_payment_fingerprints(kind,fingerprint)
  select f.kind,sha256(convert_to(f.value,'UTF8'))
  from (
    select transfer_reference as reference,slip as image from reserveflow_private.package_orders where shop_id=shop.id and state='approved'
    union all select transfer_reference,slip from reserveflow_private.slip_credit_orders where shop_id=shop.id and state='approved'
    union all select a.thunder_reference,a.image from public.booking_slip_attachments a join public.bookings b on b.id=a.booking_id
      where b.shop_id=shop.id and a.thunder_reference is not null
  ) payment cross join lateral (values ('reference',payment.reference),('image',payment.image)) f(kind,value)
  where f.value is not null on conflict do nothing;

  delete from reserveflow_private.referral_credits c where c.shop_id=shop.id
    or exists(select 1 from reserveflow_private.package_orders o where o.id=c.order_id and o.shop_id=shop.id);
  if to_regclass('reserveflow_private.platform_slip_checks') is not null then
    delete from reserveflow_private.platform_slip_checks c where
      (c.kind='subscription' and exists(select 1 from reserveflow_private.package_orders o where o.id=c.order_id and o.shop_id=shop.id))
      or (c.kind='credits' and exists(select 1 from reserveflow_private.slip_credit_orders o where o.id=c.order_id and o.shop_id=shop.id));
  end if;
  delete from reserveflow_private.booking_payment_quotes where shop_slug=shop.slug;
  delete from public.bookings where shop_id=shop.id;
  delete from reserveflow_private.line_pairing where owner_scope=shop.id::text;
  delete from reserveflow_private.line_targets where owner_scope=shop.id::text;
  delete from reserveflow_private.line_outbox where kind='shop' and payload->>'slug'=shop.slug;
  select secret_id into line_secret from reserveflow_private.shop_line_channels where shop_id=shop.id;
  delete from public.shops where id=shop.id;
  if line_secret is not null then delete from vault.secrets where id=line_secret; end if;
end;
$$;

revoke all on function public.platform_shop_overview(),public.set_platform_shop_booking(uuid,boolean),
  public.delete_platform_shop(uuid,text) from public,anon,authenticated;
grant execute on function public.platform_shop_overview(),public.set_platform_shop_booking(uuid,boolean),
  public.delete_platform_shop(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
