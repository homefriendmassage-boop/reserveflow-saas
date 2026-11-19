begin;

-- The caller supplies a shop name and URL slug. The owner always comes from Auth.
create function public.register_merchant_shop(p_name text, p_slug text)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  account_id uuid := auth.uid();
  new_shop_id uuid;
  requested_slug text := lower(btrim(p_slug));
begin
  if account_id is null then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 100
    or requested_slug is null or requested_slug !~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' then
    raise exception using errcode = '22023', message = 'INVALID_SHOP_REGISTRATION';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('shop-registration:' || account_id::text, 0));
  select s.id into new_shop_id from public.shops s
    join public.shop_members m on m.shop_id = s.id
    where s.slug = requested_slug and m.user_id = account_id and m.role = 'owner';
  if found then return new_shop_id; end if;

  -- One self-serve onboarding per account. Team members cannot create a shop from this screen.
  if exists (select 1 from public.shop_members where user_id = account_id) then
    raise exception using errcode = '22023', message = 'SHOP_MEMBERSHIP_EXISTS';
  end if;

  insert into public.shops (name, slug)
  values (btrim(p_name), requested_slug)
  on conflict (slug) do nothing
  returning id into new_shop_id;
  if not found then
    raise exception using errcode = '23505', message = 'SHOP_SLUG_TAKEN';
  end if;

  insert into public.shop_members (shop_id, user_id, role) values (new_shop_id, account_id, 'owner');
  insert into public.categories (shop_id, code, name, template, sort_order) values
    (new_shop_id, 'table', 'จองโต๊ะ', 'table', 0);
  insert into public.resources (shop_id, category_code, code, name, capacity, display) values
    (new_shop_id, 'table', 'T01', 'โต๊ะ T01', 4, '{"x":50,"y":40,"w":84,"h":72}');
  insert into public.layouts (shop_id, category_code, width, height, aspect) values
    (new_shop_id, 'table', 540, 720, 'portrait');
  return new_shop_id;
end;
$$;

revoke all on function public.register_merchant_shop(text,text) from public, anon, authenticated;
grant execute on function public.register_merchant_shop(text,text) to authenticated;

commit;
