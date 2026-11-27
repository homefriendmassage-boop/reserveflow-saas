begin;
alter table public.rf_promotion_events drop constraint if exists rf_promotion_events_status_check;
alter table public.rf_promotion_events add constraint rf_promotion_events_status_check
  check(status in ('pending','processing','sent','failed'));
alter table public.rf_promotion_events add column if not exists lease_id uuid;
alter table public.rf_promotion_events add column if not exists leased_until timestamptz;
create function public.rf_claim_promotion_events(p_limit integer default 10)
returns table(id uuid,lease_id uuid,kind text,token uuid,shop_name text,offer_name text,gift_name text,expires_at timestamptz,line_user_id text)
language plpgsql security definer set search_path='' as $$
begin
  return query
  with due as (
    select e.id from public.rf_promotion_events e
    where e.attempts<5 and ((e.status in ('pending','failed') and e.next_attempt_at<=now())
      or (e.status='processing' and e.leased_until<now()))
    order by e.created_at for update skip locked limit least(greatest(p_limit,1),20)
  ), claimed as (
    update public.rf_promotion_events e set status='processing',
      attempts=e.attempts+1, lease_id=gen_random_uuid(),leased_until=now()+interval '2 minutes'
    from due where e.id=due.id
    returning e.id,e.lease_id,e.kind,e.voucher_id
  )
  select c.id,c.lease_id,c.kind,v.token,s.name,o.name,o.gift_name,v.expires_at,v.line_user_id
  from claimed c join public.rf_promotion_vouchers v on v.id=c.voucher_id
  join public.shops s on s.id=v.shop_id
  join public.rf_promotion_offers o on o.id=v.offer_id;
end $$;
create function public.rf_finish_promotion_event(p_id uuid,p_lease_id uuid,p_sent boolean,p_error text default null)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  update public.rf_promotion_events e set
    status=case when p_sent then 'sent' else 'failed' end,
    delivered_at=case when p_sent then now() else null end,
    next_attempt_at=case when p_sent then now() else now()+least(3600,60*power(2,least(e.attempts,6))) * interval '1 second' end,
    last_error=left(p_error,200),lease_id=null,leased_until=null
  where e.id=p_id and e.lease_id=p_lease_id and e.status='processing';
  return found;
end $$;
revoke all on function public.rf_claim_promotion_events(integer),public.rf_finish_promotion_event(uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.rf_claim_promotion_events(integer),public.rf_finish_promotion_event(uuid,uuid,boolean,text) to service_role;
commit;