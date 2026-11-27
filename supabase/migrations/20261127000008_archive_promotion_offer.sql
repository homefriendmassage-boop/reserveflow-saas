begin;

alter table public.rf_promotion_offers
  add column archived_at timestamptz,
  add constraint rf_archived_promotion_inactive check (archived_at is null or not active);

alter policy rf_offers_merchant_read on public.rf_promotion_offers
  using(archived_at is null and exists(
    select 1 from public.shop_members m
    where m.shop_id=rf_promotion_offers.shop_id and m.user_id=(select auth.uid())
  ));

create or replace function public.rf_platform_promotion_offers(p_shop_id uuid)
returns setof public.rf_promotion_offers language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() then raise insufficient_privilege; end if;
  return query select * from public.rf_promotion_offers o
  where o.shop_id=p_shop_id and o.archived_at is null order by o.hours,o.mode,o.id;
end;
$$;

create function public.rf_archive_promotion_offer(p_shop_id uuid,p_offer_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not reserveflow_private.is_platform_admin() and not exists (
    select 1 from public.shop_members
    where shop_id=p_shop_id and user_id=auth.uid() and role in ('owner','admin')
  ) then raise insufficient_privilege; end if;

  -- Preserve the offer referenced by existing quotes, bookings and vouchers.
  update public.rf_promotion_offers set active=false,archived_at=now()
  where id=p_offer_id and shop_id=p_shop_id and archived_at is null;
  if found then
    if reserveflow_private.is_platform_admin() then
      insert into reserveflow_private.platform_shop_support_log(shop_id,actor_id,section,changes)
      values(p_shop_id,auth.uid(),'promotion',jsonb_build_object('offer',p_offer_id,'archived',true));
    end if;
  elsif not exists (
    select 1 from public.rf_promotion_offers where id=p_offer_id and shop_id=p_shop_id
  ) then raise exception 'PROMOTION_NOT_FOUND'; end if;
end;
$$;

revoke all on function public.rf_archive_promotion_offer(uuid,uuid) from public,anon,authenticated;
grant execute on function public.rf_archive_promotion_offer(uuid,uuid) to authenticated;

notify pgrst,'reload schema';
commit;
