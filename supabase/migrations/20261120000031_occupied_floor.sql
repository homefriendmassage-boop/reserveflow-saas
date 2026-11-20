begin;

create index if not exists booking_active_resource
  on public.bookings(shop_id,category_code,resource_code) where status='checked_in';

-- An active check-in holds the current and upcoming half-hour slot after the booked time. Future slots retain their schedule.

create or replace function public.booking_floor_availability(
  p_shop_id uuid,p_category_code text,p_resource_code text,p_start timestamptz,p_end timestamptz
) returns text language sql stable security definer set search_path=''
as $$
  select case
    when exists (select 1 from public.bookings b
      where (b.shop_id,b.category_code,b.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and b.status='checked_in' and b.starts_at<p_end
        and (p_start<b.ends_at or p_start<=statement_timestamp()+interval '30 minutes')) then 'in_use'
    when exists (select 1 from public.bookings b
      where (b.shop_id,b.category_code,b.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and b.status='confirmed'
        and tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(p_start,p_end,'[)')) then 'booked'
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

create or replace function public.booking_table_plan(
  p_shop_slug text, p_category_code text, p_date date, p_hour integer, p_minute integer
)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  with eligible as (
    select s.id, c.code,
      (p_date + make_time(p_hour, p_minute, 0)) at time zone s.timezone as starts_at
    from public.shops s
    join public.categories c on c.shop_id = s.id
    where s.slug = p_shop_slug and s.public_booking_enabled and c.visible
      and c.code = p_category_code and c.template = 'table'
      and p_hour between 0 and 23 and p_minute in (0, 30)
      and (p_date + make_time(p_hour,p_minute,0) - interval '6 hours')::date between
        ((statement_timestamp() at time zone s.timezone)-interval '6 hours')::date
        and ((statement_timestamp() at time zone s.timezone)-interval '6 hours')::date + 90
  )
  select jsonb_build_object(
    'width', coalesce(l.width, 960),
    'height', coalesce(l.height, 540),
    'background', l.background_image,
    'decorations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', decoration->>'type', 'label', decoration->>'label', 'x', decoration->'x', 'y', decoration->'y',
        'w', decoration->'w', 'h', decoration->'h'
      ))
      from jsonb_array_elements(case when jsonb_typeof(l.decorations) = 'array'
        then l.decorations else '[]'::jsonb end) decoration
    ), '[]'::jsonb),
    'tables', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', r.code, 'x', r.display->'x', 'y', r.display->'y',
        'w', r.display->'w', 'h', r.display->'h',
        'occupied', availability.state in ('booked','review','in_use'), 'availability', availability.state
      ) order by r.code)
      from public.resources r
      cross join lateral (
        select public.booking_floor_availability(r.shop_id,r.category_code,r.code,e.starts_at,e.starts_at + interval '2 hours') as state
      ) availability
      where (r.shop_id, r.category_code) = (e.id, e.code)
    ), '[]'::jsonb)
  )
  from eligible e
  left join public.layouts l on (l.shop_id, l.category_code) = (e.id, e.code);
$$;

create or replace function public.booking_resource_plan(
  p_shop_slug text, p_category_code text, p_date date, p_hour integer, p_minute integer, p_hours integer
)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  with eligible as (
    select s.id, c.code, coalesce(p_hours,2) as duration_hours,
      (p_date + make_time(p_hour, p_minute, 0)) at time zone s.timezone as starts_at
    from public.shops s
    join public.categories c on c.shop_id = s.id
    where s.slug = p_shop_slug and s.public_booking_enabled and c.visible
      and c.code = p_category_code and c.template in ('table', 'seat', 'vip')
      and ((c.template = 'table' and coalesce(p_hours,2) between 1 and 5) or (c.template = 'seat' and p_hours between 1 and 6)
        or (c.template = 'vip' and p_hours between 1 and 5))
      and p_hour between 0 and 23 and p_minute in (0, 30)
      and (p_date + make_time(p_hour,p_minute,0) - interval '6 hours')::date between
        ((statement_timestamp() at time zone s.timezone)-interval '6 hours')::date
        and ((statement_timestamp() at time zone s.timezone)-interval '6 hours')::date + 90
  )
  select jsonb_build_object(
    'width', coalesce(l.width, 960),
    'height', coalesce(l.height, 540),
    'background', l.background_image,
    'decorations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', decoration->>'type', 'label', decoration->>'label', 'x', decoration->'x', 'y', decoration->'y',
        'w', decoration->'w', 'h', decoration->'h'
      ))
      from jsonb_array_elements(case when jsonb_typeof(l.decorations) = 'array'
        then l.decorations else '[]'::jsonb end) decoration
    ), '[]'::jsonb),
    'tables', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', r.code, 'x', r.display->'x', 'y', r.display->'y',
        'w', r.display->'w', 'h', r.display->'h',
        'occupied', availability.state in ('booked','review','in_use'), 'availability', availability.state
      ) order by r.code)
      from public.resources r
      cross join lateral (
        select public.booking_floor_availability(r.shop_id,r.category_code,r.code,e.starts_at,e.starts_at + make_interval(hours => e.duration_hours)) as state
      ) availability
      where (r.shop_id, r.category_code) = (e.id, e.code)
    ), '[]'::jsonb)
  )
  from eligible e
  left join public.layouts l on (l.shop_id, l.category_code) = (e.id, e.code);
$$;

commit;
