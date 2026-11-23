-- Behavioural tests for the init migration. Run with supabase/tests/run_local.sh.
\set ON_ERROR_STOP on

create or replace function public.t_expect_error(p_sql text, p_pattern text) returns void
language plpgsql as $$
begin
  execute p_sql;
  raise exception 'EXPECTED ERROR matching "%" but statement succeeded: %', p_pattern, p_sql;
exception when others then
  if sqlerrm like 'EXPECTED ERROR%' then raise; end if;
  if sqlerrm !~* p_pattern then
    raise exception 'Wrong error for %: got "%", expected "%"', p_sql, sqlerrm, p_pattern;
  end if;
end $$;

create or replace function public.t_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), false);
end $$;

-- Fixtures (superuser)
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.test'),
  ('00000000-0000-0000-0000-00000000000b', 'admin@example.test'),
  ('00000000-0000-0000-0000-00000000000c', 'staff@example.test');
insert into public.profiles (id, display_name, role, can_submit_payments, can_review_payments) values
  ('00000000-0000-0000-0000-00000000000a', 'Owner', 'owner', true, true),
  ('00000000-0000-0000-0000-00000000000b', 'Admin', 'admin', true, false),
  ('00000000-0000-0000-0000-00000000000c', 'Staff', 'staff', false, false);

-- Report ingestion (service role)
set role service_role;
select public.svc_ingest_report(jsonb_build_object(
  'contract_version', '1.0', 'report_key', 'OPS-20261118', 'business_date', '2026-11-18',
  'timezone', 'America/New_York', 'data_mode', 'synthetic', 'status', 'partial',
  'generated_at', '2026-11-18T14:05:00Z',
  'sections', jsonb_build_array(
    jsonb_build_object('source', 'fub_deals', 'status', 'complete', 'data_mode', 'synthetic',
                       'collected_at', '2026-11-18T14:01:00Z', 'cutoff', '{"kind":"snapshot","as_of":"2026-11-18T14:01:00Z"}'),
    jsonb_build_object('source', 'doorloop_rent', 'status', 'complete', 'data_mode', 'synthetic',
                       'collected_at', '2026-11-18T14:02:00Z', 'cutoff', '{"kind":"snapshot","as_of":"2026-11-18T14:02:00Z"}'),
    jsonb_build_object('source', 'time_doctor', 'status', 'partial', 'data_mode', 'synthetic',
                       'collected_at', '2026-11-18T14:03:00Z',
                       'cutoff', '{"kind":"business_day","date":"2026-11-17","timezone":"America/New_York"}'))));
-- Mixed live/synthetic sections are refused.
select public.t_expect_error($$select public.svc_ingest_report('{"contract_version":"1.0","report_key":"X","business_date":"2026-11-18","timezone":"America/New_York","data_mode":"live","status":"complete","generated_at":"2026-11-18T14:05:00Z","sections":[{"source":"fub_deals","status":"complete","data_mode":"synthetic","cutoff":{}}]}')$$,
  'data_mode does not match');
reset role;

-- Section visibility
set role authenticated;
select public.t_as('00000000-0000-0000-0000-00000000000c');
do $$ begin
  -- What the app reads right after sign-in.
  assert (select count(*) from public.profiles) = 1, 'staff reads only their own profile';
  assert (select count(*) from public.section_access where role = 'staff' and allowed) = 1, 'staff reads section access';
  assert (select count(*) from public.app_config) > 0, 'signed-in users read app config';
  assert (select count(*) from public.report_sections) = 1, 'staff should see only fub_deals';
  assert (select source from public.report_sections) = 'fub_deals', 'staff section must be fub_deals';
  assert (select count(*) from public.reports) = 1, 'staff can list reports';
end $$;
select public.t_as('00000000-0000-0000-0000-00000000000a');
do $$ begin assert (select count(*) from public.report_sections) = 3, 'owner sees all sections'; end $$;
select public.t_as(null);
do $$ begin assert (select count(*) from public.reports) = 0, 'unknown user sees nothing'; end $$;

