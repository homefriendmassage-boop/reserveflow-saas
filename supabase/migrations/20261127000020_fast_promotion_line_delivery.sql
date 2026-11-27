begin;

create or replace function reserveflow_private.wake_promotion_line_worker()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  worker_url text;
  worker_secret text;
begin
  if not exists (select 1 from new_promotion_events) then return null; end if;
  if to_regclass('cron.job') is null or to_regnamespace('net') is null then return null; end if;

  -- Reuse the endpoint and secret already configured for this database's Cron.
  select min(endpoint) into worker_url
  from (
    select distinct substring(command from
      'https://[a-z0-9-]+[.]supabase[.]co/functions/v1/promotion-line-worker') as endpoint
    from cron.job
    where active and command like '%promotion_worker_secret%'
  ) targets
  where endpoint is not null
  having count(*)=1;

  if worker_url is null then return null; end if;
  select decrypted_secret into worker_secret
  from vault.decrypted_secrets where name='promotion_worker_secret';
  if nullif(btrim(worker_secret),'') is null then return null; end if;

  -- pg_net only sends the request after the booking transaction commits.
  perform net.http_post(
    url := worker_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type','application/json','x-promotion-worker-secret',worker_secret
    ),
    timeout_milliseconds := 30000
  );
  return null;
exception when others then
  -- The queued event remains available to the scheduled delivery worker.
  return null;
end;
$$;

revoke all on function reserveflow_private.wake_promotion_line_worker()
  from public,anon,authenticated;

drop trigger if exists wake_promotion_line_worker on public.rf_promotion_events;
create trigger wake_promotion_line_worker
  after insert on public.rf_promotion_events
  referencing new table as new_promotion_events
  for each statement execute function reserveflow_private.wake_promotion_line_worker();

commit;
