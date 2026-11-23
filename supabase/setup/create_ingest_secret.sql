-- Run ONCE in the Supabase SQL Editor (after migration 20261121000000_n8n_ingest.sql).
-- It creates a random secret, stores only its SHA-256 hash, and shows the secret ONE time.
-- Copy the value straight into the n8n credential "Rotolo App - Ingest Secret" (Header Auth,
-- name: x-ingest-secret). Keep it out of chat and logs. If a credential already exists,
-- this query returns no row.
with s as (
  select replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') as secret
), saved as (
  insert into private.ingest_secret (id, secret_hash, created_at)
  select 1, encode(sha256(convert_to(secret, 'UTF8')), 'hex'), now() from s
  on conflict (id) do nothing
  returning id
)
select s.secret as copy_into_n8n_once from s, saved;
