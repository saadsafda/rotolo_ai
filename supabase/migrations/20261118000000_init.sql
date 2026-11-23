-- Rotolo operations app — initial schema.
-- Target: Supabase Postgres. All money is integer minor units (cents).
-- Vendor credentials never live in this database; n8n holds them.
-- App clients get read access through RLS and change state only via the RPCs below.
-- n8n/Edge Functions use service_role-only RPCs.

create extension if not exists pgcrypto;

-- ───────────────────────── Roles & access ─────────────────────────
create type public.app_role as enum ('owner', 'admin', 'staff');

create table public.profiles (
  id                  uuid primary key references auth.users (id) on delete cascade,
  display_name        text not null,
  role                public.app_role not null default 'staff',
  can_submit_payments boolean not null default false,
  can_review_payments boolean not null default false,
  active              boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Which report sources each role may read. Staff default to deals only until
-- the owner confirms access to tenant / financial / employee data.
create table public.section_access (
  role    public.app_role not null,
  source  text not null,
  allowed boolean not null,
  primary key (role, source)
);

create table public.app_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

insert into public.app_config (key, value) values
  ('business_timezone',        '"America/New_York"'),
  ('stale_after_hours',        '26'),
  ('ai_summary_model',         '"gpt-5-nano"'),
  -- Financial writes stay off until workflow 02 mapping, permissions and
  -- approval behaviour are verified. Only a service_role migration may flip it.
  ('doorloop_posting_enabled', 'false'),
  ('allow_self_approval',      'false');

create or replace function public.current_app_role() returns public.app_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create or replace function public.can_read_source(p_source text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select sa.allowed from public.section_access sa
    where sa.role = public.current_app_role() and sa.source = p_source
  ), false)
$$;

create or replace function public.is_owner_or_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_app_role() in ('owner', 'admin'), false)
$$;

-- ───────────────────────── Sync runs & reports ─────────────────────────
create table public.sync_runs (
  id               uuid primary key default gen_random_uuid(),
  requested_by     uuid references auth.users (id),
  trigger          text not null check (trigger in ('app', 'schedule', 'manual')),
  data_mode        text not null check (data_mode in ('live', 'synthetic')),
  status           text not null default 'queued'
                   check (status in ('queued', 'running', 'succeeded', 'partial', 'failed', 'timed_out')),
  stage            text,
  progress         jsonb not null default '[]'::jsonb,   -- [{stage, status, at, detail}]
  error            text,
  n8n_execution_id text,
  report_id        uuid,
  created_at       timestamptz not null default now(),
  started_at       timestamptz,
  finished_at      timestamptz
);
-- At most one active run: double-taps on "Refresh" cannot start parallel collections.
create unique index sync_runs_one_active on public.sync_runs ((true))
  where status in ('queued', 'running');

create table public.reports (
  id               uuid primary key default gen_random_uuid(),
  report_key       text not null,
  business_date    date not null,
  timezone         text not null,
  data_mode        text not null check (data_mode in ('live', 'synthetic')),
  status           text not null check (status in ('complete', 'partial', 'failed')),
  generated_at     timestamptz not null,
  contract_version text not null,
  sync_run_id      uuid references public.sync_runs (id),
  created_at       timestamptz not null default now(),
  unique (report_key, sync_run_id)
);
create index reports_by_date on public.reports (business_date desc, generated_at desc);

alter table public.sync_runs
  add constraint sync_runs_report_fk foreign key (report_id) references public.reports (id);

create table public.report_sections (
  id           uuid primary key default gen_random_uuid(),
  report_id    uuid not null references public.reports (id) on delete cascade,
  source       text not null check (source in
                 ('ai_summary', 'fub_deals', 'email_evidence', 'doorloop_rent', 'doorloop_tasks', 'time_doctor')),
  status       text not null check (status in ('complete', 'partial', 'unavailable')),
  data_mode    text not null check (data_mode in ('live', 'synthetic')),
  collected_at timestamptz,
  cutoff       jsonb not null,           -- {kind: snapshot|business_day|lookback, ...}
  coverage     jsonb not null default '{}'::jsonb,
  warnings     jsonb not null default '[]'::jsonb,
  payload      jsonb not null default '{}'::jsonb,
  workflow_id  text,
  execution_id text,
  unique (report_id, source)
);

