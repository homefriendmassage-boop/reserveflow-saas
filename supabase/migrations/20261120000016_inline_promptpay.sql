begin;

create table public.shop_promptpay (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  mobile text not null check (mobile ~ '^0[689][0-9]{8}$')
);
alter table public.shop_promptpay enable row level security;
revoke all on public.shop_promptpay from public, anon, authenticated;
grant select on public.shop_promptpay to authenticated;
create policy shop_owner_reads_promptpay on public.shop_promptpay for select to authenticated
using (exists (
  select 1 from public.shop_members m where m.shop_id=shop_promptpay.shop_id
    and m.user_id=(select auth.uid()) and m.role='owner'
));

create function public.save_shop_promptpay(p_shop_id uuid,p_mobile text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  mobile text := regexp_replace(coalesce(p_mobile,''),'[[:space:]-]','','g');
begin
  if not exists (select 1 from public.shop_members where shop_id=p_shop_id
    and user_id=(select auth.uid()) and role='owner') then
    raise exception using errcode='42501',message='MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if mobile = '' then
    delete from public.shop_promptpay where shop_id=p_shop_id;
    return;
  end if;
  if mobile !~ '^0[689][0-9]{8}$' then
    raise exception using errcode='22023',message='INVALID_PROMPTPAY_MOBILE';
  end if;
  insert into public.shop_promptpay as p(shop_id,mobile) values(p_shop_id,mobile)
  on conflict(shop_id) do update set mobile=excluded.mobile;
end;
$$;
revoke all on function public.save_shop_promptpay(uuid,text) from public,anon,authenticated;
grant execute on function public.save_shop_promptpay(uuid,text) to authenticated;
create or replace function public.booking_catalog(p_shop_slug text)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'name', s.name,
    'timezone', s.timezone,
    'slip_attachments_enabled', true,
    'promptpay_mobile', (select p.mobile from public.shop_promptpay p where p.shop_id=s.id),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', c.code, 'name', c.name, 'template', c.template,
        'price', c.price, 'service_fee', c.service_fee,
        'resources', coalesce((
          select jsonb_agg(jsonb_build_object(
            'code', r.code, 'name', r.name, 'description', r.description, 'capacity', r.capacity, 'position', r.display->>'position', 'photo', r.display->>'photo'
          ) order by r.code)
          from public.resources r
          where (r.shop_id, r.category_code) = (c.shop_id, c.code) and not (r.display @> '{"archived":true}')
        ), '[]'::jsonb)
      ) order by c.sort_order, c.code)
      from public.categories c
      where c.shop_id = s.id and c.visible
    ), '[]'::jsonb)
  )
  from public.shops s
  where s.slug = p_shop_slug and s.public_booking_enabled;
$$;

commit;
