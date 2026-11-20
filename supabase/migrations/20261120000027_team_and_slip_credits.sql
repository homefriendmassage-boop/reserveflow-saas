begin;

-- The owner delegates roles. Admins edit the floor and resources. Cashiers handle bookings and payments.

create or replace function public.move_merchant_table(
  p_shop_id uuid, p_category_code text, p_resource_code text, p_x integer, p_y integer
)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role in ('owner', 'admin')) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_x is null or p_y is null or p_x not between 5 and 95 or p_y not between 5 and 95 then
    raise exception using errcode = '22023', message = 'INVALID_TABLE_POSITION';
  end if;
  update public.resources r
    set display = (case when jsonb_typeof(r.display) = 'object' then r.display else '{}'::jsonb end)
      || jsonb_build_object('x', p_x, 'y', p_y)
  from public.categories c
  where (r.shop_id, r.category_code) = (c.shop_id, c.code) and c.template = 'table'
    and r.shop_id = p_shop_id and r.category_code = p_category_code and r.code = p_resource_code;
  if not found then
    raise exception using errcode = '22023', message = 'INVALID_TABLE_POSITION';
  end if;
end;
$$;

create or replace function public.set_merchant_staff_role(p_shop_id uuid, p_user_id uuid, p_role text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role = 'owner') then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_user_id is null or p_role is null or p_role not in ('admin', 'cashier', 'staff', 'remove')
    or not exists (select 1 from auth.users where id = p_user_id) then
    raise exception using errcode = '22023', message = 'INVALID_STAFF_ROLE';
  end if;
  if p_role = 'remove' then
    delete from public.shop_members where shop_id = p_shop_id and user_id = p_user_id and role <> 'owner';
  else
    insert into public.shop_members (shop_id, user_id, role) values (p_shop_id, p_user_id, p_role)
      on conflict (shop_id, user_id) do update set role = excluded.role where shop_members.role <> 'owner';
  end if;
  if not found then
    raise exception using errcode = '22023', message = 'INVALID_STAFF_ROLE';
  end if;
end;
$$;

create or replace function public.review_merchant_team_request(p_shop_id uuid, p_user_id uuid, p_action text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members m
    where m.shop_id = p_shop_id and m.user_id = (select auth.uid()) and m.role = 'owner') then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_action is null or p_action not in ('admin','cashier','staff','reject') then
    raise exception using errcode = '22023', message = 'INVALID_TEAM_REQUEST';
  end if;
  perform 1 from public.shop_team_requests where shop_id = p_shop_id and user_id = p_user_id for update;
  if not found then raise exception using errcode = '22023', message = 'INVALID_TEAM_REQUEST'; end if;
  if p_action <> 'reject' then
    insert into public.shop_members (shop_id, user_id, role, team_name)
      select shop_id, user_id, p_action, requested_name
      from public.shop_team_requests where shop_id = p_shop_id and user_id = p_user_id
      on conflict (shop_id, user_id) do nothing;
  end if;
  delete from public.shop_team_requests where shop_id = p_shop_id and user_id = p_user_id;
end;
$$;

create or replace function public.save_merchant_floor(
  p_shop_id uuid, p_category_code text, p_width integer, p_height integer,
  p_grid boolean, p_decorations jsonb
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role in ('owner', 'admin')) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if not exists (select 1 from public.categories where shop_id = p_shop_id and code = p_category_code
      and template in ('table','seat'))
    or p_width is null or p_width not between 320 and 1600 or p_height is null or p_height not between 280 and 1600
    or p_grid is null or jsonb_typeof(p_decorations) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'INVALID_FLOOR_SETTINGS';
  end if;
  if jsonb_array_length(p_decorations) > 30 or exists (
    select 1 from jsonb_array_elements(p_decorations) d
    where char_length(coalesce(d->>'label','')) not between 1 and 80
      or case when jsonb_typeof(d->'x') = 'number' and jsonb_typeof(d->'y') = 'number'
              and jsonb_typeof(d->'w') = 'number' and jsonb_typeof(d->'h') = 'number'
        then not ((d->>'x')::numeric between 5 and 95 and (d->>'y')::numeric between 5 and 95
          and (d->>'w')::numeric between 24 and 320 and (d->>'h')::numeric between 24 and 320)
        else true end
  ) then
    raise exception using errcode = '22023', message = 'INVALID_FLOOR_SETTINGS';
  end if;
  insert into public.layouts (shop_id,category_code,width,height,aspect,decorations)
  values (p_shop_id,p_category_code,p_width,p_height,'custom',p_decorations)
  on conflict (shop_id,category_code) do update set width = excluded.width, height = excluded.height,
    aspect = excluded.aspect, decorations = excluded.decorations;
  if p_grid then
    with ranked as (
      select code, (row_number() over(order by code) - 1)::integer as idx, count(*) over() as total
      from public.resources where shop_id = p_shop_id and category_code = p_category_code
    )
    update public.resources r set display =
      (case when jsonb_typeof(r.display) = 'object' then r.display else '{}'::jsonb end)
      || jsonb_build_object('x', 17 + (ranked.idx % 3) * 33,
          'y', (ranked.idx / 3 + 1) * 100.0 / (ceil(ranked.total / 3.0) + 1))
    from ranked where r.shop_id = p_shop_id and r.category_code = p_category_code and r.code = ranked.code;
  end if;
