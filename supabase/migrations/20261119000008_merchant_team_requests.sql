begin;

alter table public.shop_members add column team_name text
  check (char_length(team_name) between 1 and 80);

create table public.shop_team_requests (
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  requested_name text not null check (char_length(requested_name) between 1 and 80),
  created_at timestamptz not null default now(),
  primary key (shop_id, user_id)
);
create index shop_team_requests_user_idx on public.shop_team_requests (user_id);
alter table public.shop_team_requests enable row level security;
revoke all on table public.shop_team_requests from public, anon, authenticated;

create function public.request_merchant_team_access(p_slug text, p_name text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  account_id uuid := auth.uid();
  target_shop uuid;
begin
  if account_id is null then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 80 then
    raise exception using errcode = '22023', message = 'INVALID_TEAM_REQUEST';
  end if;
  select id into target_shop from public.shops where slug = lower(btrim(p_slug));
  if not found then raise exception using errcode = '22023', message = 'INVALID_TEAM_REQUEST'; end if;

  perform pg_advisory_xact_lock(hashtextextended('team-request:' || account_id::text, 0));
  if exists (select 1 from public.shop_members where shop_id = target_shop and user_id = account_id) then
    raise exception using errcode = '22023', message = 'TEAM_ALREADY_MEMBER';
  end if;
  if not exists (select 1 from public.shop_team_requests where shop_id = target_shop and user_id = account_id)
    and (select count(*) from public.shop_team_requests where user_id = account_id) >= 5 then
    raise exception using errcode = '22023', message = 'TEAM_REQUEST_LIMIT';
  end if;
  insert into public.shop_team_requests (shop_id, user_id, requested_name)
    values (target_shop, account_id, btrim(p_name))
    on conflict (shop_id, user_id) do update set requested_name = excluded.requested_name;
end;
$$;

create function public.list_merchant_team(p_shop_id uuid)
returns table (
  user_id uuid, role text, requested_name text, line_name text, email text, requested_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members m
    where m.shop_id = p_shop_id and m.user_id = (select auth.uid()) and m.role = 'owner') then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  return query
    with team as (
      select m.user_id, m.role, m.team_name as requested_name, null::timestamptz as requested_at
      from public.shop_members m where m.shop_id = p_shop_id
      union all
      select r.user_id, 'pending', r.requested_name, r.created_at
      from public.shop_team_requests r where r.shop_id = p_shop_id
        and not exists (select 1 from public.shop_members m where (m.shop_id,m.user_id) = (r.shop_id,r.user_id))
    )
    select t.user_id, t.role, t.requested_name,
      left(coalesce(nullif(i.identity_data->>'name',''), nullif(i.identity_data->>'full_name','')), 100),
      case when t.role <> 'pending' then u.email::text end,
      t.requested_at
    from team t
    join auth.users u on u.id = t.user_id
    left join lateral (
      select identity_data from auth.identities i
      where i.user_id = t.user_id and i.provider in ('custom:line-manual', 'custom:line')
      order by i.created_at desc limit 1
    ) i on true
    order by (t.role = 'pending') desc, t.requested_at desc nulls last, t.user_id;
end;
$$;

create function public.review_merchant_team_request(p_shop_id uuid, p_user_id uuid, p_action text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.shop_members m
    where m.shop_id = p_shop_id and m.user_id = (select auth.uid()) and m.role = 'owner') then
    raise exception using errcode = '42501', message = 'MERCHANT_BOOKING_FORBIDDEN';
  end if;
  if p_action is null or p_action not in ('cashier','staff','reject') then
    raise exception using errcode = '22023', message = 'INVALID_TEAM_REQUEST';
  end if;
  perform 1 from public.shop_team_requests where shop_id = p_shop_id and user_id = p_user_id for update;
  if not found then raise exception using errcode = '22023', message = 'INVALID_TEAM_REQUEST'; end if;
  if p_action <> 'reject' then
    insert into public.shop_members (shop_id, user_id, role, team_name)
      select shop_id, user_id, p_action, requested_name
      from public.shop_team_requests where shop_id = p_shop_id and user_id = p_user_id
      on conflict (shop_id, user_id) do nothing;
  end if;
  delete from public.shop_team_requests where shop_id = p_shop_id and user_id = p_user_id;
end;
$$;

revoke all on function public.request_merchant_team_access(text,text), public.list_merchant_team(uuid),
  public.review_merchant_team_request(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.request_merchant_team_access(text,text), public.list_merchant_team(uuid),
  public.review_merchant_team_request(uuid,uuid,text) to authenticated;

commit;
