begin;

create function public.rf_platform_promotion_offers(p_shop_id uuid)
returns setof public.rf_promotion_offers language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return query select * from public.rf_promotion_offers o where o.shop_id=p_shop_id order by o.hours,o.mode,o.id;
end;
$$;
revoke all on function public.rf_platform_promotion_offers(uuid) from public,anon,authenticated;
grant execute on function public.rf_platform_promotion_offers(uuid) to authenticated;

create or replace function public.rf_save_promotion_offer(
  p_shop_id uuid,p_id uuid,p_name text,p_hours integer,p_mode text,p_price numeric,
  p_gift_name text,p_gift_value numeric,p_active boolean,p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,p_usage_limit integer default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid; gift text := nullif(btrim(p_gift_name),'');
begin
  if not reserveflow_private.is_platform_admin() and not exists(select 1 from public.shop_members where shop_id=p_shop_id and user_id=auth.uid()
    and role in ('owner','admin')) then raise insufficient_privilege; end if;
  if p_hours is null or p_hours not between 1 and 5 or p_mode not in ('gift','discount')
    or (p_mode='gift' and gift is null)
    or (p_mode='discount' and (gift is not null or coalesce(p_gift_value,0)<>0))
    then raise invalid_parameter_value; end if;
  if p_id is null then
    insert into public.rf_promotion_offers(shop_id,name,hours,mode,price,gift_name,gift_value,active,starts_at,ends_at,usage_limit)
      values(p_shop_id,btrim(p_name),p_hours,p_mode,p_price,gift,coalesce(p_gift_value,0),p_active,p_starts_at,p_ends_at,p_usage_limit)
      returning id into result;
  else
    update public.rf_promotion_offers set name=btrim(p_name),hours=p_hours,mode=p_mode,price=p_price,
      gift_name=gift,gift_value=coalesce(p_gift_value,0),active=p_active,starts_at=p_starts_at,ends_at=p_ends_at,usage_limit=p_usage_limit
      where id=p_id and shop_id=p_shop_id returning id into result;
    if not found then raise exception 'PROMOTION_NOT_FOUND'; end if;
  end if;
  if reserveflow_private.is_platform_admin() then
    insert into reserveflow_private.platform_shop_support_log(shop_id,actor_id,section,changes)
    values(p_shop_id,auth.uid(),'promotion',jsonb_build_object('offer',result,'active',p_active,'mode',p_mode));
  end if;
  return result;
end;
$$;

notify pgrst,'reload schema';
commit;
