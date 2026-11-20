begin;

alter table public.bookings add column review_hold boolean not null default false;
update public.bookings b set review_hold=true
where b.status in ('pending_payment','pending_confirm','slip_review')
  and exists (select 1 from public.booking_slip_attachments a where a.booking_id=b.id);

-- Replace the original exclusion constraint without depending on its generated name.
do $$
declare original text;
begin
  select conname into strict original from pg_constraint
  where conrelid='public.bookings'::regclass and contype='x';
  execute format('alter table public.bookings drop constraint %I',original);
end;
$$;

alter table public.bookings add constraint bookings_exclusive_period
exclude using gist (
  shop_id with =, category_code with =, resource_code with =,
  tstzrange(starts_at,ends_at,'[)') with &&
) where (status in ('confirmed','checked_in') or
  (review_hold and status in ('pending_payment','pending_confirm','slip_review')));

create index bookings_pending_floor_status on public.bookings(shop_id,category_code,resource_code,created_at desc)
where status in ('pending_payment','pending_confirm','slip_review');

create function public.protect_booking_period()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(
    'booking-slot:'||new.shop_id::text||':'||new.category_code||':'||new.resource_code,0));
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
create trigger protect_booking_period before insert or update of status,review_hold on public.bookings
for each row execute function public.protect_booking_period();
revoke all on function public.protect_booking_period() from public,anon,authenticated;

create table public.booking_selection_presence (
  shop_id uuid not null,
  session_id uuid not null,
  category_code text not null,
  resource_code text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  expires_at timestamptz not null,
  primary key(shop_id,session_id),
  foreign key(shop_id,category_code,resource_code) references public.resources(shop_id,category_code,code) on delete cascade
);
create index booking_selection_presence_expiry on public.booking_selection_presence(expires_at);
create index booking_selection_presence_resource on public.booking_selection_presence(shop_id,category_code,resource_code);
alter table public.booking_selection_presence enable row level security;
revoke all on public.booking_selection_presence from public,anon,authenticated;

create function public.mark_booking_selection(
  p_shop_slug text,p_session uuid,p_category_code text,p_resource_code text,
  p_date date,p_hour integer,p_minute integer,p_hours integer
) returns void language plpgsql security definer set search_path=''
as $$
declare
  shop uuid;
  zone text;
  opening timestamptz;
  duration integer;
begin
  select s.id,s.timezone into shop,zone from public.shops s
  where s.slug=p_shop_slug and s.public_booking_enabled;
  if shop is null or p_session is null then return; end if;
  if p_resource_code is null then
    delete from public.booking_selection_presence where shop_id=shop and session_id=p_session;
    return;
  end if;
  select case when c.template='table' then 2 else p_hours end into duration
  from public.categories c join public.resources r on (r.shop_id,r.category_code)=(c.shop_id,c.code)
  where c.shop_id=shop and c.code=p_category_code and c.visible and c.template in ('table','seat','vip')
    and r.code=p_resource_code and not (r.display @> '{"archived":true}');
  if duration is null or duration not between 1 and 6 or p_hour not between 10 and 22
    or p_minute not in (0,30) or (p_hour=22 and p_minute<>0)
    or p_date not between (now() at time zone zone)::date and (now() at time zone zone)::date+90
    or p_date is null or p_hour is null or p_minute is null then return; end if;
  opening := (p_date+make_time(p_hour,p_minute,0)) at time zone zone;
  delete from public.booking_selection_presence
  where (shop_id,session_id) in (
    select shop_id,session_id from public.booking_selection_presence where expires_at<=now()
    order by expires_at limit 100 for update skip locked
  );
  insert into public.booking_selection_presence(shop_id,session_id,category_code,resource_code,starts_at,ends_at,expires_at)
  values(shop,p_session,p_category_code,p_resource_code,opening,opening+make_interval(hours=>duration),now()+interval '15 seconds')
  on conflict(shop_id,session_id) do update set category_code=excluded.category_code,resource_code=excluded.resource_code,
    starts_at=excluded.starts_at,ends_at=excluded.ends_at,expires_at=excluded.expires_at;
end;
$$;
revoke all on function public.mark_booking_selection(text,uuid,text,text,date,integer,integer,integer) from public,anon,authenticated;
grant execute on function public.mark_booking_selection(text,uuid,text,text,date,integer,integer,integer) to anon,authenticated;

create function public.booking_floor_availability(
  p_shop_id uuid,p_category_code text,p_resource_code text,p_start timestamptz,p_end timestamptz
) returns text language sql stable security definer set search_path=''
as $$
  select case
    when exists (select 1 from public.bookings b
      where (b.shop_id,b.category_code,b.resource_code)=(p_shop_id,p_category_code,p_resource_code)
        and b.status in ('confirmed','checked_in')
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
revoke all on function public.booking_floor_availability(uuid,text,text,timestamptz,timestamptz) from public,anon,authenticated;

create or replace function public.attach_customer_booking_slip(p_booking_id uuid,p_phone text,p_image text)
returns void language plpgsql security definer set search_path = ''
as $$
declare review_state text := 'pending';
begin
  if not coalesce(length(p_image) <= 1450000 and p_image ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$',false)
    or not coalesce(p_phone ~ '^[0-9[:space:]-]{9,20}$',false) then
    raise exception using errcode='22023',message='INVALID_SLIP_ATTACHMENT';
  end if;
  perform 1 from public.bookings b
  where b.id=p_booking_id and b.customer_phone=regexp_replace(p_phone,'[[:space:]-]','','g')
    and b.created_at > now() - interval '24 hours'
    and b.status in ('pending_confirm','pending_payment','slip_review')
    and b.amount > 0
  for update;
  if not found then raise exception using errcode='22023',message='SLIP_BOOKING_UNAVAILABLE'; end if;

  if exists (select 1 from public.booking_slip_attachments where booking_id=p_booking_id) then
    if exists (select 1 from public.booking_slip_attachments where booking_id=p_booking_id and image=p_image) then return; end if;
    raise exception using errcode='22023',message='SLIP_ALREADY_ATTACHED';
  end if;
  begin
    update public.bookings set review_hold=true where id=p_booking_id;
  exception when exclusion_violation then
    -- Keep the evidence if another booking won after this customer paid.
    review_state := 'booking_review';
  end;
  insert into public.booking_slip_attachments(booking_id,image,verification_state)
  values (p_booking_id,p_image,review_state);
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
      and p_hour between 10 and 22 and p_minute in (0, 30)
      and (p_hour < 22 or p_minute = 0)
      and p_date between (statement_timestamp() at time zone s.timezone)::date
                     and (statement_timestamp() at time zone s.timezone)::date + 90
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
        'occupied', availability.state in ('booked','review'), 'availability', availability.state
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
    select s.id, c.code, case when c.template in ('seat','vip') then p_hours else 2 end as duration_hours,
      (p_date + make_time(p_hour, p_minute, 0)) at time zone s.timezone as starts_at
    from public.shops s
    join public.categories c on c.shop_id = s.id
    where s.slug = p_shop_slug and s.public_booking_enabled and c.visible
      and c.code = p_category_code and c.template in ('table', 'seat', 'vip')
      and (c.template = 'table' or (c.template = 'seat' and p_hours between 1 and 6)
        or (c.template = 'vip' and p_hours between 1 and 5))
      and p_hour between 10 and 22 and p_minute in (0, 30)
      and (p_hour < 22 or p_minute = 0)
      and p_date between (statement_timestamp() at time zone s.timezone)::date
                     and (statement_timestamp() at time zone s.timezone)::date + 90
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
        'occupied', availability.state in ('booked','review'), 'availability', availability.state
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
