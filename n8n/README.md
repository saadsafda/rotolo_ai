# n8n workflows for the Rotolo app

The app’s on-demand refresh uses **RE - APP - Report Queue Worker**. The worker
claims queued requests from Supabase, records progress, and stores six report
sections. The existing vendor workflows and the app-specific read-only copies supply the data.

| Workflow file | Purpose |
|---|---|
| `RE - APP - DoorLoop Snapshot - Read Only.json` | Read-only DoorLoop copy with structured tasks and lease IDs. |
| `RE - APP - Time Doctor Snapshot - Read Only.json` | Read-only Time Doctor copy that flags missing users within the configured scope. |
| `RE - APP - Report Queue Worker.json` | Polls for an app refresh, runs the read-only sources, adds the guarded OpenAI summary, and stores the result. |
| `RE - APP - Daily Operations Report.json` | Optional manual report collector for diagnosing the sources independently. The app uses the queue worker. |

## Set up the live connection

1. Apply the Supabase migrations through `20261122000000_app_report_queue.sql`.
2. Run `supabase/setup/create_ingest_secret.sql` for a fresh installation.
   Put the value directly into a credential named **Rotolo App - Ingest Secret**
   in n8n. Credential type **Header Auth**, header name `x-ingest-secret`.
   Scope the credential to the Supabase project host where possible.
3. Import the DoorLoop and Time Doctor snapshots into the same n8n project as the source workflows. Publish the two copies so the worker can call them. Their entry points are manual and sub-workflow triggers.
4. Import the queue worker. Set the DoorLoop and Time Doctor child workflow IDs. Set authentication to **Generic Credential Type → Header Auth** and select the exact Rotolo credential on **Claim Report Request**, the five **Progress**
   nodes, and **Store App Report**. Verify the OpenAI node selects **OpenAI - Harry**.
5. For a connection check, start a request through **Reports → Generate report**
   as an owner or admin, then execute **Poll Once**. Look for the report ID from
   **Verify Stored Report** and open that report in the app.
6. Publish the worker to enable polling every minute. To also generate a live
   report daily from 9 a.m. New York time, enable the server setting with
   `update public.app_config set value = 'true'::jsonb where key = 'app_report_daily_enabled';`.

The database allows one active request and rejects unsigned worker calls.
Repeated completion returns the original report ID. If the worker never picks
up a request or finishes, the app shows a timeout and lets the user try again.
No message delivery or DoorLoop posting is triggered by the report worker.

## Behaviour

- **A failed source appears as unavailable.** Its raw error stays out of the app. Time Doctor reports zero recorded time for validated users on a confirmed empty day and partial coverage when a configured user is missing. If Gmail is unavailable, the worker collects Follow Up Boss deals through the separate fallback.
- **Email evidence comes from Harry's mailbox only.** It uses 04, which checks the mailbox is `harryrotoloiv@gmail.com`. Asif's inbox from 06 is not used (decision D4).
- **What is not collected yet** (shown as "not returned", never invented):
  - Money arrives in cents. DoorLoop balances are its lease fields; the reconciled ledger and the cleared/pending classification wait for decision D6.
  - Payments cover the current month.
  - Unit, tenant and task assignee aren't collected yet.
- **The summary leads with results.** OpenAI receives section labels and availability to order the findings. n8n supplies the wording and figures directly from the report. If OpenAI is unavailable, the same findings appear in the report’s default order.
- **Data removed before storage:** email bodies (only 320-character excerpts are kept) and FUB message content.

## Changing the code

The Code-node scripts live in `src/`. After editing them:

```sh
node n8n/test/run_nodes.mjs ok > n8n/test/sample_report.json     # also: gmail_down doorloop_down td_down td_no_activity td_partial ai_digits
python3 -I n8n/build_workflows.py <path to claude-workflow-handoff>
python3 n8n/build_time_doctor_snapshot.py <Time Doctor workflow export>
python3 n8n/build_app_worker.py --doorloop-workflow-id <DoorLoop app copy ID> --time-doctor-workflow-id <Time Doctor app copy ID> --credential-id <Rotolo header credential ID>
flutter test test/n8n_report_test.dart
```
