-- Chat replies can contain report data. Keep a session private to its author
-- and stop serving it if their role, source access or payment access changes.
create function public.assistant_chat_access()
returns text language sql stable security definer set search_path = '' as $$
  select jsonb_build_array(
    p.role, p.can_submit_payments, p.can_review_payments,
    (select coalesce(jsonb_agg(s.source order by s.source), '[]'::jsonb)
     from public.section_access s where s.role = p.role and s.allowed)
  )::text
  from public.profiles p where p.id = auth.uid() and p.active;
$$;
revoke all on function public.assistant_chat_access() from public, anon, authenticated;
grant execute on function public.assistant_chat_access() to authenticated;

create table public.assistant_chats (
  id uuid primary key,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  access_snapshot text not null default public.assistant_chat_access(),
  title text not null check (char_length(title) between 1 and 160),
  entries jsonb not null check (jsonb_typeof(entries) = 'array'),
  version integer not null default 1 check (version > 0),
  updated_at timestamptz not null default now()
);
create index assistant_chats_by_user on public.assistant_chats (user_id, updated_at desc, id);
alter table public.assistant_chats enable row level security;
revoke all on public.assistant_chats from public, anon, authenticated;
grant select on public.assistant_chats to authenticated;
grant insert (id, title, entries), update (title, entries, version, updated_at)
  on public.assistant_chats to authenticated;

create policy own_assistant_chats on public.assistant_chats
  for all to authenticated
  using (user_id = (select auth.uid()) and access_snapshot = (select public.assistant_chat_access()))
  with check (user_id = (select auth.uid()) and access_snapshot = (select public.assistant_chat_access()));