create table public.external_refs (
  id          uuid primary key default gen_random_uuid(),
  system      text not null check (system in ('fub', 'doorloop', 'gmail', 'time_doctor')),
  record_type text not null,
  external_id text not null,
  url         text,
  label       text,
  unique (system, record_type, external_id)
);

-- App-side review of DoorLoop tasks: a contractor's claim is not verification.
create table public.task_reviews (
  task_id        text primary key,           -- DoorLoop task id
  review_status  text not null default 'not_reviewed'
                 check (review_status in ('not_reviewed', 'claimed_complete', 'verified_complete', 'disputed')),
  evidence_paths text[] not null default '{}',
  notes          text,
  reviewed_by    uuid references auth.users (id),
  reviewed_at    timestamptz,
  updated_at     timestamptz not null default now()
);

-- ───────────────────────── Outside payments ─────────────────────────
create table public.payment_submissions (
  id                   uuid primary key default gen_random_uuid(),
  idempotency_key      uuid not null unique,              -- generated by the app when the form opens
  submitted_by         uuid not null references auth.users (id),
  property_id          text,
  property_name        text,
  unit                 text,
  tenant_name          text,
  lease_id             text not null check (lease_id ~ '^[a-f0-9]{24}$'),
  amount_minor         bigint not null check (amount_minor > 0 and amount_minor <= 5000000),
  currency             char(3) not null default 'USD' check (currency = 'USD'),
  payment_date         date not null,
  method               text not null check (method in ('EFT', 'CASH', 'CHECK', 'MONEY_ORDER', 'CASHIERS_CHECK', 'OTHER')),
  method_detail        text,                               -- e.g. Zelle, Venmo (maps to EFT)
  reference            text not null check (reference ~ '^[A-Z0-9._/-]{3,100}$'),
  notes                text,
  receipt_path         text,                               -- private storage object path
  funds_confirmed      boolean not null check (funds_confirmed),  -- submitter attests money actually received
  status               text not null default 'submitted' check (status in
                         ('submitted', 'under_review', 'approved', 'rejected', 'posting', 'posted', 'failed')),
  failure_kind         text check (failure_kind in ('rejected_by_doorloop', 'outcome_unknown', 'precheck_blocked')),
  reconciled_absent    boolean not null default false,     -- set after a failed post is confirmed absent in DoorLoop
  doorloop_payment_id  text,
  reviewed_by          uuid references auth.users (id),
  reviewed_at          timestamptz,
  decision_reason      text,
  -- Same business key as workflow 02 (lease|method|reference).
  duplicate_key        text generated always as (lease_id || '|' || method || '|' || reference) stored,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
-- One live submission per real-world payment; a rejected one can be resubmitted.
create unique index payment_submissions_one_live on public.payment_submissions (duplicate_key)
  where status <> 'rejected';

create table public.payment_events (
  id            bigserial primary key,
  submission_id uuid not null references public.payment_submissions (id),
  from_status   text,
  to_status     text not null,
  actor         uuid,
  actor_kind    text not null check (actor_kind in ('user', 'n8n', 'system')),
  detail        jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

create table public.posting_attempts (
  id                  uuid primary key default gen_random_uuid(),
  submission_id       uuid not null references public.payment_submissions (id),
  started_at          timestamptz not null default now(),
  finished_at         timestamptz,
  outcome             text not null default 'pending'
                      check (outcome in ('pending', 'posted', 'rejected', 'unknown', 'blocked')),
  doorloop_payment_id text,
  response_summary    jsonb,
  n8n_execution_id    text
);
create unique index posting_attempts_one_pending on public.posting_attempts (submission_id)
  where outcome = 'pending';

create table public.device_tokens (
  token        text primary key,
  user_id      uuid not null references auth.users (id) on delete cascade,
  platform     text not null check (platform in ('android', 'ios')),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create table public.audit_events (
  id         bigserial primary key,
  actor      uuid,
  actor_kind text not null check (actor_kind in ('user', 'n8n', 'system')),
  action     text not null,
  entity     text not null,
  entity_id  text,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- ───────────────────────── Payment state machine ─────────────────────────
-- Enforced for every caller, including service_role.
create or replace function public.payment_guard() returns trigger
language plpgsql as $$
declare
  ok boolean;
begin
  if new.lease_id is distinct from old.lease_id
     or new.amount_minor is distinct from old.amount_minor
     or new.currency is distinct from old.currency
     or new.payment_date is distinct from old.payment_date
     or new.method is distinct from old.method
     or new.reference is distinct from old.reference
     or new.idempotency_key is distinct from old.idempotency_key
     or new.submitted_by is distinct from old.submitted_by then
    raise exception 'Financial fields of a submission are immutable' using errcode = 'P0001';
  end if;

  if new.status is distinct from old.status then
    ok := (old.status, new.status) in (
      ('submitted', 'under_review'), ('submitted', 'rejected'),
      ('under_review', 'approved'), ('under_review', 'rejected'),
      ('approved', 'posting'),
      ('posting', 'posted'), ('posting', 'failed'),
      ('failed', 'posting'), ('failed', 'rejected'));
    if not ok then
      raise exception 'Illegal payment transition % -> %', old.status, new.status using errcode = 'P0001';
    end if;
    -- A post whose outcome is unknown must be reconciled before another attempt.
    if old.status = 'failed' and new.status = 'posting' and not new.reconciled_absent then
      raise exception 'Reconcile the failed post in DoorLoop before retrying' using errcode = 'P0001';
    end if;
  end if;

  if old.status = 'posted' then
    raise exception 'Posted submissions are final' using errcode = 'P0001';
  end if;

  new.updated_at := now();
  return new;
end $$;

create trigger payment_guard before update on public.payment_submissions
  for each row execute function public.payment_guard();

create or replace function public.payment_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into payment_events (submission_id, from_status, to_status, actor, actor_kind)
    values (new.id, null, new.status, auth.uid(), case when auth.uid() is null then 'system' else 'user' end);
  elsif new.status is distinct from old.status then
    insert into payment_events (submission_id, from_status, to_status, actor, actor_kind, detail)
    values (new.id, old.status, new.status, auth.uid(),
            case when auth.uid() is null then 'n8n' else 'user' end,
            jsonb_build_object('reason', new.decision_reason, 'failure_kind', new.failure_kind,
                               'doorloop_payment_id', new.doorloop_payment_id));
  end if;
  return new;
end $$;

create trigger payment_log after insert or update on public.payment_submissions
  for each row execute function public.payment_log();

-- ───────────────────────── App RPCs (authenticated) ─────────────────────────
create or replace function public.submit_outside_payment(
  p_idempotency_key uuid, p_lease_id text, p_amount_minor bigint, p_currency text,
  p_payment_date date, p_method text, p_method_detail text, p_reference text,
  p_property_id text, p_property_name text, p_unit text, p_tenant_name text,
  p_notes text, p_receipt_path text, p_funds_confirmed boolean)
returns public.payment_submissions
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  existing public.payment_submissions;
  row public.payment_submissions;
  tz text := (select value #>> '{}' from app_config where key = 'business_timezone');
begin
  select * into me from profiles where id = auth.uid() and active;
  if me.id is null or not (me.can_submit_payments or me.role = 'owner') then
    raise exception 'Not authorised to submit payments' using errcode = '42501';
  end if;

  -- Idempotent replay: same key returns the original row; a different payload is an error.
  select * into existing from payment_submissions where idempotency_key = p_idempotency_key;
  if existing.id is not null then
    if existing.lease_id = lower(p_lease_id) and existing.amount_minor = p_amount_minor
       and existing.reference = upper(trim(p_reference)) and existing.payment_date = p_payment_date
       and existing.method = p_method then
      return existing;
    end if;
    raise exception 'Idempotency key reused with a different payment' using errcode = '23505';
  end if;

  if p_payment_date > (now() at time zone tz)::date
     or p_payment_date < (now() at time zone tz)::date - 90 then
    raise exception 'Payment date outside the allowed range' using errcode = '22023';
  end if;

  insert into payment_submissions (
    idempotency_key, submitted_by, lease_id, amount_minor, currency, payment_date, method,
    method_detail, reference, property_id, property_name, unit, tenant_name, notes,
    receipt_path, funds_confirmed)
  values (
    p_idempotency_key, auth.uid(), lower(p_lease_id), p_amount_minor, upper(p_currency), p_payment_date,
    p_method, p_method_detail, upper(trim(p_reference)), p_property_id, p_property_name, p_unit,
    p_tenant_name, p_notes, p_receipt_path, coalesce(p_funds_confirmed, false))
  returning * into row;

  insert into audit_events (actor, actor_kind, action, entity, entity_id)
  values (auth.uid(), 'user', 'payment.submitted', 'payment_submission', row.id::text);
  return row;
end $$;

create or replace function public.review_outside_payment(
  p_submission_id uuid, p_action text, p_reason text default null)
returns public.payment_submissions
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  sub public.payment_submissions;
  self_ok boolean := (select (value #>> '{}')::boolean from app_config where key = 'allow_self_approval');
  target text;
begin
  select * into me from profiles where id = auth.uid() and active;
  if me.id is null or not me.can_review_payments then
    raise exception 'Not authorised to review payments' using errcode = '42501';
  end if;

  select * into sub from payment_submissions where id = p_submission_id for update;
  if sub.id is null then raise exception 'Submission not found' using errcode = 'P0002'; end if;

  target := case p_action
    when 'start_review' then 'under_review'
    when 'approve' then 'approved'
    when 'reject' then 'rejected'
    else null end;
  if target is null then raise exception 'Unknown review action %', p_action; end if;

  if target = 'approved' and sub.submitted_by = auth.uid() and not self_ok then
    raise exception 'A submitter cannot approve their own payment' using errcode = '42501';
  end if;
  if target = 'rejected' and coalesce(trim(p_reason), '') = '' then
    raise exception 'A rejection reason is required' using errcode = '22023';
  end if;

  update payment_submissions
     set status = target,
         reviewed_by = case when target in ('approved', 'rejected') then auth.uid() else reviewed_by end,
         reviewed_at = case when target in ('approved', 'rejected') then now() else reviewed_at end,
         decision_reason = coalesce(p_reason, decision_reason)
   where id = p_submission_id
  returning * into sub;

  insert into audit_events (actor, actor_kind, action, entity, entity_id, detail)
  values (auth.uid(), 'user', 'payment.' || p_action, 'payment_submission', sub.id::text,
          jsonb_build_object('reason', p_reason));
  return sub;
end $$;

create or replace function public.set_task_review(
  p_task_id text, p_status text, p_notes text, p_evidence_paths text[])
returns public.task_reviews
language plpgsql security definer set search_path = public as $$
declare row public.task_reviews;
begin
  if not public.can_read_source('doorloop_tasks') then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  -- Only owner/admin can mark a task independently verified.
  if p_status in ('verified_complete', 'disputed') and not public.is_owner_or_admin() then
    raise exception 'Only owner/admin can verify task completion' using errcode = '42501';
  end if;
  insert into task_reviews (task_id, review_status, notes, evidence_paths, reviewed_by, reviewed_at)
  values (p_task_id, p_status, p_notes, coalesce(p_evidence_paths, '{}'), auth.uid(), now())
  on conflict (task_id) do update
    set review_status = excluded.review_status, notes = excluded.notes,
        evidence_paths = excluded.evidence_paths, reviewed_by = excluded.reviewed_by,
        reviewed_at = excluded.reviewed_at, updated_at = now()
  returning * into row;
  insert into audit_events (actor, actor_kind, action, entity, entity_id, detail)
  values (auth.uid(), 'user', 'task.review', 'task', p_task_id, jsonb_build_object('status', p_status));
  return row;
end $$;

create or replace function public.register_device_token(p_token text, p_platform text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_app_role() is null then raise exception 'Not authorised' using errcode = '42501'; end if;
  insert into device_tokens (token, user_id, platform) values (p_token, auth.uid(), p_platform)
  on conflict (token) do update set user_id = auth.uid(), platform = excluded.platform, last_seen_at = now();
end $$;

-- ───────────────────────── Service RPCs (Edge Functions / n8n only) ─────────────────────────
create or replace function public.svc_begin_posting(p_submission_id uuid)
returns public.posting_attempts
language plpgsql security definer set search_path = public as $$
declare
  sub public.payment_submissions;
  attempt public.posting_attempts;
begin
  if not (select (value #>> '{}')::boolean from app_config where key = 'doorloop_posting_enabled') then
    raise exception 'DoorLoop posting is disabled' using errcode = '42501';
  end if;
  -- Atomic claim: only one caller can move approved/failed -> posting.
  update payment_submissions set status = 'posting', failure_kind = null
   where id = p_submission_id
     and (status = 'approved' or (status = 'failed' and reconciled_absent))
  returning * into sub;
  if sub.id is null then
    raise exception 'Submission is not approved or is already posting' using errcode = '55000';
  end if;
  insert into posting_attempts (submission_id) values (sub.id) returning * into attempt;
  return attempt;
end $$;

create or replace function public.svc_finish_posting(
  p_attempt_id uuid, p_outcome text, p_doorloop_payment_id text, p_summary jsonb, p_execution_id text)
returns public.payment_submissions
language plpgsql security definer set search_path = public as $$
declare
  att public.posting_attempts;
  sub public.payment_submissions;
begin
  update posting_attempts
     set outcome = p_outcome, finished_at = now(), doorloop_payment_id = p_doorloop_payment_id,
         response_summary = p_summary, n8n_execution_id = p_execution_id
   where id = p_attempt_id and outcome = 'pending'
  returning * into att;
  if att.id is null then raise exception 'Attempt not pending' using errcode = '55000'; end if;

  update payment_submissions
     set status = case when p_outcome = 'posted' then 'posted' else 'failed' end,
         doorloop_payment_id = case when p_outcome = 'posted' then p_doorloop_payment_id else doorloop_payment_id end,
         failure_kind = case p_outcome when 'posted' then null
                                      when 'rejected' then 'rejected_by_doorloop'
                                      when 'blocked' then 'precheck_blocked'
                                      else 'outcome_unknown' end,
         reconciled_absent = case when p_outcome in ('rejected', 'blocked') then true else false end
   where id = att.submission_id
  returning * into sub;
  return sub;
end $$;

create or replace function public.svc_mark_reconciled_absent(p_submission_id uuid, p_evidence jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  update payment_submissions set reconciled_absent = true
   where id = p_submission_id and status = 'failed';
  insert into audit_events (actor_kind, action, entity, entity_id, detail)
  values ('n8n', 'payment.reconciled_absent', 'payment_submission', p_submission_id::text, p_evidence);
end $$;

create or replace function public.svc_ingest_report(p_report jsonb)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  rid uuid;
  sec jsonb;
  run uuid := nullif(p_report ->> 'sync_run_id', '')::uuid;
begin
  if p_report ->> 'contract_version' is distinct from '1.0' then
    raise exception 'Unsupported contract_version %', p_report ->> 'contract_version';
  end if;
  insert into reports (report_key, business_date, timezone, data_mode, status, generated_at,
                       contract_version, sync_run_id)
  values (p_report ->> 'report_key', (p_report ->> 'business_date')::date, p_report ->> 'timezone',
          p_report ->> 'data_mode', p_report ->> 'status', (p_report ->> 'generated_at')::timestamptz,
          p_report ->> 'contract_version', run)
  returning id into rid;

  for sec in select * from jsonb_array_elements(p_report -> 'sections') loop
    -- A synthetic report can never contain a section claiming to be live, and vice versa.
    if sec ->> 'data_mode' is distinct from p_report ->> 'data_mode' then
      raise exception 'Section % data_mode does not match report', sec ->> 'source';
    end if;
    insert into report_sections (report_id, source, status, data_mode, collected_at, cutoff, coverage,
                                 warnings, payload, workflow_id, execution_id)
    values (rid, sec ->> 'source', sec ->> 'status', sec ->> 'data_mode',
            nullif(sec ->> 'collected_at', '')::timestamptz, sec -> 'cutoff',
            coalesce(sec -> 'coverage', '{}'), coalesce(sec -> 'warnings', '[]'),
            coalesce(sec -> 'payload', '{}'), sec #>> '{workflow,id}', sec #>> '{workflow,execution_id}');
  end loop;

  if run is not null then
    update sync_runs
       set status = case p_report ->> 'status' when 'complete' then 'succeeded'
                                               when 'partial' then 'partial' else 'failed' end,
           report_id = rid, finished_at = now()
     where id = run;
  end if;
  insert into audit_events (actor_kind, action, entity, entity_id)
  values ('n8n', 'report.ingested', 'report', rid::text);
  return rid;
end $$;

create or replace function public.svc_sync_progress(p_run uuid, p_stage text, p_status text, p_detail jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  update sync_runs
     set status = case when status = 'queued' then 'running' else status end,
         started_at = coalesce(started_at, now()),
         stage = p_stage,
         progress = progress || jsonb_build_array(jsonb_build_object(
                      'stage', p_stage, 'status', p_status, 'at', now(), 'detail', p_detail))
   where id = p_run and status in ('queued', 'running');
end $$;

-- ───────────────────────── RLS ─────────────────────────
alter table public.profiles            enable row level security;
alter table public.section_access      enable row level security;
alter table public.app_config          enable row level security;
alter table public.sync_runs           enable row level security;
alter table public.reports             enable row level security;
alter table public.report_sections     enable row level security;
alter table public.external_refs       enable row level security;
alter table public.task_reviews        enable row level security;
alter table public.payment_submissions enable row level security;
alter table public.payment_events      enable row level security;
alter table public.posting_attempts    enable row level security;
alter table public.device_tokens       enable row level security;
alter table public.audit_events        enable row level security;

create policy profiles_self on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_owner_or_admin());
create policy section_access_read on public.section_access for select to authenticated using (true);
create policy app_config_read on public.app_config for select to authenticated
  using (public.current_app_role() is not null);
create policy sync_runs_read on public.sync_runs for select to authenticated using (public.is_owner_or_admin());
create policy reports_read on public.reports for select to authenticated
  using (public.current_app_role() is not null);
create policy report_sections_read on public.report_sections for select to authenticated
  using (public.can_read_source(source));
create policy external_refs_read on public.external_refs for select to authenticated
  using (public.current_app_role() is not null);
create policy task_reviews_read on public.task_reviews for select to authenticated
  using (public.can_read_source('doorloop_tasks'));
create policy payments_read on public.payment_submissions for select to authenticated
  using (submitted_by = auth.uid()
         or exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.can_review_payments));
create policy payment_events_read on public.payment_events for select to authenticated
  using (exists (select 1 from public.payment_submissions s where s.id = submission_id));  -- inherits parent RLS
create policy posting_attempts_read on public.posting_attempts for select to authenticated
  using (exists (select 1 from public.payment_submissions s where s.id = submission_id));
create policy device_tokens_own on public.device_tokens for select to authenticated using (user_id = auth.uid());
create policy audit_read on public.audit_events for select to authenticated
  using (public.current_app_role() = 'owner');
-- No insert/update/delete policies: authenticated clients write only through the RPCs above.
-- Defence in depth: remove Supabase's default table write grants for API roles.
revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;
revoke all on all tables in schema public from anon;

revoke execute on function public.svc_begin_posting(uuid)                              from public, anon, authenticated;
revoke execute on function public.svc_finish_posting(uuid, text, text, jsonb, text)    from public, anon, authenticated;
revoke execute on function public.svc_mark_reconciled_absent(uuid, jsonb)              from public, anon, authenticated;
revoke execute on function public.svc_ingest_report(jsonb)                             from public, anon, authenticated;
revoke execute on function public.svc_sync_progress(uuid, text, text, jsonb)           from public, anon, authenticated;
grant  execute on function public.svc_begin_posting(uuid)                              to service_role;
grant  execute on function public.svc_finish_posting(uuid, text, text, jsonb, text)    to service_role;
grant  execute on function public.svc_mark_reconciled_absent(uuid, jsonb)              to service_role;
grant  execute on function public.svc_ingest_report(jsonb)                             to service_role;
grant  execute on function public.svc_sync_progress(uuid, text, text, jsonb)           to service_role;

-- ───────────────────────── Defaults ─────────────────────────
insert into public.section_access (role, source, allowed)
select r.role, s.source,
       case when r.role in ('owner', 'admin') then true
            when s.source = 'fub_deals' then true      -- staff: deals only, pending owner decision
            else false end
from (values ('owner'::public.app_role), ('admin'), ('staff')) r(role)
cross join (values ('ai_summary'), ('fub_deals'), ('email_evidence'), ('doorloop_rent'),
                   ('doorloop_tasks'), ('time_doctor')) s(source);

-- Private receipt bucket (Supabase storage). Objects stored at <user_id>/<idempotency_key>/<file>.
insert into storage.buckets (id, name, public) values ('payment-receipts', 'payment-receipts', false)
on conflict (id) do nothing;
create policy receipts_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'payment-receipts' and (storage.foldername(name))[1] = auth.uid()::text);
create policy receipts_read on storage.objects for select to authenticated
  using (bucket_id = 'payment-receipts' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.can_review_payments)));
