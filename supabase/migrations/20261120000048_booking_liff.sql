begin;

alter table reserveflow_private.shop_line_channels add column booking_liff_id text;

create function public.save_shop_booking_liff(p_shop_id uuid,p_liff_id text)
returns void language plpgsql security definer set search_path='' as $$
declare liff_id text := nullif(btrim(p_liff_id),'');
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
  if liff_id is not null and liff_id !~ '^[0-9]{6,20}-[A-Za-z0-9]{4,32}$' then
    raise invalid_parameter_value;
  end if;
  update reserveflow_private.shop_line_channels set booking_liff_id=liff_id where shop_id=p_shop_id;
  if not found then raise exception using message='SHOP_LINE_NOT_CONFIGURED'; end if;
end;
$$;

create function public.shop_booking_liff(p_shop_slug text)
returns text language sql stable security definer set search_path='' as $$
  select c.booking_liff_id from reserveflow_private.shop_line_channels c
  join public.shops s on s.id=c.shop_id
  where s.slug=p_shop_slug and s.public_booking_enabled;
$$;

create function public.merchant_booking_liff(p_shop_id uuid)
returns text language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.is_shop_owner(p_shop_id) then raise insufficient_privilege; end if;
  return (select booking_liff_id from reserveflow_private.shop_line_channels where shop_id=p_shop_id);
end;
$$;

create function public.submit_verified_liff_booking(
  p_request jsonb,p_amount numeric,p_image text,p_liff_id text,p_line_user text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  config record;
  saved jsonb;
  booking uuid;
begin
  if not coalesce(p_line_user ~ '^U[0-9a-f]{32}$',false) then raise invalid_parameter_value; end if;
  select s.id,c.bot_id into config from public.shops s
  join reserveflow_private.shop_line_channels c on c.shop_id=s.id
  where s.slug=p_request->>'p_shop_slug' and s.public_booking_enabled and c.booking_liff_id=p_liff_id
  for share of c;
  if not found then raise exception using message='BOOKING_LINE_UNAVAILABLE'; end if;

  saved := public.submit_customer_payment(p_request,p_amount,p_image);
  booking := (saved->>'id')::uuid;
  if not exists(select 1 from public.bookings where id=booking and shop_id=config.id) then
    raise insufficient_privilege;
  end if;
  update reserveflow_private.booking_passes set line_user=p_line_user,line_bot=config.bot_id,line_queued_at=null
  where booking_id=booking and (line_user is null or line_bot is distinct from config.bot_id);
  if not exists(select 1 from reserveflow_private.booking_passes
    where booking_id=booking and line_user=p_line_user and line_bot=config.bot_id) then
    raise exception using message='BOOKING_LINE_ALREADY_LINKED';
  end if;
  perform reserveflow_private.queue_customer_booking_pass(booking);
  return saved || jsonb_build_object('line_linked',true);
end;
$$;

revoke all on function public.save_shop_booking_liff(uuid,text),public.shop_booking_liff(text),
  public.merchant_booking_liff(uuid),public.submit_verified_liff_booking(jsonb,numeric,text,text,text)
  from public,anon,authenticated;
grant execute on function public.save_shop_booking_liff(uuid,text),public.merchant_booking_liff(uuid) to authenticated;
grant execute on function public.shop_booking_liff(text) to anon,authenticated,service_role;
grant execute on function public.submit_verified_liff_booking(jsonb,numeric,text,text,text) to service_role;
notify pgrst,'reload schema';
commit;
