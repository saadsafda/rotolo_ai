-- Only the email Edge Function may claim or finalize a send attempt.
-- Store no addresses, subject lines or message bodies.
create table public.assistant_email_attempts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  request_id uuid not null,
  fingerprint text not null,
  status text not null default 'sending' check (status in ('sending', 'sent', 'rejected', 'unknown')),
  created_at timestamptz not null default now(),
  primary key (user_id, request_id)
);

alter table public.assistant_email_attempts enable row level security;
revoke all on public.assistant_email_attempts from anon, authenticated;
grant select, insert, update on public.assistant_email_attempts to service_role;