-- Service RPCs are not callable by app users
select public.t_as('00000000-0000-0000-0000-00000000000a');
select public.t_expect_error($$select public.svc_ingest_report('{}')$$, 'permission denied');
select public.t_expect_error($$select public.svc_begin_posting(gen_random_uuid())$$, 'permission denied');

-- Submission permissions & idempotency
select public.t_as('00000000-0000-0000-0000-00000000000c');
select public.t_expect_error($$select public.submit_outside_payment('11111111-1111-1111-1111-111111111111','aaaaaaaaaaaaaaaaaaaaaaaa',50000,'USD',current_date,'EFT','Zelle','REF-1',null,null,null,null,null,null,true)$$,
  'Not authorised to submit');

select public.t_as('00000000-0000-0000-0000-00000000000b');
select id as sub1 from public.submit_outside_payment('11111111-1111-1111-1111-111111111111','aaaaaaaaaaaaaaaaaaaaaaaa',50000,'usd',current_date,'EFT','Zelle','ref-1','p1','Prop 1','2A','T. Tenant',null,null,true) \gset
-- Same key, same payload → same row (double tap / retry).
do $$ begin
  assert (select id from public.submit_outside_payment('11111111-1111-1111-1111-111111111111','aaaaaaaaaaaaaaaaaaaaaaaa',50000,'USD',current_date,'EFT','Zelle','REF-1',null,null,null,null,null,null,true))
         = (select id from public.payment_submissions where idempotency_key = '11111111-1111-1111-1111-111111111111'),
         'replay must return the original submission';
  assert (select count(*) from public.payment_submissions) = 1, 'replay must not create a second row';
end $$;
-- Same key, different amount → error.
select public.t_expect_error($$select public.submit_outside_payment('11111111-1111-1111-1111-111111111111','aaaaaaaaaaaaaaaaaaaaaaaa',60000,'USD',current_date,'EFT','Zelle','REF-1',null,null,null,null,null,null,true)$$,
  'Idempotency key reused');
-- New key, same lease/method/reference → duplicate business payment.
select public.t_expect_error($$select public.submit_outside_payment('22222222-2222-2222-2222-222222222222','aaaaaaaaaaaaaaaaaaaaaaaa',50000,'USD',current_date,'EFT','Zelle','REF-1',null,null,null,null,null,null,true)$$,
  'payment_submissions_one_live');
-- Validation
select public.t_expect_error($$select public.submit_outside_payment(gen_random_uuid(),'aaaaaaaaaaaaaaaaaaaaaaaa',-5,'USD',current_date,'EFT',null,'REF-2',null,null,null,null,null,null,true)$$, 'check constraint');
select public.t_expect_error($$select public.submit_outside_payment(gen_random_uuid(),'aaaaaaaaaaaaaaaaaaaaaaaa',500,'USD',current_date,'EFT',null,'REF-2',null,null,null,null,null,null,false)$$, 'check constraint');
select public.t_expect_error($$select public.submit_outside_payment(gen_random_uuid(),'not-a-lease',500,'USD',current_date,'EFT',null,'REF-2',null,null,null,null,null,null,true)$$, 'check constraint');
select public.t_expect_error($$select public.submit_outside_payment(gen_random_uuid(),'aaaaaaaaaaaaaaaaaaaaaaaa',500,'EUR',current_date,'EFT',null,'REF-2',null,null,null,null,null,null,true)$$, 'check constraint');
select public.t_expect_error($$select public.submit_outside_payment(gen_random_uuid(),'aaaaaaaaaaaaaaaaaaaaaaaa',500,'USD',current_date + 3,'EFT',null,'REF-2',null,null,null,null,null,null,true)$$, 'outside the allowed range');

