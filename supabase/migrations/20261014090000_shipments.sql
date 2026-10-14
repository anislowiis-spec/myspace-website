-- Shipment tracking managed by MySpace in the Supabase dashboard.
--   shipments         one row per shipment (tracking number, which customer, from/to, expected date)
--   shipment_updates  one row per status update; the newest row is the current status
-- Customers never read these tables directly: they use the two functions below.

create type public.shipment_status as enum (
  'created', 'picked_up', 'in_transit', 'arrived_iraq', 'customs', 'out_for_delivery', 'delivered', 'problem'
);

create table public.shipments (
  tracking_number     text primary key check (tracking_number ~ '^[A-Z0-9]{4,35}$'),
  customer_ms_id      text references public.customers (ms_id) on update cascade on delete set null,
  from_country        text not null default '',
  to_city             text not null default '',
  estimated_delivery  date,
  created_at          timestamptz not null default now()
);
comment on table public.shipments is 'MySpace shipments. tracking_number: capital letters/digits, no spaces. customer_ms_id: the customer''s MySpace ID (e.g. MS482913).';

create table public.shipment_updates (
  id               bigint generated always as identity primary key,
  tracking_number  text not null references public.shipments (tracking_number) on update cascade on delete cascade,
  status           public.shipment_status not null,
  note             text not null default '',
  location         text not null default '',
  happened_at      timestamptz not null default now()
);
comment on table public.shipment_updates is 'Add a row for every status change. Leave note empty to show the standard text in the customer''s language.';
create index shipment_updates_by_number on public.shipment_updates (tracking_number, happened_at desc);

alter table public.shipments enable row level security;
alter table public.shipment_updates enable row level security;
revoke all on public.shipments, public.shipment_updates from anon, authenticated;

-- One shipment as JSON (shared by the two functions)
create or replace function public.shipment_json(p_number text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', s.tracking_number,
    'origin', s.from_country,
    'destination', s.to_city,
    'estimatedDelivery', s.estimated_delivery,
    'createdAt', s.created_at,
    'status', (select jsonb_build_object('code', u.status, 'note', u.note, 'location', u.location, 'time', u.happened_at)
               from public.shipment_updates u where u.tracking_number = s.tracking_number
               order by u.happened_at desc, u.id desc limit 1),
    'events', coalesce((select jsonb_agg(jsonb_build_object('code', u.status, 'note', u.note, 'location', u.location, 'time', u.happened_at)
                                order by u.happened_at desc, u.id desc)
                        from public.shipment_updates u where u.tracking_number = s.tracking_number), '[]'::jsonb)
  )
  from public.shipments s
  where s.tracking_number = p_number;
$$;
revoke execute on function public.shipment_json(text) from public, anon, authenticated;

-- Track one shipment by its number (any logged-in customer who knows the number, like a courier tracking page;
-- it returns only statuses and places, no personal details)
create or replace function public.track_shipment(p_number text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'login required' using errcode = '42501';
  end if;
  return public.shipment_json(upper(regexp_replace(coalesce(p_number, ''), '[\s-]', '', 'g')));
end;
$$;
revoke execute on function public.track_shipment(text) from public, anon;
grant execute on function public.track_shipment(text) to authenticated;

-- The logged-in customer's own shipments, newest first
create or replace function public.my_shipments()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(public.shipment_json(s.tracking_number) order by s.created_at desc), '[]'::jsonb)
  from public.shipments s
  join public.customers c on c.ms_id = s.customer_ms_id
  where c.id = (select auth.uid());
$$;
revoke execute on function public.my_shipments() from public, anon;
grant execute on function public.my_shipments() to authenticated;
