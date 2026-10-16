-- MySpace admin portal: admin accounts, contact messages, quote log, text settings,
-- and admin-only access to everything.

-- ---------------------------------------------------------------- admins
create table public.admins (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  added_at    timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.admins where user_id = (select auth.uid()));
$$;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- ---------------------------------------------------------------- settings: text values too
alter table public.settings alter column value drop not null;
alter table public.settings add column text_value text;
insert into public.settings (key, value, text_value, note) values
  ('price_adjust_percent', 0, null, 'Raise (+) or lower (-) all calculator prices by this percent, e.g. 5 or -3.'),
  ('phone',        null, '+964 750 742 2734',   'Phone number shown on the website.'),
  ('whatsapp',     null, '9647507422734',       'WhatsApp number: country code + number, digits only.'),
  ('notify_email', null, 'anis@myspaceapp.com', 'Email address shown on the website.');

create policy "admins update settings" on public.settings
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
grant update (value, text_value) on public.settings to authenticated;

-- ---------------------------------------------------------------- contact messages
create table public.messages (
  id          bigint generated always as identity primary key,
  name        text not null check (char_length(name) between 1 and 120),
  email       text not null check (char_length(email) between 3 and 200),
  phone       text not null default '' check (char_length(phone) <= 40),
  message     text not null check (char_length(message) between 1 and 4000),
  lang        text not null default 'en' check (lang in ('en', 'ar', 'ckb')),
  handled     boolean not null default false,
  created_at  timestamptz not null default now()
);
alter table public.messages enable row level security;
revoke all on public.messages from anon, authenticated;
grant insert (name, email, phone, message, lang) on public.messages to anon, authenticated;
create policy "anyone can send a message" on public.messages
  for insert to anon, authenticated with check (handled = false);
grant select, update (handled), delete on public.messages to authenticated;
create policy "admins read messages"   on public.messages for select to authenticated using (public.is_admin());
create policy "admins update messages" on public.messages for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins delete messages" on public.messages for delete to authenticated using (public.is_admin());

-- ---------------------------------------------------------------- quote log (every price check)
create table public.quotes (
  id              bigint generated always as identity primary key,
  from_country    text not null check (char_length(from_country) between 2 and 2),
  to_city         text not null default '' check (char_length(to_city) <= 60),
  shipment_type   text not null default 'pkg' check (shipment_type in ('pkg', 'docs')),
  pieces          int  not null default 1 check (pieces between 1 and 500),
  chargeable_kg   numeric not null check (chargeable_kg >= 0 and chargeable_kg <= 100000),
  total_usd       numeric not null check (total_usd >= 0 and total_usd <= 10000000),
  booked          boolean not null default false,
  customer_id     uuid references auth.users (id) on delete set null default auth.uid(),
  created_at      timestamptz not null default now()
);
alter table public.quotes enable row level security;
revoke all on public.quotes from anon, authenticated;
grant insert (from_country, to_city, shipment_type, pieces, chargeable_kg, total_usd, booked) on public.quotes to anon, authenticated;
create policy "anyone can log a quote" on public.quotes for insert to anon, authenticated with check (true);
grant select, delete on public.quotes to authenticated;
create policy "admins read quotes"   on public.quotes for select to authenticated using (public.is_admin());
create policy "admins delete quotes" on public.quotes for delete to authenticated using (public.is_admin());

-- ---------------------------------------------------------------- admin access to existing tables
-- (customers are deleted only through admin_delete_customer below)
grant select, update (name, phone, city, address, lang) on public.customers to authenticated;
create policy "admins read customers"   on public.customers for select to authenticated using (public.is_admin());
create policy "admins update customers" on public.customers for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert, update, delete on public.shipments, public.shipment_updates to authenticated;
create policy "admins manage shipments" on public.shipments
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage shipment updates" on public.shipment_updates
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------- admin functions
-- Customers with login details from the auth system (last sign-in etc.)
create or replace function public.admin_customers()
returns table (id uuid, ms_id text, name text, email text, phone text, city text, address text, lang text,
               created_at timestamptz, last_sign_in_at timestamptz, shipments bigint, quotes bigint, is_admin boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  return query
    select c.id, c.ms_id, c.name, c.email, c.phone, c.city, c.address, c.lang, c.created_at, u.last_sign_in_at,
           (select count(*) from public.shipments s where s.customer_ms_id = c.ms_id),
           (select count(*) from public.quotes q where q.customer_id = c.id),
           exists (select 1 from public.admins a where a.user_id = c.id)
    from public.customers c
    left join auth.users u on u.id = c.id
    order by c.created_at desc;
end;
$$;
revoke execute on function public.admin_customers() from public, anon;
grant execute on function public.admin_customers() to authenticated;

-- Delete a customer completely (login + profile); their shipments stay, unlinked
create or replace function public.admin_delete_customer(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  if p_id = (select auth.uid()) then raise exception 'You cannot delete your own admin account here.'; end if;
  delete from auth.users where id = p_id;
end;
$$;
revoke execute on function public.admin_delete_customer(uuid) from public, anon;
grant execute on function public.admin_delete_customer(uuid) to authenticated;

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
    'quotes_7d',          (select count(*) from public.quotes where created_at > now() - interval '7 days'),
    'quotes_30d',         (select count(*) from public.quotes where created_at > now() - interval '30 days'),
    'bookings_30d',       (select count(*) from public.quotes where booked and created_at > now() - interval '30 days'),
    'quote_value_30d',    (select coalesce(sum(total_usd), 0) from public.quotes where created_at > now() - interval '30 days'),
    'shipments_by_status', (select coalesce(jsonb_object_agg(st, n), '{}'::jsonb) from (
        select coalesce((select u.status::text from public.shipment_updates u where u.tracking_number = s.tracking_number
                         order by u.happened_at desc, u.id desc limit 1), 'no_updates') as st, count(*) as n
        from public.shipments s group by 1) x),
    'top_countries_30d',  (select coalesce(jsonb_agg(jsonb_build_object('country', from_country, 'quotes', n) order by n desc), '[]'::jsonb) from (
        select from_country, count(*) as n from public.quotes where created_at > now() - interval '30 days'
        group by from_country order by n desc limit 6) t)
  );
end;
$$;
revoke execute on function public.admin_overview() from public, anon;
grant execute on function public.admin_overview() to authenticated;