-- No direct table writes from the app
select public.t_expect_error($$update public.payment_submissions set status = 'approved'$$, 'permission denied');
select public.t_expect_error($$insert into public.reports (report_key,business_date,timezone,data_mode,status,generated_at,contract_version) values ('x',current_date,'UTC','live','complete',now(),'1.0')$$, 'permission denied');

-- Review permissions
select public.t_expect_error(format('select public.review_outside_payment(%L,''approve'')', :'sub1'), 'Not authorised to review');
select public.t_as('00000000-0000-0000-0000-00000000000a');
select public.t_expect_error(format('select public.review_outside_payment(%L,''approve'')', :'sub1'), 'Illegal payment transition submitted -> approved');
select status from public.review_outside_payment(:'sub1', 'start_review');
select status from public.review_outside_payment(:'sub1', 'approve');

-- Self-approval is blocked by default
select id as sub2 from public.submit_outside_payment('33333333-3333-3333-3333-333333333333','bbbbbbbbbbbbbbbbbbbbbbbb',12345,'USD',current_date,'CHECK',null,'CHK-1001',null,null,null,null,null,null,true) \gset
select status from public.review_outside_payment(:'sub2', 'start_review');
select public.t_expect_error(format('select public.review_outside_payment(%L,''approve'')', :'sub2'), 'cannot approve their own');
select public.t_expect_error(format('select public.review_outside_payment(%L,''reject'')', :'sub2'), 'reason is required');
select status from public.review_outside_payment(:'sub2', 'reject', 'Duplicate of bank deposit');
reset role;

-- Posting (service role)
set role service_role;
select public.t_as(null);
select public.t_expect_error(format('select public.svc_begin_posting(%L)', :'sub1'), 'posting is disabled');
reset role;
update public.app_config set value = 'true' where key = 'doorloop_posting_enabled';
set role service_role;
select public.t_expect_error(format('select public.svc_begin_posting(%L)', :'sub2'), 'not approved');
select id as att1 from public.svc_begin_posting(:'sub1') \gset
-- Concurrent second claim fails.
select public.t_expect_error(format('select public.svc_begin_posting(%L)', :'sub1'), 'not approved or is already posting');
-- Ambiguous failure → must reconcile before retry.
select status, failure_kind from public.svc_finish_posting(:'att1', 'unknown', null, '{"http":504}', 'exec-1');
select public.t_expect_error(format('select public.svc_begin_posting(%L)', :'sub1'), 'not approved or is already posting');
select public.svc_mark_reconciled_absent(:'sub1', '{"lookup":"no payment with stable id"}');
select id as att2 from public.svc_begin_posting(:'sub1') \gset
select status, doorloop_payment_id from public.svc_finish_posting(:'att2', 'posted', 'dl_pay_123', '{"verified":true}', 'exec-2');
-- Posted is final; financial fields immutable.
select public.t_expect_error(format('update public.payment_submissions set notes = %L where id = %L', 'x', :'sub1'), 'Posted submissions are final');
reset role;
select public.t_expect_error(format('update public.payment_submissions set amount_minor = 1 where id = %L', :'sub2'), 'immutable');

-- Rejected payment can be resubmitted under a new key.
set role authenticated;
select public.t_as('00000000-0000-0000-0000-00000000000b');
select status from public.submit_outside_payment('44444444-4444-4444-4444-444444444444','bbbbbbbbbbbbbbbbbbbbbbbb',12345,'USD',current_date,'CHECK',null,'CHK-1001',null,null,null,null,null,null,true);
-- Admin (no review flag) sees only own submissions.
do $$ begin assert (select count(*) from public.payment_submissions) = 2, 'admin sees own two submissions'; end $$;
reset role;

-- Audit trail
do $$ begin
  assert (select array_agg(to_status order by id) from public.payment_events
          where submission_id = (select id from public.payment_submissions where idempotency_key = '11111111-1111-1111-1111-111111111111'))
       = array['submitted','under_review','approved','posting','failed','posting','posted'],
       'event trail for sub1';
