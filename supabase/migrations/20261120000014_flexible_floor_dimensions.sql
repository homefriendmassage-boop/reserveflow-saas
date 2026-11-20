begin;

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
    where shop_id = p_shop_id and user_id = (select auth.uid()) and role in ('owner','admin','cashier')) then
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
    and user_id = (select auth.uid()) and role in ('owner','admin','cashier')) then
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

commit;
