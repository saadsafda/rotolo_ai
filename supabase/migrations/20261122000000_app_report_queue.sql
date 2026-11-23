-- The app queues requests through Auth. Only the n8n worker can claim or complete them.
insert into public.app_config (key, value) values ('app_report_daily_enabled', 'false')
on conflict (key) do nothing;

create function private.check_report_worker()
returns void language plpgsql security definer set search_path = '' as $$
declare
  supplied text := (coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb)->>'x-ingest-secret';
  expected text := (select secret_hash from private.ingest_secret where id = 1);
begin
  if expected is null or supplied is null or length(supplied) < 32
     or encode(sha256(convert_to(supplied, 'UTF8')), 'hex') <> expected then
    raise exception 'Report worker authentication failed' using errcode = '42501';
  end if;
end $$;
revoke execute on function private.check_report_worker() from public;

create function private.expire_report_runs()
returns void language sql set search_path = '' as $$
  update public.sync_runs set status = 'timed_out', finished_at = now(),
    error = case when started_at is null then 'The report worker did not pick up this request.'
                 else 'Report collection exceeded its time limit.' end
  where (status = 'queued' and created_at < now() - interval '3 minutes')
     or (status = 'running' and started_at < now() - interval '15 minutes')
$$;
revoke execute on function private.expire_report_runs() from public;

create function public.request_app_report(p_mode text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  run public.sync_runs%rowtype;
begin
  if not public.is_owner_or_admin() then
    raise exception 'Only an owner or admin can refresh reports' using errcode = '42501';
  end if;
  if p_mode is null or p_mode not in ('live', 'synthetic') then
    raise exception 'Invalid report mode' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(60110463);
  perform private.expire_report_runs();
  select * into run from public.sync_runs where status in ('queued', 'running');
  if found then
    if run.data_mode <> p_mode then
      raise exception 'A report in another mode is already running. Try again after it finishes.';
    end if;
    return run.id;
  end if;
  insert into public.sync_runs (requested_by, trigger, data_mode)
  values (auth.uid(), 'app', p_mode) returning * into run;
  return run.id;
end $$;

create function public.app_report_progress(p_run uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_owner_or_admin() then
    raise exception 'Only an owner or admin can view refresh progress' using errcode = '42501';
  end if;
  perform private.expire_report_runs();
  return (select to_jsonb(r) from public.sync_runs r where r.id = p_run);
end $$;

create function public.n8n_claim_app_report()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  run public.sync_runs%rowtype;
  zone text := coalesce((select value #>> '{}' from public.app_config where key = 'business_timezone'), 'America/New_York');
  model text := coalesce((select value #>> '{}' from public.app_config where key = 'ai_summary_model'), 'gpt-5-nano');
  local_now timestamp := now() at time zone zone;
begin
  perform private.check_report_worker();
  -- Serialize daily scheduling with app requests and concurrent worker ticks.
  perform pg_advisory_xact_lock(60110463);
  perform private.expire_report_runs();
  select * into run from public.sync_runs where status in ('queued', 'running') for update;
  if run.status = 'running' then return jsonb_build_object('claimed', false); end if;
  if run.id is null
     and (select value = 'true'::jsonb from public.app_config where key = 'app_report_daily_enabled')
     and local_now::time >= time '09:00'
     and not exists (select 1 from public.sync_runs
                      where trigger = 'schedule' and (created_at at time zone zone)::date = local_now::date) then
    insert into public.sync_runs (trigger, data_mode) values ('schedule', 'live') returning * into run;
  end if;
  if run.id is null then return jsonb_build_object('claimed', false); end if;
  update public.sync_runs set status = 'running', started_at = now() where id = run.id;
  return jsonb_build_object('claimed', true, 'sync_run_id', run.id, 'mode', run.data_mode,
    'timezone', zone, 'model', model, 'business_date', local_now::date);
end $$;

create function public.n8n_app_report_progress(p_run uuid, p_stage text, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_report_worker();
  if p_stage is null or p_stage not in ('fub', 'email', 'doorloop', 'time_doctor', 'summary', 'store')
    or p_status is null or p_status not in ('running', 'ok', 'partial', 'failed') then
    raise exception 'Invalid report stage' using errcode = '22023';
  end if;
  perform public.svc_sync_progress(p_run, p_stage, p_status, null);
end $$;

create function public.n8n_finish_app_report(p_report jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  run public.sync_runs%rowtype;
  section_count int;
  unavailable_count int;
  complete_count int;
  status_value text;
  section jsonb;
  progress_stage text;
begin
  perform private.check_report_worker();
  perform private.expire_report_runs();
  select * into run from public.sync_runs where id = (p_report->>'sync_run_id')::uuid for update;
  if run.report_id is not null then return run.report_id; end if;
  if run.status is distinct from 'running' or p_report->>'data_mode' is distinct from run.data_mode then
    raise exception 'No matching active report request' using errcode = '22023';
  end if;
  select count(*), count(*) filter (where s->>'status' = 'unavailable' and s->>'source' <> 'ai_summary'),
    count(*) filter (where s->>'status' = 'complete')
  into section_count, unavailable_count, complete_count
  from jsonb_array_elements(p_report->'sections') s;
  if section_count <> 6 then raise exception 'Expected six report sections' using errcode = '22023'; end if;
  status_value := case when unavailable_count = 5 then 'failed' when complete_count = 6 then 'complete' else 'partial' end;
  for section in select * from jsonb_array_elements(p_report->'sections') loop
    progress_stage := case section->>'source'
      when 'fub_deals' then 'fub' when 'email_evidence' then 'email'
      when 'doorloop_rent' then 'doorloop' when 'time_doctor' then 'time_doctor'
      when 'ai_summary' then 'summary' end;
    if progress_stage is not null then
      perform public.svc_sync_progress(run.id, progress_stage,
        case section->>'status' when 'complete' then 'ok' when 'partial' then 'partial' else 'failed' end, null);
    end if;
  end loop;
  perform public.svc_sync_progress(run.id, 'store', 'ok', null);
  return public.svc_ingest_report(jsonb_set(p_report, '{status}', to_jsonb(status_value)));
end $$;

revoke execute on function public.request_app_report(text), public.app_report_progress(uuid)
  from public, anon;
grant execute on function public.request_app_report(text), public.app_report_progress(uuid) to authenticated;
revoke execute on function public.n8n_claim_app_report(), public.n8n_app_report_progress(uuid, text, text),
  public.n8n_finish_app_report(jsonb) from public, authenticated;
grant execute on function public.n8n_claim_app_report(), public.n8n_app_report_progress(uuid, text, text),
  public.n8n_finish_app_report(jsonb) to anon;