end $$;

-- Payment comments (migration 20261119)
set role authenticated;
select public.t_as('00000000-0000-0000-0000-00000000000b');  -- admin: submitter of sub1
select body from public.add_payment_comment(:'sub1', '  Tenant sent the bank slip.  ');
select public.t_expect_error(format('select public.add_payment_comment(%L, %L)', :'sub1', '   '), 'empty');
select public.t_as('00000000-0000-0000-0000-00000000000c');  -- staff: neither submitter nor reviewer
select public.t_expect_error(format('select public.add_payment_comment(%L, %L)', :'sub1', 'hi'), 'Not authorised');
do $$ begin assert (select count(*) from public.payment_comments) = 0, 'staff cannot read others'' comments'; end $$;
select public.t_as('00000000-0000-0000-0000-00000000000a');  -- owner: reviewer
select body from public.add_payment_comment(:'sub1', 'Checked bank feed.');
do $$ begin
  assert (select count(*) from public.payment_comments) = 2, 'reviewer sees all comments';
  assert (select body from public.payment_comments order by created_at, id limit 1) in ('Tenant sent the bank slip.', 'Checked bank feed.'), 'body trimmed';
end $$;
select public.t_expect_error($$insert into public.payment_comments (submission_id, author, author_name, body) values (gen_random_uuid(), gen_random_uuid(), 'x', 'y')$$, 'permission denied');

-- Deal evidence reviews
select deal_id from public.mark_deal_evidence_reviewed(9001, null);
select public.t_as('00000000-0000-0000-0000-00000000000c');
select public.t_expect_error($$select public.mark_deal_evidence_reviewed(9001, null)$$, 'Only owner/admin');
do $$ begin assert (select count(*) from public.deal_evidence_reviews) = 0, 'staff cannot read evidence reviews (no email_evidence access)'; end $$;
select public.t_as('00000000-0000-0000-0000-00000000000a');
do $$ begin assert (select count(*) from public.deal_evidence_reviews) = 1, 'owner reads evidence reviews'; end $$;
select public.t_as(null);
reset role;

-- n8n ingest (migration 20261121): secret header required, live data only
insert into private.ingest_secret (id, secret_hash)
values (1, encode(sha256(convert_to('test-secret-0123456789abcdef0123456789abcdef', 'UTF8')), 'hex'));
set role anon;
select public.t_expect_error($$select public.n8n_ingest_report('{}')$$, 'Not authorised');
select set_config('request.headers', '{"x-ingest-secret":"wrong-secret-0123456789abcdef0123456789abcdef"}', false);
select public.t_expect_error($$select public.n8n_ingest_report('{}')$$, 'Not authorised');
select set_config('request.headers', '{"x-ingest-secret":"test-secret-0123456789abcdef0123456789abcdef"}', false);
select public.t_expect_error($$select public.n8n_ingest_report('{"data_mode":"synthetic"}')$$, 'Only live reports');
select public.n8n_ingest_report(jsonb_build_object(
  'contract_version', '1.0', 'report_key', 'OPS-20261120', 'business_date', '2026-11-20',
  'timezone', 'America/New_York', 'data_mode', 'live', 'status', 'complete',
  'generated_at', '2026-11-20T14:05:00Z',
  'sections', jsonb_build_array(jsonb_build_object('source', 'fub_deals', 'status', 'complete', 'data_mode', 'live',
     'collected_at', '2026-11-20T14:01:00Z', 'cutoff', '{"kind":"snapshot","as_of":"2026-11-20T14:01:00Z"}'))));
-- anon still cannot read anything or reach the secret
select public.t_expect_error($$select * from public.reports$$, 'permission denied');
select public.t_expect_error($$select * from private.ingest_secret$$, 'permission denied');
select public.t_expect_error($$select public.svc_ingest_report('{}')$$, 'permission denied');
select set_config('request.headers', '', false);
reset role;
do $$ begin assert (select count(*) from public.reports where data_mode = 'live') = 1, 'live report stored'; end $$;

