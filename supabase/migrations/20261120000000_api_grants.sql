-- Explicit privileges for the Data API roles.
-- Newer Supabase projects no longer grant table access to `anon` / `authenticated`
-- by default, so signed-in users could not read even their own profile.
-- These grants only open the door: row-level security policies still decide which
-- rows each user sees, and there are still no insert/update/delete grants: every
-- write goes through the security-definer functions below.

grant usage on schema public to anon, authenticated, service_role;

-- Reads for signed-in users (filtered by RLS).
grant select on
  public.profiles, public.section_access, public.app_config, public.sync_runs,
  public.reports, public.report_sections, public.external_refs, public.task_reviews,
  public.payment_submissions, public.payment_events, public.posting_attempts,
  public.device_tokens, public.audit_events, public.payment_comments,
  public.deal_evidence_reviews
to authenticated;

-- Nothing for anonymous callers.
revoke all on all tables in schema public from anon;

-- App functions (each checks the caller's profile and role itself).
grant execute on function
  public.submit_outside_payment, public.review_outside_payment, public.set_task_review,
  public.register_device_token, public.add_payment_comment, public.mark_deal_evidence_reviewed
to authenticated;

-- Helpers used inside RLS policies.
grant execute on function public.current_app_role, public.can_read_source, public.is_owner_or_admin
to authenticated;

-- Server side (Edge Functions with the service-role key). svc_* execute grants are in the init migration.
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
