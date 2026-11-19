-- Remove demo-one fixtures and test references visible in the booking history screenshot.
-- Add other confirmed test UUIDs to this list before running, if needed.
begin;
create temporary table confirmed_demo_test_ids (id uuid primary key) on commit drop;
insert into confirmed_demo_test_ids values
  ('d4302c53-a3fa-4884-9b5a-e277e294c554'),
  ('b66c58fb-f47f-498f-a389-940341c12034'),
  ('ca4c674c-2b45-3682-2c6f-8932ba4c0130'),
  ('9314783c-69af-bb67-8f27-36270b70ba60');
insert into confirmed_demo_test_ids
select md5(s.id::text || seed.category_code || seed.resource_code)::uuid
from public.shops s
cross join (values ('table','T01'),('staff','S01'),('vip','V01'),('seat','A01'),('ticket','E01'))
  as seed(category_code,resource_code)
where s.slug = 'demo-one'
on conflict do nothing;

do $$
begin
  if to_regclass('reserveflow_private.line_outbox') is not null then
    delete from reserveflow_private.line_outbox q
    using public.bookings b, public.shops s, confirmed_demo_test_ids t
    where s.slug = 'demo-one' and b.shop_id = s.id and b.id = t.id
      and q.kind = 'booking' and q.payload->>'booking_id' = b.id::text
      and q.delivered_at is null;
  end if;
end;
$$;

delete from public.bookings b
using public.shops s, confirmed_demo_test_ids t
where s.slug = 'demo-one' and b.shop_id = s.id and b.id = t.id
returning b.id, b.category_code, b.resource_code, b.starts_at;

commit;