-- Mobile queue: staff can't request, workers can't claim anonymously without the secret.
set role authenticated;
select public.t_as('00000000-0000-0000-0000-00000000000c');
select public.t_expect_error($$select public.request_app_report('live')$$, 'Only an owner');
select public.t_as('00000000-0000-0000-0000-00000000000a');
select public.request_app_report('synthetic') as app_run \gset
select public.request_app_report('synthetic') = :'app_run'::uuid as same_run \gset
\if :same_run
\else
  select 1 / 0;
\endif
select public.t_expect_error($$select public.request_app_report('live')$$, 'another mode');
reset role;

set role anon;
select public.t_expect_error($$select public.n8n_claim_app_report()$$, 'authentication failed');
select set_config('request.headers', '{"x-ingest-secret":"test-secret-0123456789abcdef0123456789abcdef"}', false);
select public.n8n_claim_app_report()->>'sync_run_id' = :'app_run' as claimed_run \gset
\if :claimed_run
\else
  select 1 / 0;
\endif
do $$ begin
  assert public.n8n_claim_app_report()->>'claimed' = 'false', 'one worker claims the active request';
end $$;
select public.n8n_app_report_progress(:'app_run', 'fub', 'running');
create temp table queue_completion as
select jsonb_build_object(
  'contract_version','1.0','sync_run_id', :'app_run', 'report_key','DEMO-OPS-20261120',
  'business_date','2026-11-20','timezone','America/New_York','data_mode','synthetic',
  'status','complete','generated_at',now(),
  'sections', jsonb_agg(jsonb_build_object(
    'source', source, 'status', case when source = 'time_doctor' then 'unavailable' else 'complete' end,
    'data_mode','synthetic', 'cutoff', jsonb_build_object('kind','snapshot','as_of', now())))
) as body from (values ('fub_deals'),('email_evidence'),('doorloop_rent'),('doorloop_tasks'),('time_doctor'),('ai_summary')) sources(source);
select public.t_expect_error($$select public.n8n_finish_app_report(jsonb_set(body,'{data_mode}','"live"')) from queue_completion$$, 'No matching active report');
select public.n8n_finish_app_report(body) as app_report from queue_completion \gset
select public.n8n_finish_app_report(body) = :'app_report'::uuid as same_report from queue_completion \gset
\if :same_report
\else
  select 1 / 0;
\endif
reset role;

set role authenticated;
select public.t_as('00000000-0000-0000-0000-00000000000a');
select public.app_report_progress(:'app_run')->>'status' = 'partial'
  and public.app_report_progress(:'app_run')->>'report_id' = :'app_report'
  and (select count(*) from public.report_sections where report_id=:'app_report') = 6 as stored_report \gset
\if :stored_report
\else
  select 1 / 0;
\endif
select public.request_app_report('live') as stale_run \gset
reset role;
update public.sync_runs set created_at = now() - interval '4 minutes' where id=:'stale_run';
set role authenticated;
select public.app_report_progress(:'stale_run')->>'status' = 'timed_out' as expired \gset
\if :expired
\else
  select 1 / 0;
\endif
reset role;

-- Push dispatch requires the service role and worker authentication, and only
-- sends once to users with an available report section and an opted-in device.
insert into public.device_tokens (token, user_id, platform) values
 ('owner-device', '00000000-0000-0000-0000-00000000000a', 'android'),
 ('staff-device', '00000000-0000-0000-0000-00000000000c', 'ios'),
 ('staff-opted-out', '00000000-0000-0000-0000-00000000000c', 'ios');
