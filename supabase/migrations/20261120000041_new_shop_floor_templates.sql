begin;

create or replace function public.register_merchant_shop(p_name text, p_slug text)
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
  insert into public.resources (shop_id,category_code,code,name,capacity,display)
  select new_shop_id,'table',r.code,'โต๊ะ '||r.code,r.capacity,
    jsonb_build_object('x',r.x,'y',r.y,'w',84,'h',72)
  from (values
    ('T01',20,33.33,2),('T02',40,33.33,4),('T03',60,33.33,4),
    ('T04',80,33.33,6),('T05',20,66.67,6),('T06',40,66.67,8)
  ) r(code,x,y,capacity);
  insert into public.layouts (shop_id,category_code,width,height,aspect,decorations)
  values(new_shop_id,'table',960,540,'wide',
    '[{"type":"entrance","label":"ทางเข้า","x":10,"y":82,"w":90,"h":40}]'::jsonb);
  return new_shop_id;
end;
$$;

commit;
