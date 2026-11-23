-- Receipt files are private and immutable. Their key belongs to one payment.

update storage.buckets
set file_size_limit = 5242880, allowed_mime_types = array['image/jpeg', 'image/png']
where id = 'payment-receipts';

drop policy receipts_upload on storage.objects;
create policy receipts_upload on storage.objects for insert to authenticated
with check (
  bucket_id = 'payment-receipts'
  and cardinality(storage.foldername(name)) = 2
  and (storage.foldername(name))[1] = auth.uid()::text
  and (storage.foldername(name))[2] ~ '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'
  and split_part(name, '/', 3) ~ '^[a-f0-9]{64}[.](jpg|png)$'
  and exists (
    select from public.profiles p
    where p.id = auth.uid() and p.active and (p.can_submit_payments or p.role = 'owner')
  )
);

drop policy receipts_read on storage.objects;
create policy receipts_read on storage.objects for select to authenticated
using (
  bucket_id = 'payment-receipts' and exists (
    select from public.profiles p where p.id = auth.uid() and p.active
      and (
        (storage.foldername(name))[1] = p.id::text
        or (p.can_review_payments and exists (
          select from public.payment_submissions s where s.receipt_path = storage.objects.name
        ))
      )
  )
);

create function private.check_payment_receipt()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.receipt_path is null then return new; end if;
  if cardinality(storage.foldername(new.receipt_path)) is distinct from 2
     or (storage.foldername(new.receipt_path))[1] is distinct from new.submitted_by::text
     or (storage.foldername(new.receipt_path))[2] is distinct from new.idempotency_key::text
     or split_part(new.receipt_path, '/', 3) !~ '^[a-f0-9]{64}[.](jpg|png)$'
     or not exists (
       select from storage.objects where bucket_id = 'payment-receipts' and name = new.receipt_path
     ) then
    raise exception 'Receipt does not belong to this payment or has not been uploaded' using errcode = '22023';
  end if;
  return new;
end
$$;
revoke execute on function private.check_payment_receipt() from public, anon, authenticated;
create trigger check_payment_receipt before insert or update of receipt_path on public.payment_submissions
for each row execute function private.check_payment_receipt();

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

  -- Serialize retries for the same submission and scope replay to its submitter.
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 0));
  -- Idempotent replay: same key returns the original row; a different payload is an error.
  select * into existing from payment_submissions where idempotency_key = p_idempotency_key;
  if existing.id is not null then
    if existing.submitted_by = auth.uid()
       and existing.receipt_path is not distinct from p_receipt_path
       and existing.lease_id = lower(p_lease_id) and existing.amount_minor = p_amount_minor
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

-- Suppress report pushes during quiet hours on opted-in devices.

alter table public.device_tokens add column quiet_hours boolean not null default false;

create function public.register_report_device(p_token text, p_platform text, p_quiet_hours boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.current_app_role() is null then raise exception 'Not authorised' using errcode = '42501'; end if;
  insert into public.device_tokens (token, user_id, platform, quiet_hours)
    values (p_token, auth.uid(), p_platform, coalesce(p_quiet_hours, false))
  on conflict (token) do update set user_id = auth.uid(), platform = excluded.platform,
    quiet_hours = excluded.quiet_hours, last_seen_at = now();
end
$$;
revoke execute on function public.register_report_device(text, text, boolean) from public, anon;
grant execute on function public.register_report_device(text, text, boolean) to authenticated;

create or replace function public.register_device_token(p_token text, p_platform text)
returns void language sql security definer set search_path = '' as $$
  select public.register_report_device(p_token, p_platform, false)
$$;

create or replace function public.n8n_claim_report_push(p_report_id uuid)
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
    and (
      not d.quiet_hours or
      (now() at time zone 'America/New_York')::time >= time '07:00'
      and (now() at time zone 'America/New_York')::time < time '21:00'
    )
    and exists (
      select from public.report_sections s
      join public.section_access a on a.source = s.source and a.role = p.role and a.allowed
      where s.report_id = p_report_id and s.status in ('complete', 'partial')
    );
end
$$;
revoke execute on function public.n8n_claim_report_push(uuid) from public, anon, authenticated;
grant execute on function public.n8n_claim_report_push(uuid) to service_role;
