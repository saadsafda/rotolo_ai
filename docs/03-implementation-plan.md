# Implementation plan

Live n8n workflows stay unchanged throughout. Every n8n change is made in a **new copy** with a `RE - APP -` prefix.
Each new copy starts unpublished, with its schedule disabled, and is reviewed before activation.

## Phase status

| # | Phase | Status |
|---|---|---|
| 1 | Inspect workflows | **Done**: [01-n8n-inventory.md](01-n8n-inventory.md) |
| 2 | Contracts and schema | **Done**: [02-backend-contracts.md](02-backend-contracts.md), migration + local tests passing |
| 3 | Flutter UI on synthetic data | **Done**: redesigned to the Claude Design prototype; 57 Flutter tests passing |
| 4 | Supabase project, auth, read-only reports | **Done in code**: live repository, grants migration; project `pdobiwupwvbegzjlmnox` |
| 5 | n8n: `RE - APP - Daily Operations Report` | **Built, awaiting import**: see [n8n/README.md](../n8n/README.md). Stores via `n8n_ingest_report` (secret header) instead of Edge Functions |
| 6 | Push notifications (FCM) | Needs Firebase project (D1) |
| 7 | Payment submission and review (no posting) | Backend RPCs done; UI in phase 3; goes live with phase 4 |
| 8 | DoorLoop posting | **Blocked** on checks V1–V5 |

## Phase 5 — n8n changes (proposed, not yet built)

Build a new workflow, **`RE - APP - Daily Operations Report`**:

1. **Triggers:** a Webhook node with Header Auth (Supabase only), plus a schedule that stays **disabled**.
   - Input: `{sync_run_id, mode}`.
2. **CONFIG:** loaded from the request and from app config. Fields: timezone, AI model, VA scope, and synthetic flag.
3. **Synthetic path:** emits fixture sections in contract v1.0 with `data_mode: synthetic`. This reuses 01's fixture idea in the new format.
4. **Live path:** each source is called as a sub-workflow with **`onError: continueRegularOutput`**, using 06's pattern, so one failing source doesn't sink the whole report.
   - **`fub_deals` and `email_evidence`:** call 04. If 04 fails (for example on Gmail auth), fall back to calling 05 and mark `email_evidence` as unavailable.
   - **`doorloop_rent` and `doorloop_tasks`:** call `RE - APP - DoorLoop Snapshot`, a copy of 03 whose final node also emits structured `tasks[]`, tenant names and money in minor units.
     - The ledger fields stay `null` until reconciliation rules are agreed.
   - **`time_doctor`:** call 07. If it throws because the VA scope changed, emit `status: unavailable` with the error as a warning.
     - Longer term: merge 07's validation with 01's per-metric soft failures (D3).
5. **Normalize:** a Code node maps each output into the section envelope with cutoffs. It drops email bodies and FUB communication `content`.
6. **AI summary:** reuses 06's guarded prompt, with the model taken from config. Output containing digits is rejected.
7. **Progress and storage:** calls the signed `n8n-sync-progress` endpoint after each stage, then `n8n-ingest-report`.
8. **Errors:** an Error Trigger reports `failed` to the sync run.

**Separately**, build `RE - APP - Outside Payment Posting`, a copy of 02:
- The WhatsApp trigger and parser are replaced by a Webhook node that receives an **already-approved** submission from Supabase.
- Lease, account and duplicate checks, the POST and the verification are kept.
- The result is reported to `n8n-payment-result`.
- The POST node stays disabled until V1–V5 pass.

## Validation required before DoorLoop posting (phase 8)

| ID | Check | How |
|---|---|---|
| V1 | Does `POST /lease-payments` honour a client-supplied `id`? If not, redesign idempotency around a lookup by reference. | DoorLoop API docs, plus one sandbox or test-lease post that the owner approves |
| V2 | Filter parameter names `filter_lease`, `filter_date_from` and `filter_date_to` | Read-only GET against a lease with known payments |
| V3 | Deposit account mapping (`depositAccountsByLeaseOrProperty` is empty) | Owner supplies the mapping |
| V4 | Accounting choices: `autoApplyPaymentOnCharges=true`, `autoDeposit=false`, and ACTIVE-lease-only | Owner and bookkeeper confirm |
| V5 | End-to-end test of approve → post → verify → ledger refresh, including the ambiguous-failure path | Staging run on a test lease |
| V6 | Fix 02's `totalBalance` → `totalBalanceDue` bug | In the APP copy |

## Decisions needed

| ID | Decision | Default used until answered |
|---|---|---|
| D1 | Who owns the Supabase and Firebase projects (new ones, under which account)? | No live backend; the app runs on synthetic data |
| D2 | **Staff access**: which sections may staff see? | Staff see deals only. Rent, tasks, email evidence, VA activity and the AI summary are owner/admin only |
| D3 | **Lhaura Somera**: is she in scope? 07 hard-requires her; 01 reports her missing from the active directory | Shown as a "missing from directory" warning, never silently dropped |
| D4 | Workflow 06's inbox section reads **Asif's** mailbox and emails the brief **to Asif**. Should the app include an inbox section, and from whose mailbox? | Excluded. Only Harry-guarded email evidence (04) is used |
| D5 | Who can submit and who can approve outside payments? Is self-approval allowed? | Owner can submit and approve; admin can submit; self-approval is blocked |
| D6 | Which `depositStatus` values count as cleared vs pending, and how a reconciled balance is computed from charges, payments, credits and returns | `unclassified` / `not_computed`; the app shows DoorLoop API balances, clearly labelled |
| D7 | Should the app include Time Doctor low-activity or unusual-activity metrics (screenshot-derived)? | Excluded |
| D8 | Should workflow 06's live daily email to Asif keep running once the app is live? | Unchanged |
| D9 | Production AI model (gpt-5-nano was tested) | Configurable in `app_config.ai_summary_model` |

## Acceptance criteria → where they're covered

| Criterion | Covered by |
|---|---|
| Authenticate and show a stored report | Phase 4 (RLS reads), UI in phase 3 |
| Refresh produces a traceable sync run | `sync_runs` plus the one-active-run index; Realtime progress |
| Every section shows its source and cutoff | Section envelope `cutoff` is required (`not null`) |
| Synthetic or incomplete data can't look live | DB rejects mixed modes; app labelling rules; synthetic banner |
| Gmail ownership is correct | 04's runtime guard on Harry's address; 06's Asif inbox excluded (D4) |
| Secrets stay server-side | Trust boundaries in contracts §0; app holds only the Supabase anon key |
| Duplicates can't create duplicate payments | 5 layers; DB tests passing; V1 pending |
| Unapproved submissions can't trigger writes | State machine trigger plus `svc_begin_posting` claiming only `approved`, behind the posting flag |
| Push opens the correct report | `data.report_id` → `/reports/:id` route |