set role authenticated;
select public.t_as('00000000-0000-0000-0000-00000000000c');
select public.unregister_device_token('staff-opted-out');
select public.unregister_device_token('owner-device');
select public.t_expect_error($$select * from public.n8n_claim_report_push(null)$$, 'permission denied');
reset role;
delete from public.section_access where role = 'staff' and source = 'fub_deals';
select id as live_report from public.reports where data_mode = 'live' order by created_at desc limit 1 \gset
set role service_role;
select set_config('request.headers', '{}', false);
select public.t_expect_error($$select * from public.n8n_claim_report_push(null)$$, 'authentication failed');
select set_config('request.headers', '{"x-ingest-secret":"test-secret-0123456789abcdef0123456789abcdef"}', false);
select array_agg(token) = array['owner-device'] as push_visible from public.n8n_claim_report_push(:'live_report') \gset
\if :push_visible
\else
  select 1 / 0;
\endif
select count(*) = 0 as push_once from public.n8n_claim_report_push(:'live_report') \gset
\if :push_once
\else
  select 1 / 0;
\endif
reset role;
-- Receipts are scoped to their submitter and visible to reviewers only after submission.
grant select, insert on storage.objects to authenticated;
set role authenticated;
select public.t_as('00000000-0000-0000-0000-00000000000c');
select public.t_expect_error($$insert into storage.objects(bucket_id, name) values ('payment-receipts', '00000000-0000-0000-0000-00000000000c/88888888-8888-8888-8888-888888888888/' || repeat('c',64) || '.png')$$, 'row-level security');
select public.t_as('00000000-0000-0000-0000-00000000000b');
insert into storage.objects (bucket_id, name)
values ('payment-receipts', '00000000-0000-0000-0000-00000000000b/88888888-8888-8888-8888-888888888888/' || repeat('c',64) || '.png');
do $$ begin assert (select count(*) from storage.objects) = 1, 'submitter can read their upload for retries'; end $$;
select public.t_as('00000000-0000-0000-0000-00000000000a');
do $$ begin assert (select count(*) from storage.objects) = 0, 'reviewers cannot see unsubmitted files'; end $$;
select public.t_expect_error($$select public.submit_outside_payment(
 '88888888-8888-8888-8888-888888888888','aaaaaaaaaaaaaaaaaaaaaaaa',700,'USD',current_date,'EFT','Zelle','RECEIPT-01',
 null,null,null,null,null,'00000000-0000-0000-0000-00000000000b/88888888-8888-8888-8888-888888888888/' || repeat('c',64) || '.png',true
)$$, 'Receipt does not belong');
select public.t_as('00000000-0000-0000-0000-00000000000b');
select id from public.submit_outside_payment(
 '88888888-8888-8888-8888-888888888888','aaaaaaaaaaaaaaaaaaaaaaaa',700,'USD',current_date,'EFT','Zelle','RECEIPT-01',
 null,null,null,null,null,'00000000-0000-0000-0000-00000000000b/88888888-8888-8888-8888-888888888888/' || repeat('c',64) || '.png',true
);
select public.t_as('00000000-0000-0000-0000-00000000000a');
do $$ begin assert (select count(*) from storage.objects) = 1, 'reviewers can see submitted receipts'; end $$;
select public.t_as('00000000-0000-0000-0000-00000000000c');
do $$ begin assert (select count(*) from storage.objects) = 0, 'staff cannot read receipts'; end $$;

select public.register_report_device(repeat('q', 100), 'android', true);
reset role;
do $$ begin assert (select quiet_hours from public.device_tokens where token = repeat('q', 100)), 'quiet hours persist per device'; end $$;
set role authenticated;
select public.t_as('00000000-0000-0000-0000-00000000000b');
select public.register_device_token(repeat('q', 100), 'android');
reset role;
do $$ begin assert not (select quiet_hours from public.device_tokens where token = repeat('q', 100)), 'legacy app registration resets preferences on transfer'; end $$;

\echo ALL SCHEMA TESTS PASSED
