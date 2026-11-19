begin;

create function public.save_merchant_category(
  p_shop_id uuid, p_code text, p_template text, p_name text,
  p_visible boolean, p_price numeric, p_fee numeric, p_order integer
) returns text
language plpgsql security definer set search_path = ''
as $$
declare
  category_code text;
begin
  if not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role = 'owner') then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 100
    or p_visible is null or p_price is null or p_price not between 0 and 99999999.99
    or p_fee is null or p_fee not between 0 and 99999999.99
    or p_order is null or p_order not between 0 and 10000 then
    raise exception using errcode = '22023', message = 'INVALID_CATEGORY_SETTINGS';
  end if;
  if p_code is null then
    if p_template is null or p_template not in ('table','staff','vip','seat','ticket') then
      raise exception using errcode = '22023', message = 'INVALID_CATEGORY_SETTINGS';
    end if;
    category_code := 'cat-' || gen_random_uuid()::text;
    insert into public.categories (shop_id, code, template, name, visible, price, service_fee, sort_order)
    values (p_shop_id, category_code, p_template, btrim(p_name), p_visible, p_price, p_fee, p_order);
    return category_code;
  end if;
  update public.categories set name = btrim(p_name), visible = p_visible, price = p_price,
    service_fee = p_fee, sort_order = p_order
  where shop_id = p_shop_id and code = p_code
  returning code into category_code;
  if not found then raise exception using errcode = '22023', message = 'INVALID_CATEGORY_SETTINGS'; end if;
  return category_code;
end;
$$;

create function public.save_merchant_floor_item(
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
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role in ('owner','admin','cashier')) then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if not exists (select 1 from public.categories where shop_id = p_shop_id and code = p_category_code
      and template in ('table','seat'))
    or p_name is null or char_length(btrim(p_name)) not between 1 and 100
    or p_capacity is null or p_capacity not between 1 and 100
    or p_x is null or p_x not between 5 and 95 or p_y is null or p_y not between 5 and 95
    or p_width is null or p_width not between 24 and 320 or p_height is null or p_height not between 24 and 320 then
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

create function public.save_merchant_floor(
  p_shop_id uuid, p_category_code text, p_width integer, p_height integer,
  p_grid boolean, p_decorations jsonb
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role in ('owner','admin','cashier')) then
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

revoke all on function public.save_merchant_category(uuid,text,text,text,boolean,numeric,numeric,integer),
  public.save_merchant_floor_item(uuid,text,text,text,integer,integer,integer,integer,integer),
  public.save_merchant_floor(uuid,text,integer,integer,boolean,jsonb) from public, anon, authenticated;
grant execute on function public.save_merchant_category(uuid,text,text,text,boolean,numeric,numeric,integer),
  public.save_merchant_floor_item(uuid,text,text,text,integer,integer,integer,integer,integer),
  public.save_merchant_floor(uuid,text,integer,integer,boolean,jsonb) to authenticated;

commit;
