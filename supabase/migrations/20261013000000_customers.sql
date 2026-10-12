-- MySpace customers: one row per account, created automatically at sign-up.

create table public.customers (
  id          uuid primary key references auth.users (id) on delete cascade,
  ms_id       text not null unique,
  name        text not null default '',
  email       text not null,
  phone       text not null default '',
  city        text not null default '',
  lang        text not null default 'en',
  created_at  timestamptz not null default now()
);

comment on table public.customers is 'MySpace customer profiles (one per login).';

alter table public.customers enable row level security;

-- Customers can read and edit only their own row; the MySpace ID and email are not editable.
create policy "customers read own" on public.customers
  for select to authenticated using ((select auth.uid()) = id);

create policy "customers update own" on public.customers
  for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

revoke all on public.customers from anon, authenticated;
grant select on public.customers to authenticated;
grant update (name, phone, city, lang) on public.customers to authenticated;

-- Create the profile row (with a unique MySpace ID like MS482913) when someone signs up.
create or replace function public.handle_new_customer()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_ms_id text;
begin
  loop
    new_ms_id := 'MS' || (floor(random() * 900000) + 100000)::int::text;
    exit when not exists (select 1 from public.customers where ms_id = new_ms_id);
  end loop;

  insert into public.customers (id, ms_id, name, email, phone, city, lang)
  values (
    new.id,
    new_ms_id,
    left(coalesce(new.raw_user_meta_data ->> 'name', ''), 120),
    new.email,
    left(coalesce(new.raw_user_meta_data ->> 'phone', ''), 40),
    left(coalesce(new.raw_user_meta_data ->> 'city', ''), 80),
    case when new.raw_user_meta_data ->> 'lang' in ('en', 'ar', 'ckb') then new.raw_user_meta_data ->> 'lang' else 'en' end
  );
  return new;
end;
$$;

revoke execute on function public.handle_new_customer() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_customer();
