begin;

-- Extend only the existing category, resource and layout editors.
create or replace function public.save_merchant_category(
  p_shop_id uuid, p_code text, p_template text, p_name text,
  p_visible boolean, p_price numeric, p_fee numeric, p_order integer
) returns text
language plpgsql security definer set search_path = ''
as $$
declare
  category_code text;
  previous_template text;
begin
  if not reserveflow_private.is_platform_admin()
    and not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role = 'owner') then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 100
    or p_visible is null or p_price is null or p_price not between 0 and 99999999.99
    or p_fee is null or p_fee not between 0 and 99999999.99
    or p_order is null or p_order not between 0 and 10000 then
    raise exception using errcode = '22023', message = 'INVALID_CATEGORY_SETTINGS';
  end if;
  perform 1 from public.shops where id = p_shop_id for update;
  if p_template is not null and p_template not in ('table','staff','vip','seat','ticket') then
    raise exception using errcode='22023',message='INVALID_CATEGORY_SETTINGS';
  end if;
  if p_code is null then
    if p_template is null then raise invalid_parameter_value; end if;
    category_code := 'cat-' || gen_random_uuid()::text;
    insert into public.categories (shop_id, code, template, name, visible, price, service_fee, sort_order)
    values (p_shop_id, category_code, p_template, btrim(p_name), p_visible, p_price, p_fee, p_order);
    return category_code;
  end if;
  select c.template into previous_template from public.categories c
  where c.shop_id=p_shop_id and c.code=p_code for update;
  if not found then raise exception using errcode='22023',message='INVALID_CATEGORY_SETTINGS'; end if;
  if p_template is not null and p_template<>previous_template and exists (
    select 1 from public.bookings b where b.shop_id=p_shop_id and b.category_code=p_code
  ) then raise exception using errcode='22023',message='CATEGORY_TEMPLATE_HAS_BOOKINGS'; end if;
  update public.categories set template=coalesce(p_template,previous_template), name = btrim(p_name), visible = p_visible, price = p_price,
    service_fee = p_fee, sort_order = p_order
  where shop_id = p_shop_id and code = p_code
  returning code into category_code;
  if not found then raise exception using errcode = '22023', message = 'INVALID_CATEGORY_SETTINGS'; end if;
  return category_code;
end;
$$;

create or replace function public.move_merchant_category(p_shop_id uuid, p_code text, p_direction integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  position integer;
  sorted_codes text[];
  neighbor text;
begin
  if not reserveflow_private.is_platform_admin()
    and not exists (select 1 from public.shop_members
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role = 'owner') then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_direction is null or p_direction not in (-1, 1) then
    raise exception using errcode = '22023', message = 'INVALID_CATEGORY_SETTINGS';
  end if;
  perform 1 from public.shops where id = p_shop_id for update;
  select array_agg(code order by sort_order, code) into sorted_codes
    from public.categories where shop_id = p_shop_id;
  position := array_position(sorted_codes, p_code);
  if position is null then raise exception using errcode = '22023', message = 'INVALID_CATEGORY_SETTINGS'; end if;
  neighbor := sorted_codes[position + p_direction];
  if neighbor is null then return; end if;
  sorted_codes[position + p_direction] := p_code;
  sorted_codes[position] := neighbor;
  update public.categories c set sort_order = ranked.ordinality - 1
  from unnest(sorted_codes) with ordinality as ranked(code, ordinality)
  where c.shop_id = p_shop_id and c.code = ranked.code
    and c.sort_order is distinct from ranked.ordinality - 1;
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
  if not reserveflow_private.is_platform_admin()
    and not exists (select 1 from public.shop_members where shop_id = p_shop_id
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

create or replace function public.archive_merchant_list_resource(p_shop_id uuid,p_category_code text,p_code text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not reserveflow_private.is_platform_admin()
    and not exists (select 1 from public.shop_members where shop_id=p_shop_id
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
  if not reserveflow_private.is_platform_admin()
    and not exists (select 1 from public.shop_members
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
  if not reserveflow_private.is_platform_admin()
    and not exists (select 1 from public.shop_members where shop_id = p_shop_id
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

create function public.platform_shop_support_editors(p_shop_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  if not exists(select 1 from public.shops where id=p_shop_id) then
    raise exception using message='PLATFORM_SHOP_NOT_FOUND';
  end if;
  return jsonb_build_object(
    'categories',coalesce((
      select jsonb_agg(to_jsonb(c) || jsonb_build_object('template_editable',not exists(
        select 1 from public.bookings b where b.shop_id=c.shop_id and b.category_code=c.code))
        order by c.sort_order,c.code)
      from public.categories c where c.shop_id=p_shop_id),'[]'::jsonb),
    'resources',coalesce((
      select jsonb_agg(to_jsonb(r) order by r.code)
      from public.resources r where r.shop_id=p_shop_id),'[]'::jsonb),
    'layouts',coalesce((
      select jsonb_agg(to_jsonb(l) order by l.category_code)
      from public.layouts l where l.shop_id=p_shop_id),'[]'::jsonb));
end;
$$;

create function reserveflow_private.audit_platform_shop_editor()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  entry jsonb;
  target_shop uuid;
begin
  if tg_op='UPDATE' and new is not distinct from old then return null; end if;
  if not reserveflow_private.is_platform_admin() then return null; end if;
  entry := case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
  target_shop := (entry->>'shop_id')::uuid;
  if exists(select 1 from public.shops where id=target_shop) then
    insert into reserveflow_private.platform_shop_support_log(shop_id,actor_id,section,changes)
    values(target_shop,auth.uid(),tg_table_name,jsonb_strip_nulls(jsonb_build_object(
      'action',tg_op,'category',entry->>'category_code','code',entry->>'code')));
  end if;
  return null;
end;
$$;

create trigger audit_platform_category_edit after insert or update or delete on public.categories
for each row execute function reserveflow_private.audit_platform_shop_editor();
create trigger audit_platform_resource_edit after insert or update or delete on public.resources
for each row execute function reserveflow_private.audit_platform_shop_editor();
create trigger audit_platform_layout_edit after insert or update or delete on public.layouts
for each row execute function reserveflow_private.audit_platform_shop_editor();

revoke all on function public.platform_shop_support_editors(uuid),reserveflow_private.audit_platform_shop_editor()
  from public,anon,authenticated;
grant execute on function public.platform_shop_support_editors(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
