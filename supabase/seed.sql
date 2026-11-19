-- Local development only. No Auth accounts or credentials are created here.
insert into public.shops (id, slug, name, plan) values
  ('10000000-0000-4000-8000-000000000001', 'demo-one', 'ร้าน DEMO', 'Trial'),
  ('10000000-0000-4000-8000-000000000002', 'demo-two', 'ร้านตัวอย่างที่สอง', 'Starter')
on conflict do nothing;

insert into public.categories
  (shop_id, code, name, template, sort_order, price, service_fee, payment_mode, default_status)
select shops.id, demo.*
from public.shops
cross join (values
  ('table', 'จองโต๊ะ', 'table', 1, 200, 0, 'deposit', 'pending_payment'),
  ('staff', 'จองพนักงาน', 'staff', 2, 500, 50, 'full', 'pending_confirm'),
  ('vip', 'จองห้อง', 'vip', 3, 1500, 100, 'deposit', 'pending_payment'),
  ('seat', 'จองที่นั่ง', 'seat', 4, 150, 0, 'full', 'pending_confirm'),
  ('ticket', 'จองบัตร', 'ticket', 5, 900, 20, 'full', 'pending_payment')
) as demo(code, name, template, sort_order, price, service_fee, payment_mode, default_status)
where shops.slug in ('demo-one', 'demo-two')
on conflict do nothing;

insert into public.resources (shop_id, category_code, code, name, capacity, display)
select shop_id, categories.code, demo.code, demo.name, demo.capacity, demo.display::jsonb
from public.categories
join (values
  ('table', 'T01', 'โต๊ะ T01', 4, '{"x":25,"y":30}'),
  ('staff', 'S01', 'พนักงานตัวอย่าง', null, '{}'),
  ('vip', 'V01', 'ห้อง VIP A', 8, '{}'),
  ('seat', 'A01', 'ที่นั่ง A01', 1, '{"x":25,"y":30}'),
  ('ticket', 'E01', 'โซน General', null, '{}')
) as demo(category, code, name, capacity, display)
on categories.code = demo.category
where shop_id in ('10000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002')
on conflict do nothing;

insert into public.layouts (shop_id, category_code, width, height, aspect, decorations)
select shop_id, code, 960, 540, 'wide', '[{"type":"entrance","label":"ทางเข้า","x":10,"y":80,"w":90,"h":40}]'
from public.categories
where code in ('table', 'seat')
and shop_id in ('10000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002')
on conflict do nothing;

insert into public.bookings
  (id, shop_id, category_code, resource_code, starts_at, ends_at, customer_name,
   customer_phone, guests, tickets, amount, status)
select (md5(resources.shop_id::text || category_code || resources.code))::uuid, resources.shop_id, category_code, resources.code,
  ((current_date + 1) + time '18:00') at time zone 'Asia/Bangkok',
  ((current_date + 1) + time '20:00') at time zone 'Asia/Bangkok',
  'ลูกค้าตัวอย่าง', '0800000000', demo.guests, demo.tickets,
  categories.price * demo.quantity + categories.service_fee, 'confirmed'
from public.resources
join public.categories on categories.shop_id = resources.shop_id and categories.code = resources.category_code
join (values
  ('T01', 2, null, 2), ('S01', null, null, 2), ('V01', 4, null, 2),
  ('A01', null, null, 2), ('E01', null, 2, 2)
) as demo(code, guests, tickets, quantity) on resources.code = demo.code
where resources.shop_id in ('10000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002')
on conflict do nothing;
