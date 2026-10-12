-- Business settings the website reads (fuel surcharge, exchange rate),
-- editable by the owner in Supabase: Table Editor -> settings.

create table public.settings (
  key         text primary key,
  value       numeric not null,
  note        text,
  updated_at  timestamptz not null default now()
);

comment on table public.settings is 'MySpace website settings. Edit the value column; the website uses it immediately.';

alter table public.settings enable row level security;

create policy "settings are public" on public.settings
  for select to anon, authenticated using (true);

revoke all on public.settings from anon, authenticated;
grant select on public.settings to anon, authenticated;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger settings_touch before update on public.settings
  for each row execute function public.touch_updated_at();

insert into public.settings (key, value, note) values
  ('fuel_percent', 0,    'Fuel surcharge in percent (e.g. 24.5). Changes weekly - update it here.'),
  ('usd_to_iqd',   1520, 'Iraqi dinars for 1 US dollar, used to show prices in IQD.');

-- Customers' own delivery address in Iraq
alter table public.customers add column address text not null default '';
grant update (address) on public.customers to authenticated;
