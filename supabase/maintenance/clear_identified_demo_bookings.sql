-- Remove demo-one fixtures and confirmed test references in one statement.
do $$
declare
  demo_shop uuid;
  test_ids uuid[];
  removed integer;
begin
  select id into demo_shop from public.shops where slug = 'demo-one';
  if demo_shop is null then
    raise notice 'Shop demo-one was not found.';
    return;
  end if;

  test_ids := array[
    'd4302c53-a3fa-4884-9b5a-e277e294c554',
    'b66c58fb-f47f-498f-a389-940341c12034',
    'ca4c674c-2b45-3682-2c6f-8932ba4c0130',
    '9314783c-69af-bb67-8f27-36270b70ba60'
  ]::uuid[] || array(
    select md5(demo_shop::text || seed.category_code || seed.resource_code)::uuid
    from (values ('table','T01'),('staff','S01'),('vip','V01'),('seat','A01'),('ticket','E01'))
      as seed(category_code,resource_code)
  );

  if to_regclass('reserveflow_private.line_outbox') is not null then
    delete from reserveflow_private.line_outbox q
    using public.bookings b
    where b.shop_id = demo_shop and b.id = any(test_ids)
      and q.kind = 'booking' and q.payload->>'booking_id' = b.id::text
      and q.delivered_at is null;
  end if;

  delete from public.bookings b
  where b.shop_id = demo_shop and b.id = any(test_ids);
  get diagnostics removed = row_count;
  raise notice 'Removed % test booking(s) from demo-one.', removed;
end;
$$;
