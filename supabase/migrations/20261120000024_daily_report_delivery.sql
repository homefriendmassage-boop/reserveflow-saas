begin;

alter table reserveflow_private.line_outbox add column queued_at timestamptz;
alter table reserveflow_private.line_outbox alter column queued_at set default now();

create index daily_report_delivery_lookup on reserveflow_private.line_outbox
  (target_id, (payload->>'date'), queued_at desc)
  where kind='daily_report';

create function public.shop_daily_report_delivery(p_shop_id uuid,p_date date,p_target_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  if not reserveflow_private.can_read_shop_reports(p_shop_id) then raise insufficient_privilege; end if;
  return (
    select jsonb_build_object(
      'state',case when q.delivered_at is not null then 'accepted'
        when q.attempts>=8 then 'failed'
        when q.lease_id is not null then 'sending'
        when q.attempts>0 then 'retrying' else 'queued' end,
      'delivered_at',q.delivered_at,
      'http_status',q.last_status)
    from reserveflow_private.line_outbox q join reserveflow_private.line_targets t on t.id=q.target_id
    where q.target_id=p_target_id and q.kind='daily_report' and q.payload->>'date'=p_date::text
      and t.target_type='group' and t.owner_scope=p_shop_id::text
      and reserveflow_private.line_target_is_current(t) and q.sender_bot_id is not distinct from t.bot_id
    order by q.queued_at desc nulls last, coalesce(q.delivered_at,q.next_at) desc, q.id desc limit 1
  );
end;
$$;
revoke all on function public.shop_daily_report_delivery(uuid,date,uuid) from public,anon,authenticated;
grant execute on function public.shop_daily_report_delivery(uuid,date,uuid) to authenticated;

commit;
