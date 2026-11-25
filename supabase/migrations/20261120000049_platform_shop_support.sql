begin;

create table reserveflow_private.platform_shop_support_log (
  id bigint generated always as identity primary key,
  shop_id uuid not null references public.shops(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  section text not null,
  changes jsonb not null,
  created_at timestamptz not null default statement_timestamp()
);

create function public.platform_shop_support_settings(p_shop_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare settings jsonb;
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  select jsonb_build_object(
    'name',s.name,'slug',s.slug,'open',s.public_booking_enabled,'suspended',s.platform_booking_suspended,
    'line',case when l.shop_id is not null then jsonb_build_object(
      'bot_name',l.bot_name,'friend_id',l.friend_basic_id,'liff_id',l.booking_liff_id) end,
    'categories',coalesce((select jsonb_agg(jsonb_build_object('code',c.code,'name',c.name,'visible',c.visible,
      'price',c.price,'fee',c.service_fee,'sort_order',c.sort_order) order by c.sort_order,c.code)
      from public.categories c where c.shop_id=s.id),'[]'::jsonb)
  ) into settings
  from public.shops s left join reserveflow_private.shop_line_channels l on l.shop_id=s.id
  where s.id=p_shop_id;
  if not found then raise exception using message='PLATFORM_SHOP_NOT_FOUND'; end if;
  return settings;
end;
$$;

create function public.save_platform_shop_support(p_shop_id uuid,p_section text,p_values jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare
  shop public.shops%rowtype;
  v_name text := nullif(btrim(p_values->>'name'),'');
  v_open boolean := (p_values->>'open')::boolean;
  v_visible boolean := (p_values->>'visible')::boolean;
  v_price numeric := (p_values->>'price')::numeric;
  v_fee numeric := (p_values->>'fee')::numeric;
  v_order integer := (p_values->>'sort_order')::integer;
  v_friend text := nullif(btrim(p_values->>'friend_id'),'');
  v_liff text := nullif(btrim(p_values->>'liff_id'),'');
  change_summary jsonb;
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  select * into shop from public.shops where id=p_shop_id for update;
  if not found then raise exception using message='PLATFORM_SHOP_NOT_FOUND'; end if;

  case p_section
  when 'shop' then
    if v_name is null or char_length(v_name)>100 or v_open is null then raise invalid_parameter_value; end if;
    if shop.platform_booking_suspended and v_open then
      raise exception using message='PLATFORM_SHOP_BOOKING_SUSPENDED';
    end if;
    update public.shops set name=v_name,public_booking_enabled=v_open where id=shop.id;
    change_summary:=jsonb_build_object('name',v_name,'open',v_open);
  when 'category' then
    if v_name is null or char_length(v_name)>100 or v_visible is null
      or v_price is null or v_price not between 0 and 99999999.99
      or v_fee is null or v_fee not between 0 and 99999999.99
      or v_order is null or v_order not between 0 and 10000 then raise invalid_parameter_value; end if;
    update public.categories set name=v_name,visible=v_visible,price=v_price,service_fee=v_fee,sort_order=v_order
    where shop_id=shop.id and code=p_values->>'code';
    if not found then raise exception using message='PLATFORM_CATEGORY_NOT_FOUND'; end if;
    change_summary:=jsonb_build_object('code',p_values->>'code','name',v_name,'visible',v_visible,
      'price',v_price,'fee',v_fee,'sort_order',v_order);
  when 'line' then
    if (v_friend is not null and v_friend !~ '^@[A-Za-z0-9._-]{1,49}$')
      or (v_liff is not null and v_liff !~ '^[0-9]{6,20}-[A-Za-z0-9]{4,32}$') then raise invalid_parameter_value; end if;
    update reserveflow_private.shop_line_channels set friend_basic_id=v_friend,booking_liff_id=v_liff
    where shop_id=shop.id;
    if not found then raise exception using message='SHOP_LINE_NOT_CONFIGURED'; end if;
    change_summary:=jsonb_build_object('friend_id',v_friend,'liff_id',v_liff);
  else
    raise invalid_parameter_value;
  end case;
  insert into reserveflow_private.platform_shop_support_log(shop_id,actor_id,section,changes)
    values(shop.id,auth.uid(),p_section,change_summary);
end;
$$;

revoke all on reserveflow_private.platform_shop_support_log from public,anon,authenticated;
revoke all on function public.platform_shop_support_settings(uuid),public.save_platform_shop_support(uuid,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.platform_shop_support_settings(uuid),public.save_platform_shop_support(uuid,text,jsonb)
  to authenticated;
notify pgrst,'reload schema';
commit;
