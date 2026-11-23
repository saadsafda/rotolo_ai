# Backend contracts (v1.0)

- **Stack:** Supabase (Postgres, Auth, private Storage, Realtime, Edge Functions), plus n8n for vendor integrations and Firebase Cloud Messaging (FCM) for push.
- **Schema:** [`supabase/migrations/20261118000000_init.sql`](../supabase/migrations/20261118000000_init.sql).
- **Tests:** [`supabase/tests/run_local.sh`](../supabase/tests/run_local.sh).

## Trust boundaries

```
Flutter app ──(Supabase JWT)──▶ PostgREST reads (RLS) + app RPCs
            ──(Supabase JWT)──▶ Edge Functions: refresh-report, post-payment
Edge Fn     ──(Header-Auth secret held in Supabase secrets)──▶ n8n webhook
n8n         ──(HMAC-signed body, secret held as n8n credential)──▶ Edge Fns: n8n-ingest-report,
                                                                    n8n-sync-progress, n8n-payment-result
Edge Fn     ──(service_role, server only)──▶ svc_* RPCs
Edge Fn     ──(FCM service account, server only)──▶ FCM
```

- The app never sees an n8n URL, a webhook secret, or a vendor or service-role key.
- n8n webhooks accept only the Header-Auth secret.
- Ingest endpoints verify `X-Signature: sha256=HMAC(body)` plus `X-Timestamp`, which must be within 5 minutes.

## 1. Report ingest (n8n → backend)

`POST /functions/v1/n8n-ingest-report` calls `svc_ingest_report(jsonb)` and returns `{report_id}`.

```jsonc
{
  "contract_version": "1.0",
  "sync_run_id": "uuid | null",          // null for scheduled runs with no app request
  "report_key": "OPS-20261118",
  "business_date": "2026-11-18",          // date the report is for, in `timezone`
  "timezone": "America/New_York",         // from app_config.business_timezone
  "data_mode": "live" | "synthetic",      // every section must match (DB-enforced)
  "status": "complete" | "partial" | "failed",
  "generated_at": "2026-11-18T14:05:00Z",
  "sections": [ Section, ... ]
}
```

### Section envelope

```jsonc
{
  "source": "ai_summary|fub_deals|email_evidence|doorloop_rent|doorloop_tasks|time_doctor",
  "status": "complete" | "partial" | "unavailable",
  "data_mode": "live" | "synthetic",
  "collected_at": "ISO-8601 | null",
  "cutoff":                                   // exactly one shape
     {"kind": "snapshot", "as_of": "ISO"}                        // FUB, DoorLoop
   | {"kind": "business_day", "date": "2026-11-17", "timezone": "America/New_York",
      "from": "ISO", "to": "ISO"}                                 // Time Doctor (previous day)
   | {"kind": "lookback", "days": 90, "as_of": "ISO"},            // Gmail evidence
  "coverage": { /* source-specific completeness, below */ },
  "warnings": [{"code": "VA_NOT_IN_DIRECTORY", "severity": "review|info|error", "message": "…"}],
  "workflow": {"id": "f181nRQxfGeiVgQ_5iPO9", "execution_id": "12345"},
  "payload": { /* below */ }
}
```

**How the app labels data quality.** The rules are applied in this order:
1. `data_mode = synthetic` → **SYNTHETIC**. This badge is always shown and is never hidden by any other state.
2. `status = unavailable` → **UNAVAILABLE**.
3. `status = partial` → **INCOMPLETE**.
4. `now - collected_at > app_config.stale_after_hours` → **STALE**.
5. Otherwise → **LIVE**.

Every section header shows its source, the collection time and the cutoff label, for example "Snapshot 9:02 AM ET" or "Workday Tue 17 Nov (ET)".

### Payloads

All money values are integers in minor units (cents), with `"currency": "USD"` set once per section.

- **The conversion happens in n8n**, in the normalization Code node: `Math.round(dollars * 100)` on DoorLoop's decimal values.
- **Missing values are always `null`, never `0`.**

**`ai_summary`**
- **Payload:** `{text, model, guard: "verified_findings", status: "ok|unavailable"}`. Historical reports can also have `guard: "no_digits"` and `status: "rejected_by_guard"`.
- **Input:** section IDs and availability statuses. OpenAI orders the topics. n8n renders exact figures and findings from the collected sections, and uses the default order if the model output is missing or invalid.
- **Never sent to the AI:** report figures, email contents, receipts, addresses or names.

