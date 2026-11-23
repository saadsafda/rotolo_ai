create function public.unregister_device_token(p_token text)
returns void language sql security definer set search_path = '' as $$
  delete from public.device_tokens where user_id = auth.uid() and token = p_token
$$;
revoke execute on function public.unregister_device_token(text) from public, anon;
grant execute on function public.unregister_device_token(text) to authenticated;

-- Only the report worker can claim a dispatch. A report gets at most one batch,
-- including when n8n retries after a response is lost.
create table private.report_push_dispatch (
  report_id uuid primary key references public.reports(id) on delete cascade,
  claimed_at timestamptz not null default now()
);
alter table private.report_push_dispatch enable row level security;

create function public.n8n_claim_report_push(p_report_id uuid)
returns table(token text)
language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_report_worker();
  insert into private.report_push_dispatch(report_id)
    select r.id from public.reports r
    where r.id = p_report_id and r.data_mode = 'live'
      and r.status in ('complete', 'partial')
  on conflict do nothing;
  if not found then return; end if;

  return query
  select d.token from public.device_tokens d
  join public.profiles p on p.id = d.user_id and p.active
  where d.last_seen_at >= now() - interval '30 days'
    and exists (
      select from public.report_sections s
      join public.section_access a on a.source = s.source and a.role = p.role and a.allowed
      where s.report_id = p_report_id and s.status in ('complete', 'partial')
    );
end
$$;
revoke execute on function public.n8n_claim_report_push(uuid) from public, anon, authenticated;
grant execute on function public.n8n_claim_report_push(uuid) to service_role;
