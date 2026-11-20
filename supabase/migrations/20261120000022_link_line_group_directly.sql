begin;

create function public.shop_line_group_credentials(p_shop_id uuid,p_owner uuid)
returns table(bot_id text,access_token text)
language sql stable security definer set search_path='' as $$
  select s.bot_id,v.decrypted_secret::jsonb->>'token'
  from reserveflow_private.shop_line_channels s join vault.decrypted_secrets v on v.id=s.secret_id
  where s.shop_id=p_shop_id and exists(select 1 from public.shop_members m
    where m.shop_id=p_shop_id and m.user_id=p_owner and m.role='owner');
$$;

create function public.link_verified_shop_line_group(p_shop_id uuid,p_owner uuid,p_bot_id text,p_group_id text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not coalesce(p_group_id ~ '^C[0-9a-f]{32}$',false) then raise invalid_parameter_value; end if;
  perform pg_advisory_xact_lock(hashtextextended('line-pairing:'||p_shop_id::text,0));
  if not exists(select 1 from public.shop_members m where m.shop_id=p_shop_id and m.user_id=p_owner and m.role='owner')
    or not exists(select 1 from reserveflow_private.shop_line_channels s where s.shop_id=p_shop_id and s.bot_id=p_bot_id)
  then raise insufficient_privilege; end if;
  insert into reserveflow_private.line_targets(owner_scope,target,target_type,bot_id)
  values(p_shop_id::text,p_group_id,'group',p_bot_id)
  on conflict(owner_scope,target) do update set bot_id=excluded.bot_id
  where line_targets.bot_id is distinct from excluded.bot_id;
end;
$$;
revoke all on function public.shop_line_group_credentials(uuid,uuid),
  public.link_verified_shop_line_group(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.shop_line_group_credentials(uuid,uuid),
  public.link_verified_shop_line_group(uuid,uuid,text,text) to service_role;
commit;