**`fub_deals`** (from 05, or from 04's pass-through)
```jsonc
{ "counts": {"open": 0, "closed_by_system_flag": 0, "closed_label_needs_review": 0, "cancelled": 0},
  "pipelines": [{"id": 1, "name": "…", "stages": [{"id": 1, "name": "…", "closed_stage": false}]}],
  "deals": [{
    "deal_id": 123, "property": "…", "pipeline": "…", "stage": "…",
    "classification": "open|closed_by_system_flag|closed_label_needs_review|cancelled",
    "projected_close_date": "YYYY-MM-DD|null", "days_to_projected_close": 5,
    "stage_entered_at": "ISO|null", "days_in_stage": 12, "assigned_users": ["…"],
    "flags": ["Projected close within 7 calendar days"],
    "fub_url": null,                       // deal URL format unverified, so null until confirmed
    "linked_people": [{"id": 1, "name": "…", "url": "https://rotoloandcohomebuyers.followupboss.com/2/people/view/1"}],
    "latest_linked_communication": {"date": "ISO", "type": "Email", "direction": "outbound", "person_name": "…"}
    // `content` dropped: untrusted, and not needed
  }] }
```
- **`coverage`:** `{deals_fetched, pipelines_fetched, contacts_fetched, missing_contact_ids, complete: true}`.

**`email_evidence`** (from 04)
```jsonc
{ "mailbox": "harryrotoloiv@gmail.com", "mailbox_verified": true,
  "query_scope": "Attorney office correspondence, 90 days",
  "items": [{"message_id": "…", "thread_id": "…", "date": "ISO", "from": "…", "to": ["…"],
             "subject": "…", "excerpt": "≤320 chars, untrusted", "kind": "VA_OUTREACH|ATTORNEY_MESSAGE|CORRESPONDENCE_REVIEW",
             "deal_id": 123, "mapping": "UNIQUE_PROPERTY_DEAL|MULTIPLE_FUB_DEALS_SAME_PROPERTY_REVIEW",
             "source_url": "https://mail.google.com/…"}],
  "deal_status": [{"deal_id": 123, "status": "ATTORNEY_REPLY_VERIFIED|VA_OUTREACH_VISIBLE|CORRESPONDENCE_VISIBLE_REVIEW|NO_MATCHED_EVIDENCE_IN_SCOPE",
                   "message_count": 3, "latest_message_id": "…", "verified_reply_message_id": "…|null"}],
  "unmatched": [{"message_id": "…", "subject": "…", "date": "ISO", "reason": "…"}] }
```
- **`coverage`:** `{listed, fetched, unreadable, complete, next_page_pending}`.
- **Excerpts are display-only.** The app shows them as plain text and never as links or markup. Nothing in an excerpt can trigger any action.

**`doorloop_rent`** (from a new copy of 03; see the plan)
```jsonc
{ "currency": "USD",
  "leases": [{
    "lease_id": "24hex", "reference": "…", "property_id": "…", "property_name": "…", "unit": null,
    "lease_name": "…", "tenants": null, "status": "ACTIVE", "collection_status": "OVERDUE",
    "api_balance": {"total_due_minor": 0, "overdue_minor": 0, "current_minor": 0, "upcoming_minor": 0},
    "ledger": {"charges_minor": null, "cleared_payments_minor": null, "pending_payments_minor": null,
               "applied_credits_minor": null, "returned_payments_minor": null,
               "reconciled_balance_minor": null,
               "status": "not_computed|matches_api|mismatch_review"},
    "flags": ["collection_status_conflict"] }],
  "payments": [{"payment_id": "…", "lease_id": "…", "date": "YYYY-MM-DD", "amount_minor": 0,
                "deposit_status": "raw DoorLoop value", "returned_linked": false,
                "classification": "cleared|pending|returned|unclassified"}],
  "promises": {"status": "not_connected"} }
```
- **`coverage`:** `{source_counts: {...8 sources}, pagination_checks: {...}}`. This is copied from 03 unchanged.
- **Ledger fields stay `null` with `status: not_computed`** until the reconciliation rule is agreed. Until then the app shows *"DoorLoop API balance"*, never *"reconciled"*.
- **Payment classification:** the mapping from `deposit_status` to cleared or pending is a business decision. Until it's confirmed, every payment is `unclassified`.

**`doorloop_tasks`**
```jsonc
{ "status_counts": {"NOT_STARTED": 3}, "excluded": {"rent_reminder_tasks": 297},
  "tasks": [{"task_id": "…", "subject": "…", "type": "TENANT_REQUEST", "status": "IN_PROGRESS",
             "priority": null, "property_name": "…", "unit": null, "due_date": "YYYY-MM-DD|null",
             "assignees": null, "updated_at": "ISO", "is_overdue": true,
             "completion_claim": {"source": "doorloop_status", "claimed": false}}] }
```
- **Verification lives in the backend:** whether a completion was independently verified is stored in the `task_reviews` table, not in DoorLoop.

**`time_doctor`** (07's validation, plus 01's per-metric soft failures)
```jsonc
{ "work_date": "2026-11-17",
  "scope": {"intended": [{"id": "…", "name": "Lhaura Somera"}, {"id": "…", "name": "Mary Dalipe"}],
            "missing": [{"name": "Lhaura Somera", "reason": "not in active directory"}]},
  "users": [{"user_id": "…", "name": "…", "tracked_sec": 28800, "active_sec": 26100, "idle_sec": 2700,
             "whole_idle_minutes": 40, "meeting_sec": 600, "unavailable_metrics": []}],
  "team_total": {"tracked_sec": 0, "active_sec": 0, "idle_sec": 0, "meeting_sec": 0},
  "gaps": [{"user_id": "…", "start": "ISO", "end": "ISO", "approx_minutes": 12,
            "interpretation": "Untracked interval; no non-work conclusion"}],
  "metric_availability": {"summary": true, "timeline": true, "planned_shifts": true,
                          "low_activity": false, "unusual_activity": false},
  "validation": {"user_team_reconciled": true},
  "continuous_idle_detection_available": false }
```
- **Out of scope:** low-activity and unusual-activity metrics are screenshot-derived. They stay `false` (out of the initial scope) unless the owner approves them.

## 2. Refresh (app → backend → n8n)

**`POST /functions/v1/refresh-report`**
- **Who:** owner or admin, authenticated with a JWT.
- **Request body:** `{"mode": "live" | "synthetic"}`.
- **Steps:**
  1. Insert a `sync_runs` row with status `queued`. A unique index allows only one active run, so a second request gets `409 {sync_run_id}` of the active run.
  2. `POST` to the n8n webhook with `{sync_run_id, mode}` and the Header-Auth secret.
  3. Return `202 {sync_run_id}`.
- **Progress:** the app subscribes over Realtime to `sync_runs` where `id = sync_run_id`.
  - n8n calls `n8n-sync-progress` for each stage: `fub`, `email`, `doorloop`, `time_doctor`, `summary`, `store`.
  - At the end n8n calls `n8n-ingest-report`, which sets status `succeeded`, `partial` or `failed` and fills `report_id`.
  - If n8n fails before ingesting, the n8n Error Trigger calls `n8n-sync-progress` with `status: failed`.
  - If nothing arrives for 15 minutes, the next refresh request marks the run `timed_out`.

## 3. Push notifications

- **Trigger:** after a report is ingested, the Edge Function sends FCM to every `device_tokens` row whose owner can read at least one section of that report.
- **Payload:** `{"notification": {"title": "Daily operations report ready", "body": "Tap to open."}, "data": {"type": "report_ready", "report_id": "uuid"}}`.
  - It contains no figures, names or addresses.
- **Tap behaviour:** the app routes to `/reports/<report_id>`.

## 4. Outside payments

| Step | Who | Call |
|---|---|---|
| Upload receipt (optional) | submitter | Storage `payment-receipts/<uid>/<idempotency_key>/<file>` (private) |
| Submit | `can_submit_payments` or owner | RPC `submit_outside_payment(...)`. The idempotency key is a UUID generated when the form opens and reused on retries. |
| Start review / approve / reject | `can_review_payments` | RPC `review_outside_payment(id, 'start_review' \| 'approve' \| 'reject', reason)`. Self-approval is blocked; a rejection needs a reason. |
| Post to DoorLoop | owner (Edge Fn `post-payment`) | `svc_begin_posting` claims the payment atomically and checks `doorloop_posting_enabled`. The n8n posting webhook runs workflow 02's checks (lease, account, duplicates, POST, verify). n8n then calls `n8n-payment-result`, which calls `svc_finish_posting`. |
| Reconcile ambiguous failure | owner, via n8n lookup | n8n looks the payment up by its stable ID or reference. If DoorLoop confirms it's absent, `svc_mark_reconciled_absent` is called, and only then can posting be retried. |

**Duplicate protection layers** (all tested in `schema_test.sql`):
1. The same idempotency key returns the original row. Reusing a key with a different payload is an error.
2. There's one live submission per `lease|method|reference`, the same business key workflow 02 uses.
3. Only one posting attempt can be pending, and the claim on `approved` is atomic.
4. Workflow 02's DoorLoop-side duplicate check and stable ID, both still to be verified (inventory §5.2).
5. Posted submissions are final, and financial fields can't be changed after submission.

`doorloop_posting_enabled` is `false` and can be changed only by a service_role or migration. The app has no switch for it.
