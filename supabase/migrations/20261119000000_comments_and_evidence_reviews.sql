-- Adds what the app design needs beyond the init migration:
--   * reviewer comments on outside-payment submissions
--   * "evidence reviewed" marks on Follow Up Boss deals (a human note; never changes the FUB stage)
-- Clients write only through the RPCs below. Comment text is untrusted user input: it is stored and
-- displayed, never interpreted, and it never changes payment status.

create table public.payment_comments (
  id            uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.payment_submissions (id) on delete cascade,
  author        uuid not null references auth.users (id),
  author_name   text not null,
  body          text not null check (length(btrim(body)) between 1 and 2000),
  created_at    timestamptz not null default now()
);
create index payment_comments_submission on public.payment_comments (submission_id, created_at);

create table public.deal_evidence_reviews (
  deal_id       bigint primary key,            -- Follow Up Boss deal id
  reviewed_by   uuid not null references auth.users (id),
  reviewer_name text not null,
  notes         text check (notes is null or length(notes) <= 2000),
  reviewed_at   timestamptz not null default now()
);

create or replace function public.add_payment_comment(p_submission_id uuid, p_body text)
returns public.payment_comments
language plpgsql security definer set search_path = public as $$
declare
  me  public.profiles;
  sub public.payment_submissions;
  row public.payment_comments;
begin
  select * into me from profiles where id = auth.uid() and active;
  if me.id is null then raise exception 'Not authorised' using errcode = '42501'; end if;
  select * into sub from payment_submissions where id = p_submission_id;
  if sub.id is null then raise exception 'Submission not found' using errcode = 'P0002'; end if;
  -- Same audience as payments_read: the submitter or an active reviewer.
  if not (sub.submitted_by = me.id or me.can_review_payments) then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  if p_body is null or length(btrim(p_body)) = 0 then
    raise exception 'Comment is empty' using errcode = '22023';
  end if;
  insert into payment_comments (submission_id, author, author_name, body)
  values (sub.id, me.id, me.display_name, btrim(p_body))
  returning * into row;
  insert into audit_events (actor, actor_kind, action, entity, entity_id, detail)
  values (me.id, 'user', 'payment.comment', 'payment_submission', sub.id::text, jsonb_build_object('comment_id', row.id));
  return row;
end $$;

create or replace function public.mark_deal_evidence_reviewed(p_deal_id bigint, p_notes text)
returns public.deal_evidence_reviews
language plpgsql security definer set search_path = public as $$
declare
  me  public.profiles;
  row public.deal_evidence_reviews;
begin
  select * into me from profiles where id = auth.uid() and active;
  if me.id is null or me.role not in ('owner', 'admin') then
    raise exception 'Only owner/admin can mark evidence reviewed' using errcode = '42501';
  end if;
  if not public.can_read_source('email_evidence') then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  insert into deal_evidence_reviews (deal_id, reviewed_by, reviewer_name, notes, reviewed_at)
  values (p_deal_id, me.id, me.display_name, p_notes, now())
  on conflict (deal_id) do update
    set reviewed_by = excluded.reviewed_by, reviewer_name = excluded.reviewer_name,
        notes = excluded.notes, reviewed_at = excluded.reviewed_at
  returning * into row;
  insert into audit_events (actor, actor_kind, action, entity, entity_id, detail)
  values (me.id, 'user', 'deal.evidence_reviewed', 'fub_deal', p_deal_id::text, '{}'::jsonb);
  return row;
end $$;

alter table public.payment_comments      enable row level security;
alter table public.deal_evidence_reviews enable row level security;

create policy payment_comments_read on public.payment_comments for select to authenticated
  using (exists (select 1 from public.payment_submissions s where s.id = submission_id));  -- inherits parent RLS
create policy deal_evidence_reviews_read on public.deal_evidence_reviews for select to authenticated
  using (public.can_read_source('email_evidence'));

revoke insert, update, delete, truncate on public.payment_comments, public.deal_evidence_reviews from anon, authenticated;
revoke all on public.payment_comments, public.deal_evidence_reviews from anon;
