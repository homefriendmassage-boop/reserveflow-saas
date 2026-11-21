begin;

-- Keep unfinished bookings on the current business day's floor after their scheduled end.
-- Scheduled overlaps on future business days continue to use the original time ranges.
create function reserveflow_private.unfinished_booking_holds_slot(
  p_booking public.bookings,p_slot_start timestamptz,p_timezone text
)
returns boolean language sql stable set search_path=''
as $$
  select p_booking.status in ('confirmed','checked_in')
    and p_booking.ends_at<=statement_timestamp()
    and p_slot_start>=p_booking.ends_at
    and (
      (p_booking.status='checked_in' and p_slot_start<=statement_timestamp()+interval '30 minutes')
      or (
        (p_slot_start at time zone p_timezone - interval '6 hours')::date
          = (statement_timestamp() at time zone p_timezone - interval '6 hours')::date
        and (p_booking.status='checked_in' or
          (p_booking.ends_at at time zone p_timezone - interval '6 hours')::date
          = (p_slot_start at time zone p_timezone - interval '6 hours')::date)
      )
    );
$$;

revoke all on function reserveflow_private.unfinished_booking_holds_slot(public.bookings,timestamptz,text)
  from public,anon,authenticated;

create or replace function public.booking_floor_availability(
  p_shop_id uuid,p_category_code text,p_resource_code text,p_start timestamptz,p_end timestamptz
) returns text language sql stable security definer set search_path=''
as $$
  select case
    when exists (select 1 from public.bookings b join public.shops s on s.id=b.shop_id
      where (b.shop_id,b.category_code,b.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and b.status='checked_in' and (
          tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(p_start,p_end,'[)')
          or reserveflow_private.unfinished_booking_holds_slot(b,p_start,s.timezone)
        )) then 'in_use'
    when exists (select 1 from public.bookings b join public.shops s on s.id=b.shop_id
      where (b.shop_id,b.category_code,b.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and b.status='confirmed'
        and (
          tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(p_start,p_end,'[)')
          or reserveflow_private.unfinished_booking_holds_slot(b,p_start,s.timezone)
        )) then 'booked'
    when exists (select 1 from public.bookings b
      where (b.shop_id,b.category_code,b.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and b.review_hold and b.status in ('pending_payment','pending_confirm','slip_review')
        and tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(p_start,p_end,'[)')) then 'review'
    when exists (select 1 from public.bookings b
      where (b.shop_id,b.category_code,b.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and b.status in ('pending_payment','pending_confirm','slip_review')
        and b.created_at > statement_timestamp()-interval '15 minutes'
        and tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(p_start,p_end,'[)')) then 'unpaid'
    when exists (select 1 from public.booking_selection_presence s
      where (s.shop_id,s.category_code,s.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and s.expires_at > statement_timestamp()
        and tstzrange(s.starts_at,s.ends_at,'[)') && tstzrange(p_start,p_end,'[)')) then 'selecting'
    else 'available'
  end;
$$;

create or replace function public.protect_booking_period()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(
    'booking-slot:'||new.shop_id::text||':'||new.category_code||':'||new.resource_code,0));
  if (
    new.status='checked_in' or
    (tg_op='INSERT' and new.starts_at<=statement_timestamp()+interval '30 minutes')
  ) and exists (
    select 1 from public.bookings b
    join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
    where (b.shop_id,b.category_code,b.resource_code)=(new.shop_id,new.category_code,new.resource_code)
      and b.id<>new.id and b.status='checked_in' and c.template in ('table','seat','vip')
  ) then
    raise exception using errcode='23P01',message='BOOKING_RESOURCE_IN_USE';
  end if;
  if tg_op='INSERT' and new.status in ('pending_payment','pending_confirm','slip_review','confirmed','checked_in') and exists (
    select 1
    from public.bookings b
    join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
    join public.shops s on s.id=b.shop_id
    where (b.shop_id,b.category_code,b.resource_code)=(new.shop_id,new.category_code,new.resource_code)
      and b.id<>new.id and c.template in ('table','seat','vip')
      and reserveflow_private.unfinished_booking_holds_slot(b,new.starts_at,s.timezone)
  ) then
    raise exception using errcode='23P01',message='BOOKING_RESOURCE_IN_USE';
  end if;
  if tg_op='INSERT' and new.status in ('pending_payment','pending_confirm','slip_review') and exists (
    select 1 from public.bookings b where (b.shop_id,b.category_code,b.resource_code)
      = (new.shop_id,new.category_code,new.resource_code)
      and (b.status in ('confirmed','checked_in') or
        (b.review_hold and b.status in ('pending_payment','pending_confirm','slip_review')))
      and tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(new.starts_at,new.ends_at,'[)')
  ) then
    raise exception using errcode='23P01',message='BOOKING_SLOT_TAKEN';
  end if;
  return new;
end;
$$;

commit;
