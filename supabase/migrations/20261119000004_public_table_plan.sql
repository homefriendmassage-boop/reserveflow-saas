begin;

-- Return only public map geometry and occupied resource codes for the selected round.
create function public.booking_table_plan(
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
    'decorations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'label', decoration->>'label', 'x', decoration->'x', 'y', decoration->'y',
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

revoke all on function public.booking_table_plan(text, text, date, integer, integer) from public, anon, authenticated;
grant execute on function public.booking_table_plan(text, text, date, integer, integer) to anon, authenticated;

commit;
