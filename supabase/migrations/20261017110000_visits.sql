-- Anonymous visitor statistics for the admin dashboard.
-- No names, no IP addresses: just a random visitor id kept in the visitor's browser.

create table public.visits (
  id          bigint generated always as identity primary key,
  visitor     text not null check (visitor ~ '^[a-z0-9]{8,40}$'),
  path        text not null default '/' check (char_length(path) <= 200),
  lang        text not null default 'en' check (lang in ('en', 'ar', 'ckb')),
  device      text not null default 'desktop' check (device in ('mobile', 'tablet', 'desktop')),
  source      text not null default 'direct' check (char_length(source) <= 80),
  created_at  timestamptz not null default now()
);
create index visits_by_time on public.visits (created_at desc);

alter table public.visits enable row level security;
revoke all on public.visits from anon, authenticated;
grant insert (visitor, path, lang, device, source) on public.visits to anon, authenticated;
create policy "anyone can be counted" on public.visits for insert to anon, authenticated with check (true);
grant delete on public.visits to authenticated;
create policy "admins delete visits" on public.visits for delete to authenticated using (public.is_admin());

-- Visitor numbers for the dashboard (times in Iraq time, UTC+3)
create or replace function public.admin_visits(p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  since timestamptz := date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad' - make_interval(days => greatest(1, least(p_days, 365)) - 1);
  today timestamptz := date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad';
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
  return jsonb_build_object(
    'visitors_today', (select count(distinct visitor) from public.visits where created_at >= today),
    'views_today',    (select count(*) from public.visits where created_at >= today),
    'visitors_7d',    (select count(distinct visitor) from public.visits where created_at >= today - interval '6 days'),
    'visitors_period',(select count(distinct visitor) from public.visits where created_at >= since),
    'views_period',   (select count(*) from public.visits where created_at >= since),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d::date, 'visitors', coalesce(v.visitors, 0), 'views', coalesce(v.views, 0)) order by d), '[]'::jsonb)
              from generate_series((since at time zone 'Asia/Baghdad')::date, (now() at time zone 'Asia/Baghdad')::date, interval '1 day') d
              left join (select (created_at at time zone 'Asia/Baghdad')::date as day, count(distinct visitor) as visitors, count(*) as views
                         from public.visits where created_at >= since group by 1) v on v.day = d::date),
    'by_lang',   (select coalesce(jsonb_object_agg(lang, n), '{}'::jsonb) from (select lang, count(distinct visitor) n from public.visits where created_at >= since group by lang) x),
    'by_device', (select coalesce(jsonb_object_agg(device, n), '{}'::jsonb) from (select device, count(distinct visitor) n from public.visits where created_at >= since group by device) x),
    'by_source', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'visitors', n) order by n desc), '[]'::jsonb)
                  from (select source, count(distinct visitor) n from public.visits where created_at >= since group by source order by n desc limit 8) x)
  );
end;
$$;
revoke execute on function public.admin_visits(int) from public, anon;
grant execute on function public.admin_visits(int) to authenticated;
