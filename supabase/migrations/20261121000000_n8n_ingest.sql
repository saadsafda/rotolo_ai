-- Lets the n8n workflow "RE - APP - Daily Operations Report" store reports without
-- the service-role key and without deploying Edge Functions.
--
-- n8n calls  POST /rest/v1/rpc/n8n_ingest_report  with the publishable key and the
-- header  x-ingest-secret: <secret>. Only a SHA-256 hash of the secret is stored, in a
-- schema the Data API does not expose. Wrong or missing secret = refused.
-- The function can only insert reports through svc_ingest_report (which validates the
-- contract and refuses mixed live/synthetic data); it cannot read or change anything else.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.ingest_secret (
  id          int primary key default 1 check (id = 1),   -- single row
  secret_hash text not null check (secret_hash ~ '^[0-9a-f]{64}$'),
  created_at  timestamptz not null default now()
);
revoke all on private.ingest_secret from public, anon, authenticated;
alter table private.ingest_secret enable row level security;

create or replace function public.n8n_ingest_report(p_report jsonb)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  supplied text := headers ->> 'x-ingest-secret';
  expected text := (select secret_hash from private.ingest_secret where id = 1);
begin
  if expected is null or supplied is null or length(supplied) < 32
     or encode(sha256(convert_to(supplied, 'UTF8')), 'hex') <> expected then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  if p_report ->> 'data_mode' is distinct from 'live' then
    raise exception 'Only live reports are accepted from n8n' using errcode = '22023';
  end if;
  return public.svc_ingest_report(p_report);
end $$;

revoke execute on function public.n8n_ingest_report(jsonb) from public, authenticated;
grant  execute on function public.n8n_ingest_report(jsonb) to anon;
