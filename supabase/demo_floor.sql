-- Optional demo data. Only adds missing tables to the sample shop.
insert into public.resources (shop_id, category_code, code, name, capacity, display)
select s.id, c.code, demo.code, 'โต๊ะ ' || demo.code, demo.capacity,
  jsonb_build_object('x', demo.x, 'y', demo.y, 'w', 84, 'h', 72)
from public.shops s
join public.categories c on c.shop_id = s.id and c.code = 'table' and c.template = 'table'
cross join (values
  ('T02', 4, 50, 30), ('T03', 4, 81, 25), ('T04', 6, 19, 62),
  ('T05', 6, 50, 63), ('T06', 8, 81, 62)
) as demo(code, capacity, x, y)
where s.slug = 'demo-one'
on conflict (shop_id, category_code, code) do nothing;
