begin;

alter table public.layouts add column background_image text;

create function public.update_merchant_floor_design(
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
    and code = p_category_code and template in ('table','seat'))
    or jsonb_typeof(positions) <> 'array' or jsonb_array_length(positions) > 1000
    or (p_design ? 'width' and not coalesce((p_design->>'width')::integer between 320 and 1600,false))
    or (p_design ? 'height' and not coalesce((p_design->>'height')::integer between 280 and 1600,false))
    or (image is not null and (length(image) > 960000 or image !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$')) then
    raise exception using errcode = '22023', message = 'INVALID_FLOOR_SETTINGS';
  end if;
  if blocks is not null and (jsonb_typeof(blocks) <> 'array' or jsonb_array_length(blocks) > 100 or exists (
    select 1 from jsonb_array_elements(blocks) b where not coalesce(
      length(b->>'label') between 1 and 80 and (b->>'x')::numeric between 1 and 99
      and (b->>'y')::numeric between 1 and 99 and (b->>'w')::numeric between 20 and 800
      and (b->>'h')::numeric between 20 and 800, false)
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
      length(entry->>'code') between 1 and 100 and (entry->>'x')::numeric between 5 and 95
      and (entry->>'y')::numeric between 5 and 95
      and (entry->>'w')::numeric between 24 and 320 and (entry->>'h')::numeric between 24 and 320, false) then
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
revoke all on function public.update_merchant_floor_design(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.update_merchant_floor_design(uuid,text,jsonb) to authenticated;

create or replace function public.booking_table_plan(
  p_shop_slug text, p_category_code text, p_date date, p_hour integer, p_minute integer
)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  with eligible as (
    select s.id, c.code,
      (p_date + make_time(p_hour, p_minute, 0)) at time zone s.timezone as starts_at
    from public.shops s
    join public.categories c on c.shop_id = s.id
    where s.slug = p_shop_slug and s.public_booking_enabled and c.visible
      and c.code = p_category_code and c.template = 'table'
      and p_hour between 10 and 22 and p_minute in (0, 30)
      and (p_hour < 22 or p_minute = 0)
      and p_date between (statement_timestamp() at time zone s.timezone)::date
                     and (statement_timestamp() at time zone s.timezone)::date + 90
  )
  select jsonb_build_object(
    'width', coalesce(l.width, 960),
    'height', coalesce(l.height, 540),
    'background', l.background_image,
    'decorations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', decoration->>'type', 'label', decoration->>'label', 'x', decoration->'x', 'y', decoration->'y',
        'w', decoration->'w', 'h', decoration->'h'
      ))
      from jsonb_array_elements(case when jsonb_typeof(l.decorations) = 'array'
        then l.decorations else '[]'::jsonb end) decoration
    ), '[]'::jsonb),
    'tables', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', r.code, 'x', r.display->'x', 'y', r.display->'y',
        'w', r.display->'w', 'h', r.display->'h',
        'occupied', exists (
          select 1 from public.bookings b
          where (b.shop_id, b.category_code, b.resource_code) = (r.shop_id, r.category_code, r.code)
            and b.status not in ('cancelled', 'completed')
            and tstzrange(b.starts_at, b.ends_at, '[)') &&
                tstzrange(e.starts_at, e.starts_at + interval '2 hours', '[)')
        )
      ) order by r.code)
      from public.resources r
      where (r.shop_id, r.category_code) = (e.id, e.code)
    ), '[]'::jsonb)
  )
  from eligible e
  left join public.layouts l on (l.shop_id, l.category_code) = (e.id, e.code);
$$;


create or replace function public.booking_resource_plan(
  p_shop_slug text, p_category_code text, p_date date, p_hour integer, p_minute integer, p_hours integer
)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  with eligible as (
    select s.id, c.code, case when c.template = 'seat' then p_hours else 2 end as duration_hours,
      (p_date + make_time(p_hour, p_minute, 0)) at time zone s.timezone as starts_at
    from public.shops s
    join public.categories c on c.shop_id = s.id
    where s.slug = p_shop_slug and s.public_booking_enabled and c.visible
      and c.code = p_category_code and c.template in ('table', 'seat')
      and (c.template = 'table' or p_hours between 1 and 6)
      and p_hour between 10 and 22 and p_minute in (0, 30)
      and (p_hour < 22 or p_minute = 0)
      and p_date between (statement_timestamp() at time zone s.timezone)::date
                     and (statement_timestamp() at time zone s.timezone)::date + 90
  )
  select jsonb_build_object(
    'width', coalesce(l.width, 960),
    'height', coalesce(l.height, 540),
    'background', l.background_image,
    'decorations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', decoration->>'type', 'label', decoration->>'label', 'x', decoration->'x', 'y', decoration->'y',
        'w', decoration->'w', 'h', decoration->'h'
      ))
      from jsonb_array_elements(case when jsonb_typeof(l.decorations) = 'array'
        then l.decorations else '[]'::jsonb end) decoration
    ), '[]'::jsonb),
    'tables', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', r.code, 'x', r.display->'x', 'y', r.display->'y',
        'w', r.display->'w', 'h', r.display->'h',
        'occupied', exists (
          select 1 from public.bookings b
          where (b.shop_id, b.category_code, b.resource_code) = (r.shop_id, r.category_code, r.code)
            and b.status not in ('cancelled', 'completed')
            and tstzrange(b.starts_at, b.ends_at, '[)') &&
                tstzrange(e.starts_at, e.starts_at + make_interval(hours => e.duration_hours), '[)')
        )
      ) order by r.code)
      from public.resources r
      where (r.shop_id, r.category_code) = (e.id, e.code)
    ), '[]'::jsonb)
  )
  from eligible e
  left join public.layouts l on (l.shop_id, l.category_code) = (e.id, e.code);
$$;

commit;
