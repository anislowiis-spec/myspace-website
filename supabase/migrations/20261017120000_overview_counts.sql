-- Price checks and bookings are counted separately (a booking is logged as its own row).
-- Dashboard numbers in one call
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  return jsonb_build_object(
    'customers',          (select count(*) from public.customers),
    'customers_7d',       (select count(*) from public.customers where created_at > now() - interval '7 days'),
    'customers_30d',      (select count(*) from public.customers where created_at > now() - interval '30 days'),
    'shipments',          (select count(*) from public.shipments),
    'messages_new',       (select count(*) from public.messages where not handled),
    'quotes_7d',          (select count(*) from public.quotes where not booked and created_at > now() - interval '7 days'),
    'quotes_30d',         (select count(*) from public.quotes where not booked and created_at > now() - interval '30 days'),
    'bookings_30d',       (select count(*) from public.quotes where booked and created_at > now() - interval '30 days'),
    'quote_value_30d',    (select coalesce(sum(total_usd), 0) from public.quotes where booked and created_at > now() - interval '30 days'),
    'shipments_by_status', (select coalesce(jsonb_object_agg(st, n), '{}'::jsonb) from (
        select coalesce((select u.status::text from public.shipment_updates u where u.tracking_number = s.tracking_number
                         order by u.happened_at desc, u.id desc limit 1), 'no_updates') as st, count(*) as n
        from public.shipments s group by 1) x),
    'top_countries_30d',  (select coalesce(jsonb_agg(jsonb_build_object('country', from_country, 'quotes', n) order by n desc), '[]'::jsonb) from (
        select from_country, count(*) as n from public.quotes where not booked and created_at > now() - interval '30 days'
        group by from_country order by n desc limit 6) t)
  );
end;
$$;
revoke execute on function public.admin_overview() from public, anon;
grant execute on function public.admin_overview() to authenticated;
