-- Create reserveflow_line_worker_secret in Supabase Vault before running.
do $$
begin
  if to_regnamespace('cron') is null or to_regnamespace('net') is null then
    raise exception 'Enable Supabase Cron (pg_cron) and the pg_net extension first.';
  end if;
  if not exists (select 1 from vault.secrets where name = 'reserveflow_line_worker_secret') then
    raise exception 'Create reserveflow_line_worker_secret in Supabase Vault first.';
  end if;

  perform cron.schedule('reserveflow-line-notify','* * * * *',$job$
    select net.http_post(
      url := 'https://zotgxsimkrofqxkhjjak.supabase.co/functions/v1/line-notification-worker',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'x-rf-worker-secret',(select decrypted_secret from vault.decrypted_secrets
          where name = 'reserveflow_line_worker_secret')
      ),
      body := '{}'::jsonb
    );
  $job$);
end;
$$;
