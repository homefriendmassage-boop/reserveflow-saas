begin;

alter table public.booking_slip_attachments add column verified_paid_at timestamptz;
create index booking_slip_paid_daily on public.booking_slip_attachments(verified_paid_at)
where verification_state='confirmed' and verified_paid_at is not null;
create index bookings_shop_service_day on public.bookings(shop_id,starts_at);

create function reserveflow_private.can_read_shop_reports(p_shop_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.shop_members where shop_id=p_shop_id
    and user_id=(select auth.uid()) and role in ('owner','admin','cashier'));
$$;

create function public.shop_daily_report(p_shop_id uuid,p_date date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  shop public.shops%rowtype;
  start_day timestamptz;
  end_day timestamptz;
  service jsonb;
  receipts jsonb;
  categories jsonb;
begin
  if not reserveflow_private.can_read_shop_reports(p_shop_id) then raise insufficient_privilege; end if;
  select * into strict shop from public.shops where id=p_shop_id;
  if p_date is null or not isfinite(p_date) or p_date<'2000-01-01'::date
    or p_date>(now() at time zone shop.timezone)::date then raise invalid_parameter_value; end if;
  start_day := p_date::timestamp at time zone shop.timezone;
  end_day := (p_date+1)::timestamp at time zone shop.timezone;

  select jsonb_build_object(
    'bookings',count(*),
    'active',count(*) filter(where b.status in ('confirmed','checked_in','completed')),
    'pending',count(*) filter(where b.status in ('pending_payment','pending_confirm','slip_review')),
    'cancelled',count(*) filter(where b.status='cancelled'),
    'booking_amount',coalesce(sum(b.amount) filter(where b.status in ('confirmed','checked_in','completed')),0))
  into service from public.bookings b
    where b.shop_id=p_shop_id and b.starts_at>=start_day and b.starts_at<end_day;
  select jsonb_build_object('verified_amount',coalesce(sum(a.verified_amount),0),
    'verified_count',count(*))
  into receipts from public.booking_slip_attachments a join public.bookings b on b.id=a.booking_id
    where b.shop_id=p_shop_id and a.verification_state='confirmed'
      and a.verified_paid_at>=start_day and a.verified_paid_at<end_day;

  select coalesce(jsonb_agg(to_jsonb(parts) order by parts.name),'[]'::jsonb) into categories from (
    select c.name,count(*) as bookings,count(*) filter(where b.status='cancelled') as cancelled,
      coalesce(sum(b.amount) filter(where b.status in ('confirmed','checked_in','completed')),0) as booking_amount
    from public.bookings b join public.categories c on (c.shop_id,c.code)=(b.shop_id,b.category_code)
    where b.shop_id=p_shop_id and b.starts_at>=start_day and b.starts_at<end_day
    group by c.code,c.name
  ) parts;
  return jsonb_build_object('shop_name',shop.name,'date',p_date,'categories',categories) || service || receipts;
end;
$$;

create function public.shop_daily_report_groups(p_shop_id uuid)
returns table(id uuid,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
  if not reserveflow_private.can_read_shop_reports(p_shop_id) then raise insufficient_privilege; end if;
  return query select t.id,t.created_at from reserveflow_private.line_targets t
  where t.owner_scope=p_shop_id::text and t.target_type='group' order by t.created_at;
end;
$$;

alter table reserveflow_private.line_outbox drop constraint line_outbox_kind_check;
alter table reserveflow_private.line_outbox add constraint line_outbox_kind_check
check(kind in ('shop','booking','referral','daily_report'));

create function public.send_shop_daily_report(p_shop_id uuid,p_date date,p_target_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  report jsonb := public.shop_daily_report(p_shop_id,p_date);
  outbox_id uuid;
begin
  if not exists(select 1 from reserveflow_private.line_targets where id=p_target_id
    and owner_scope=p_shop_id::text and target_type='group') then raise insufficient_privilege; end if;
  perform pg_advisory_xact_lock(hashtextextended('daily-report:'||p_target_id::text||':'||p_date::text,0));
  select id into outbox_id from reserveflow_private.line_outbox
  where target_id=p_target_id and kind='daily_report' and payload->>'date'=p_date::text and payload=report
    and coalesce(delivered_at,next_at)>now()-interval '30 seconds' and attempts<8
  limit 1;
  if found then return outbox_id; end if;
  insert into reserveflow_private.line_outbox(target_id,kind,payload)
  values(p_target_id,'daily_report',report) returning id into outbox_id;
  return outbox_id;
end;
$$;

revoke all on function public.shop_daily_report(uuid,date),public.shop_daily_report_groups(uuid),
  public.send_shop_daily_report(uuid,date,uuid) from public,anon,authenticated;
grant execute on function public.shop_daily_report(uuid,date),public.shop_daily_report_groups(uuid),
  public.send_shop_daily_report(uuid,date,uuid) to authenticated;
create or replace function public.finish_thunder_booking_slip(
  p_booking_id uuid,p_outcome text,p_reference text,p_amount numeric,p_mobile text,p_paid_at timestamptz
) returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  slip public.booking_slip_attachments%rowtype;
  booking public.bookings%rowtype;
  expected_mobile text;
  outcome text := p_outcome;
begin
  if p_outcome not in ('retry','qr_unreadable','not_verified','provider_verified') then
    raise exception using errcode='22023',message='INVALID_VERIFICATION_OUTCOME';
  end if;
  select * into slip from public.booking_slip_attachments where booking_id=p_booking_id for update;
  if not found then return null; end if;
  if slip.verification_state not in ('pending','retry') then
    return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
  end if;
  if p_outcome='provider_verified' then
    select * into booking from public.bookings where id=p_booking_id for update;
    select mobile into expected_mobile from public.shop_promptpay where shop_id=booking.shop_id for share;
    if p_amount is null or p_amount <= 0 or p_amount > 9999999999.99 or p_amount <> round(p_amount,2)
      or p_reference is null or length(p_reference) not between 1 and 200 then
      outcome := 'retry';
    elsif p_mobile is null or expected_mobile is null or p_mobile <> expected_mobile
      or p_paid_at is null or p_paid_at < booking.created_at or p_paid_at > now()+interval '2 minutes' then
      outcome := case when p_amount <> booking.amount then 'amount_review' else 'receiver_review' end;
    else
      begin
        perform pg_advisory_xact_lock(hashtextextended('payment-reference:'||p_reference,0));
        if exists (select 1 from reserveflow_private.package_orders where transfer_reference=p_reference) then
          raise unique_violation;
        end if;
        update public.booking_slip_attachments set thunder_reference=p_reference where booking_id=p_booking_id;
        if p_amount <> booking.amount then
          outcome := 'amount_review';
        elsif booking.status in ('pending_confirm','pending_payment','slip_review') and booking.starts_at > now() then
          update public.bookings set status='confirmed' where id=p_booking_id;
          outcome := 'confirmed';
        else
          outcome := 'booking_review';
        end if;
      exception when unique_violation then
        outcome := 'duplicate_review';
      end;
    end if;
  end if;
  update public.booking_slip_attachments
  set verification_state=outcome,
    verified_paid_at=case when outcome='confirmed' then p_paid_at end,
    verified_amount=case when outcome in ('confirmed','amount_review','receiver_review','booking_review','duplicate_review')
      then p_amount else null end
  where booking_id=p_booking_id returning * into slip;
  return jsonb_build_object('state',slip.verification_state,'amount',slip.verified_amount);
end;
$$;

commit;
