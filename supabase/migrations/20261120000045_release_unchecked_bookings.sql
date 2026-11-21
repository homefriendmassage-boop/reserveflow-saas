begin;

-- Only a recorded check-in can hold a resource after the scheduled end.
create or replace function reserveflow_private.unfinished_booking_holds_slot(
  p_booking public.bookings,p_slot_start timestamptz,p_timezone text
)
returns boolean language sql stable set search_path=''
as $$
  select p_booking.status='checked_in'
    and p_booking.ends_at<=statement_timestamp()
    and p_slot_start>=p_booking.ends_at
    and (
      p_slot_start<=statement_timestamp()+interval '30 minutes'
      or (p_slot_start at time zone p_timezone - interval '6 hours')::date
        = (statement_timestamp() at time zone p_timezone - interval '6 hours')::date
    );
$$;

revoke all on function reserveflow_private.unfinished_booking_holds_slot(public.bookings,timestamptz,text)
  from public,anon,authenticated;

commit;
