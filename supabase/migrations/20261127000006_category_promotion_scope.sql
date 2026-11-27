begin;

alter table public.rf_promotion_offers add column category_code text;
alter table public.rf_promotion_offers add constraint rf_promotion_category_shop
  foreign key (shop_id,category_code) references public.categories(shop_id,code)
  deferrable initially deferred;
create index rf_promotion_offers_category on public.rf_promotion_offers(shop_id,category_code,hours)
  where active;

create function public.rf_save_category_promotion_offer(
  p_shop_id uuid,p_category_code text,p_id uuid,p_name text,p_hours integer,p_mode text,p_price numeric,
  p_gift_name text,p_gift_value numeric,p_active boolean,p_starts_at timestamptz,p_ends_at timestamptz,p_usage_limit integer
)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  result uuid;
  hourly_rate numeric;
begin
  if not reserveflow_private.is_platform_admin() and not exists(
    select 1 from public.shop_members where shop_id=p_shop_id and user_id=auth.uid()
      and role in ('owner','admin')) then raise insufficient_privilege; end if;
  select price into hourly_rate from public.categories
    where shop_id=p_shop_id and code=p_category_code and template in ('seat','vip','staff');
  if not found then raise exception 'PROMOTION_CATEGORY_REQUIRED'; end if;
  if p_price is null or (p_mode='gift' and p_price<>hourly_rate*p_hours)
    or (p_mode='discount' and p_price>hourly_rate*p_hours) then
    raise exception 'PROMOTION_CATEGORY_PRICE_INVALID';
  end if;
  result:=public.rf_save_promotion_offer(p_shop_id,p_id,p_name,p_hours,p_mode,p_price,p_gift_name,
    p_gift_value,p_active,p_starts_at,p_ends_at,p_usage_limit);
  update public.rf_promotion_offers set category_code=p_category_code where id=result and shop_id=p_shop_id;
  return result;
end;
$$;

revoke all on function public.rf_save_category_promotion_offer(uuid,text,uuid,text,integer,text,numeric,text,numeric,boolean,timestamptz,timestamptz,integer)
  from public,anon,authenticated;
grant execute on function public.rf_save_category_promotion_offer(uuid,text,uuid,text,integer,text,numeric,text,numeric,boolean,timestamptz,timestamptz,integer)
  to authenticated;

create or replace function reserveflow_private.rf_promotion_terms(p_request jsonb,p_quote boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_offer uuid := (p_request->>'offer_id')::uuid;
  v_id uuid := (p_request->>'p_request_id')::uuid;
  v_sha bytea := sha256(convert_to(p_request::text,'UTF8'));
  shop uuid;
  category public.categories%rowtype;
  offer public.rf_promotion_offers%rowtype;
  selection reserveflow_private.rf_promotion_selections%rowtype;
  regular numeric;
  terms jsonb;
begin
  if v_offer is null then return null; end if;
  if v_id is null then raise invalid_parameter_value; end if;
  select id into shop from public.shops where slug=p_request->>'p_shop_slug' and public_booking_enabled;
  select * into category from public.categories where shop_id=shop and code=p_request->>'p_category_code'
    and visible and template in ('seat','vip','staff');
  select * into offer from public.rf_promotion_offers where id=v_offer and shop_id=shop for update;
  if category.shop_id is null or offer.id is null then raise exception 'PROMOTION_UNAVAILABLE'; end if;
  select * into selection from reserveflow_private.rf_promotion_selections where request_id=v_id for update;
  if found then
    if selection.request_hash<>v_sha or selection.offer_id<>v_offer then raise exception 'PROMOTION_QUOTE_MISMATCH'; end if;
    if selection.booking_id is not null or selection.held_until>now() then return selection.terms; end if;
    raise exception 'PROMOTION_QUOTE_EXPIRED';
  end if;
  if not p_quote then raise exception 'PROMOTION_QUOTE_EXPIRED'; end if;
  if exists(select 1 from public.bookings where id=v_id) then raise exception 'PROMOTION_QUOTE_MISMATCH'; end if;
  regular := category.price*offer.hours;
  if (offer.category_code is not null and offer.category_code<>category.code)
    or not offer.active or offer.hours not between 1 and 5
    or offer.hours is distinct from (p_request->>'p_hours')::integer
    or (offer.starts_at is not null and now()<offer.starts_at)
    or (offer.ends_at is not null and now()>=offer.ends_at)
    or (offer.mode='gift' and (offer.price<>regular or nullif(btrim(offer.gift_name),'') is null))
    or (offer.mode='discount' and (offer.price>regular or nullif(btrim(offer.gift_name),'') is not null or offer.gift_value<>0))
    then raise exception 'PROMOTION_UNAVAILABLE'; end if;
  if offer.usage_limit is not null and (
    select count(*) from reserveflow_private.rf_promotion_selections h
    left join public.bookings b on b.id=h.booking_id
    where h.offer_id=offer.id and (h.booking_id is null and h.held_until>now()
      or b.id is not null and b.status<>'cancelled')
  )>=offer.usage_limit then raise exception 'PROMOTION_SOLD_OUT'; end if;
  terms := jsonb_build_object('id',offer.id,'name',offer.name,'mode',offer.mode,'hours',offer.hours,
    'gift',offer.gift_name,'gift_value',offer.gift_value,'price',offer.price,'fee',category.service_fee,
    'regular_rate',category.price,'amount',offer.price+category.service_fee,'held_until',now()+interval '15 minutes');
  insert into reserveflow_private.rf_promotion_selections(request_id,shop_id,offer_id,terms,request_hash,held_until)
  values(v_id,shop,v_offer,terms,v_sha,(terms->>'held_until')::timestamptz)
  on conflict(request_id) do nothing;
  if not found then raise exception 'PROMOTION_QUOTE_MISMATCH'; end if;
  return terms;
end;
$$;

create or replace function public.rf_booking_offers(p_shop_slug text,p_category_code text,p_hours integer)
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'hours',o.hours,
    'mode',o.mode,'price',o.price,'gift',o.gift_name,'gift_value',o.gift_value) order by o.price,o.id),'[]'::jsonb)
  from public.rf_promotion_offers o join public.shops s on s.id=o.shop_id
  join public.categories c on c.shop_id=s.id and c.code=p_category_code
  where s.slug=p_shop_slug and s.public_booking_enabled and reserveflow_private.shop_booking_active(s.id)
    and (o.category_code is null or o.category_code=c.code)
    and c.visible and c.template in ('seat','vip','staff') and o.active and o.hours=p_hours and o.hours between 1 and 5
    and (o.starts_at is null or o.starts_at<=now()) and (o.ends_at is null or o.ends_at>now())
    and (o.mode='gift' and o.price=c.price*o.hours and nullif(btrim(o.gift_name),'') is not null
      or o.mode='discount' and o.price<=c.price*o.hours and nullif(btrim(o.gift_name),'') is null and o.gift_value=0)
    and (o.usage_limit is null or o.usage_limit>(
      select count(*) from reserveflow_private.rf_promotion_selections h
      left join public.bookings b on b.id=h.booking_id where h.offer_id=o.id
        and (h.booking_id is null and h.held_until>now() or b.id is not null and b.status<>'cancelled')));
$$;

notify pgrst,'reload schema';
commit;