end;
$$;

create or replace function public.save_merchant_list_resource(
  p_shop_id uuid, p_category_code text, p_code text, p_name text, p_description text,
  p_position text, p_photo text, p_capacity integer
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  kind text;
  profile jsonb;
begin
  if not exists (select 1 from public.shop_members where shop_id = p_shop_id
    and user_id = (select auth.uid()) and role in ('owner', 'admin')) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  select template into kind from public.categories where shop_id = p_shop_id and code = p_category_code;
  if kind is null or kind not in ('staff','ticket') or not coalesce(length(btrim(p_name)) between 1 and 100,false)
    or length(coalesce(p_description,'')) > 500 or length(coalesce(p_position,'')) > 100
    or (kind = 'ticket' and not coalesce(p_capacity between 1 and 10,false))
    or (p_photo is not null and (length(p_photo) > 480000
      or p_photo !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$')) then
    raise exception using errcode = '22023', message = 'INVALID_RESOURCE';
  end if;
  profile := case when kind = 'staff'
    then jsonb_build_object('position',coalesce(p_position,''),'photo',p_photo) else '{}'::jsonb end;
  if p_code is null then
    insert into public.resources (shop_id,category_code,code,name,description,capacity,display)
    values (p_shop_id,p_category_code,'R-' || gen_random_uuid()::text,btrim(p_name),
      coalesce(p_description,''),case when kind = 'ticket' then p_capacity end,profile);
  else
    update public.resources
    set name=btrim(p_name),description=coalesce(p_description,''),display=display || profile,
      capacity=case when kind = 'ticket' then p_capacity else capacity end
    where shop_id=p_shop_id and category_code=p_category_code and code=p_code;
    if not found then raise exception using errcode = '22023', message = 'INVALID_RESOURCE'; end if;
  end if;
end;
$$;

create or replace function public.save_merchant_floor_item(
  p_shop_id uuid, p_category_code text, p_code text, p_name text, p_capacity integer,
  p_x integer, p_y integer, p_width integer, p_height integer
) returns text
language plpgsql security definer set search_path = ''
as $$
declare
  item_code text;
  geometry jsonb;
begin
  if not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role in ('owner', 'admin')) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if not exists (select 1 from public.categories where shop_id = p_shop_id and code = p_category_code
      and template in ('table','seat','vip'))
    or p_name is null or char_length(btrim(p_name)) not between 1 and 100
    or p_capacity is null or p_capacity not between 1 and 100
    or p_x is null or p_x not between 0 and 100 or p_y is null or p_y not between 0 and 100
    or p_width is null or p_width < 1 or p_height is null or p_height < 1 then
    raise exception using errcode = '22023', message = 'INVALID_TABLE_POSITION';
  end if;
  geometry := jsonb_build_object('x',p_x,'y',p_y,'w',p_width,'h',p_height);
  if p_code is null then
    -- The primary key rejects collisions without overwriting existing resources.
    item_code := 'F-' || left(gen_random_uuid()::text, 8);
    insert into public.resources (shop_id,category_code,code,name,capacity,display)
    values (p_shop_id,p_category_code,item_code,btrim(p_name),p_capacity,geometry);
    return item_code;
  end if;
  update public.resources set name = btrim(p_name), capacity = p_capacity,
    display = (case when jsonb_typeof(display) = 'object' then display else '{}'::jsonb end) || geometry
  where shop_id = p_shop_id and category_code = p_category_code and code = p_code
  returning code into item_code;
  if not found then raise exception using errcode = '22023', message = 'INVALID_TABLE_POSITION'; end if;
  return item_code;
end;
$$;

create or replace function public.update_merchant_floor_design(
  p_shop_id uuid, p_category_code text, p_design jsonb
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  entry jsonb;
  positions jsonb := coalesce(p_design->'items', '[]'::jsonb);
  blocks jsonb := p_design->'decorations';
  image text := p_design->>'background';
begin
  if not exists (select 1 from public.shop_members where shop_id = p_shop_id
    and user_id = (select auth.uid()) and role in ('owner', 'admin')) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if not exists (select 1 from public.categories where shop_id = p_shop_id
    and code = p_category_code and template in ('table','seat','vip'))
    or jsonb_typeof(positions) <> 'array' or jsonb_array_length(positions) > 1000
    or (p_design ? 'width' and not coalesce((p_design->>'width')::integer >= 1,false))
    or (p_design ? 'height' and not coalesce((p_design->>'height')::integer >= 1,false))
    or (image is not null and (length(image) > 960000 or image !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$')) then
    raise exception using errcode = '22023', message = 'INVALID_FLOOR_SETTINGS';
  end if;
  if blocks is not null and (jsonb_typeof(blocks) <> 'array' or jsonb_array_length(blocks) > 100 or exists (
    select 1 from jsonb_array_elements(blocks) b where not coalesce(
      length(b->>'label') between 1 and 80 and (b->>'x')::numeric between 0 and 100
      and (b->>'y')::numeric between 0 and 100 and (b->>'w')::numeric >= 1 and (b->>'w')::numeric < 'Infinity'::numeric
      and (b->>'h')::numeric >= 1 and (b->>'h')::numeric < 'Infinity'::numeric, false)
  )) then
    raise exception using errcode = '22023', message = 'INVALID_FLOOR_SETTINGS';
  end if;

  if p_design ?| array['width','height','decorations','background'] then
    insert into public.layouts as l (shop_id,category_code,width,height,aspect,decorations,background_image)
    values (p_shop_id,p_category_code,coalesce((p_design->>'width')::integer,960),
      coalesce((p_design->>'height')::integer,540),'custom',coalesce(blocks,'[]'),image)
    on conflict (shop_id,category_code) do update set
      width = coalesce((p_design->>'width')::integer,l.width),
      height = coalesce((p_design->>'height')::integer,l.height),
      decorations = coalesce(blocks,l.decorations),
      background_image = case when p_design ? 'background' then image else l.background_image end;
  end if;

  if p_design ? 'remove_item' then
    delete from public.resources
    where shop_id = p_shop_id and category_code = p_category_code and code = p_design->>'remove_item';
  end if;

  for entry in select value from jsonb_array_elements(positions) loop
    if not coalesce(
      length(entry->>'code') between 1 and 100 and (entry->>'x')::numeric between 0 and 100
      and (entry->>'y')::numeric between 0 and 100
      and (entry->>'w')::numeric >= 1 and (entry->>'w')::numeric < 'Infinity'::numeric and (entry->>'h')::numeric >= 1 and (entry->>'h')::numeric < 'Infinity'::numeric, false) then
      raise exception using errcode = '22023', message = 'INVALID_TABLE_POSITION';
    end if;
    entry := entry || jsonb_build_object('x',(entry->>'x')::numeric,'y',(entry->>'y')::numeric,
      'w',(entry->>'w')::numeric,'h',(entry->>'h')::numeric);
    if entry ? 'name' then
      if not coalesce(length(btrim(entry->>'name')) between 1 and 100 and (entry->>'capacity')::integer between 1 and 100,false) then
        raise exception using errcode = '22023', message = 'INVALID_TABLE_POSITION';
      end if;
      insert into public.resources as r (shop_id,category_code,code,name,capacity,display)
      values (p_shop_id,p_category_code,entry->>'code',btrim(entry->>'name'),(entry->>'capacity')::integer,
        jsonb_build_object('x',entry->'x','y',entry->'y','w',entry->'w','h',entry->'h'))
      on conflict (shop_id,category_code,code) do update
      set name = excluded.name, capacity = excluded.capacity, display = r.display || excluded.display;
    else
      update public.resources set display = display || jsonb_build_object('x',entry->'x','y',entry->'y','w',entry->'w','h',entry->'h')
      where shop_id = p_shop_id and category_code = p_category_code and code = entry->>'code';
    end if;
  end loop;
end;
$$;

create or replace function public.archive_merchant_list_resource(p_shop_id uuid,p_category_code text,p_code text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members where shop_id=p_shop_id
    and user_id=(select auth.uid()) and role in ('owner', 'admin')) then
    raise exception using errcode='42501',message='MERCHANT_BOOKING_FORBIDDEN';
  end if;
  update public.resources r set display=r.display || '{"archived":true}'::jsonb
  from public.categories c
  where (c.shop_id,c.code)=(r.shop_id,r.category_code)
    and r.shop_id=p_shop_id and r.category_code=p_category_code and r.code=p_code
    and c.template in ('staff','ticket');
  if not found then raise exception using errcode='22023',message='INVALID_RESOURCE'; end if;
end;
$$;

drop policy if exists read_member_bookings on public.bookings;
create policy read_member_bookings on public.bookings for select to authenticated
  using (shop_id in (select shop_id from public.shop_members where user_id=(select auth.uid())
    and role in ('owner','admin','cashier')));

create or replace function public.list_merchant_bookings(p_shop_id uuid)
returns table(id uuid,category_code text,resource_code text,starts_at timestamptz,ends_at timestamptz,
  customer_name text,amount numeric,status text)
language plpgsql stable security definer set search_path=''
as $$
declare role_name text;
begin
  select role into role_name from public.shop_members
  where shop_id=p_shop_id and user_id=(select auth.uid());
  if role_name is null then raise insufficient_privilege; end if;
  return query select b.id,b.category_code,b.resource_code,b.starts_at,b.ends_at,b.customer_name,
    case when role_name<>'staff' then b.amount end,b.status
  from public.bookings b join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
  where b.shop_id=p_shop_id and (role_name<>'staff' or c.template='table')
  order by b.created_at desc;
end;
$$;
revoke all on function public.list_merchant_bookings(uuid) from public,anon,authenticated;
grant execute on function public.list_merchant_bookings(uuid) to authenticated;

alter table reserveflow_private.platform_billing drop constraint if exists platform_billing_mobile_check;
alter table reserveflow_private.platform_billing add constraint platform_billing_mobile_check
  check(mobile ~ '^(0[689][0-9]{8}|[0-9]{13})$');

create or replace function public.save_platform_package_settings(p_mobile text,p_prices jsonb,p_referral numeric)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if nullif(p_mobile,'') is not null and p_mobile !~ '^(0[689][0-9]{8}|[0-9]{13})$' then raise invalid_parameter_value; end if;
  if jsonb_typeof(p_prices) is distinct from 'object' or p_referral is null or p_referral not between 0 and 100 or exists (
    select 1 from jsonb_each(p_prices) entry
    where entry.key not in ('monthly','quarterly','half_year','yearly') or
      jsonb_typeof(entry.value) <> 'number' or (entry.value::text)::numeric not between 1 and 10000000
  ) then raise invalid_parameter_value; end if;
  update reserveflow_private.platform_billing
    set mobile=nullif(p_mobile,''),prices=p_prices,referral_percent=p_referral;
end;
$$;

create table if not exists reserveflow_private.slip_credit_offer (
  id boolean primary key default true check(id),
  credits integer not null check(credits between 1 and 100000),
  amount numeric(12,2) not null check(amount>0)
);
insert into reserveflow_private.slip_credit_offer(credits,amount) values(100,100) on conflict do nothing;

create table if not exists reserveflow_private.slip_credit_orders (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  credits integer not null,
  amount numeric(12,2) not null,
  receiving_mobile text not null,
  state text not null default 'pending' check(state in ('pending','approved','rejected')),
  slip text,
  transfer_reference text unique,
  created_at timestamptz not null default now()
);
create unique index if not exists slip_credit_pending_order
  on reserveflow_private.slip_credit_orders(shop_id) where state='pending';

create table if not exists reserveflow_private.slip_credit_balances (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  credits bigint not null check(credits>=0)
);
create table if not exists reserveflow_private.slip_credit_usage (
  booking_id uuid primary key references public.bookings(id) on delete cascade
);

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

create or replace function public.save_slip_credit_offer(p_credits integer,p_amount numeric)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if p_credits is null or p_credits not between 1 and 100000 or p_amount is null
    or p_amount not between 0.01 and 9999999999.99 or p_amount<>round(p_amount,2) then
    raise invalid_parameter_value;
  end if;
  update reserveflow_private.slip_credit_offer set credits=p_credits,amount=p_amount;
end;
$$;

create or replace function public.open_slip_credit_order(p_shop_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
  insert into reserveflow_private.slip_credit_orders(shop_id,credits,amount,receiving_mobile)
  select p_shop_id,o.credits,o.amount,b.mobile
  from reserveflow_private.slip_credit_offer o cross join reserveflow_private.platform_billing b
  where b.mobile is not null
  on conflict(shop_id) where state='pending' do nothing;
end;
$$;

create or replace function public.submit_slip_credit_payment(p_order_id uuid,p_image text)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if p_image is null then
    delete from reserveflow_private.slip_credit_orders
    where id=p_order_id and state='pending' and slip is null and reserveflow_private.is_shop_owner(shop_id);
  else
    if length(p_image)>1450000 or p_image !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$' then
      raise invalid_parameter_value;
    end if;
    update reserveflow_private.slip_credit_orders set slip=p_image
    where id=p_order_id and state='pending' and slip is null and reserveflow_private.is_shop_owner(shop_id);
  end if;
  if not found then raise invalid_parameter_value; end if;
end;
$$;

create or replace function public.platform_slip_credit_image(p_order_id uuid)
returns text language plpgsql stable security definer set search_path=''
as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return (select slip from reserveflow_private.slip_credit_orders where id=p_order_id and state='pending');
end;
$$;

create or replace function reserveflow_private.check_slip_credit_reference()
returns trigger language plpgsql security definer set search_path=''
as $$
declare ref text := coalesce(to_jsonb(new)->>'transfer_reference',to_jsonb(new)->>'thunder_reference');
begin
  if ref is null then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended('payment-reference:'||ref,0));
  if tg_table_name='slip_credit_orders' then
    if exists(select 1 from reserveflow_private.package_orders where transfer_reference=ref)
      or exists(select 1 from public.booking_slip_attachments where thunder_reference=ref) then
      raise unique_violation;
    end if;
  elsif exists(select 1 from reserveflow_private.slip_credit_orders where transfer_reference=ref) then
    raise unique_violation;
  end if;
  return new;
end;
$$;

drop trigger if exists slip_credit_reference on reserveflow_private.slip_credit_orders;
create trigger slip_credit_reference before update of transfer_reference on reserveflow_private.slip_credit_orders
for each row execute function reserveflow_private.check_slip_credit_reference();
drop trigger if exists package_slip_credit_reference on reserveflow_private.package_orders;
create trigger package_slip_credit_reference before update of transfer_reference on reserveflow_private.package_orders
for each row execute function reserveflow_private.check_slip_credit_reference();
drop trigger if exists booking_slip_credit_reference on public.booking_slip_attachments;
create trigger booking_slip_credit_reference before update of thunder_reference on public.booking_slip_attachments
for each row execute function reserveflow_private.check_slip_credit_reference();

create or replace function public.review_slip_credit_order(p_order_id uuid,p_approve boolean,p_reference text)
returns void language plpgsql security definer set search_path=''
as $$
declare purchase reserveflow_private.slip_credit_orders%rowtype;
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  select * into purchase from reserveflow_private.slip_credit_orders where id=p_order_id for update;
  if not found or purchase.state<>'pending' or purchase.slip is null or p_approve is null then
    raise invalid_parameter_value;
  end if;
  if not p_approve then
    update reserveflow_private.slip_credit_orders set state='rejected' where id=p_order_id;
    return;
  end if;
  if p_reference is null or length(btrim(p_reference)) not between 4 and 200 then
    raise invalid_parameter_value;
  end if;
  update reserveflow_private.slip_credit_orders
  set state='approved',transfer_reference=btrim(p_reference) where id=p_order_id;
  insert into reserveflow_private.slip_credit_balances as balance(shop_id,credits)
  values(purchase.shop_id,purchase.credits)
  on conflict(shop_id) do update set credits=balance.credits+excluded.credits;
end;
$$;

create or replace function public.consume_booking_slip_credit(p_booking_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare shop uuid;
begin
  select b.shop_id into shop from public.bookings b
  join public.booking_slip_attachments a on a.booking_id=b.id
  where b.id=p_booking_id and a.verification_started_at>now()-interval '1 minute'
    and a.verification_state in ('pending','retry') for update of a;
  if not found then return false; end if;
  if exists(select 1 from reserveflow_private.slip_credit_usage where booking_id=p_booking_id) then
    return true;
  end if;
  update reserveflow_private.slip_credit_balances set credits=credits-1 where shop_id=shop and credits>0;
  if not found then return false; end if;
  insert into reserveflow_private.slip_credit_usage(booking_id) values(p_booking_id);
  return true;
end;
$$;

revoke all on function public.shop_slip_credit_overview(uuid), public.save_slip_credit_offer(integer,numeric),
  public.open_slip_credit_order(uuid), public.submit_slip_credit_payment(uuid,text),
  public.platform_slip_credit_image(uuid), public.review_slip_credit_order(uuid,boolean,text),
  public.consume_booking_slip_credit(uuid) from public,anon,authenticated;
grant execute on function public.shop_slip_credit_overview(uuid), public.save_slip_credit_offer(integer,numeric),
  public.open_slip_credit_order(uuid), public.submit_slip_credit_payment(uuid,text),
  public.platform_slip_credit_image(uuid), public.review_slip_credit_order(uuid,boolean,text) to authenticated;
grant execute on function public.consume_booking_slip_credit(uuid) to service_role;

commit;
