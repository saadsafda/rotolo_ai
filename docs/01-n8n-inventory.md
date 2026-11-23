# n8n workflow inventory

Source: offline export bundle `claude-workflow-handoff` (18 Nov 2026), 7 workflows.
These are exports only. Nothing was imported, executed, enabled or changed on the live instance.
Pinned execution data is not included, so the statements below come from node configuration and code.
They do not show whether past runs succeeded. Sticky notes were treated as possibly stale and checked against the code.

## 1. Dependency map

```
06 Daily Operations Report — Asif   [ACTIVE, schedule 09:00 NY, sends Gmail]
 ├─ 05 FUB Live Deal Report           (onError: continue)
 ├─ 07 Time Doctor Live Daily Report  (onError: continue)
 ├─ 03 DoorLoop API Snapshot          (onError: continue)
 ├─ Gmail getAll  [Asif Gmail Auth]   inbox newer_than:1d
 ├─ OpenAI chat/completions [OpenAI - Harry]  gpt-5-nano
 └─ Gmail send    [Asif Gmail Auth] → asifmahmoodai84@gmail.com

01 WhatsApp Daily Operations         [inactive, schedule node disabled]
 ├─ 04 FUB Attorney Email Evidence    (no onError → any failure stops 01)
 │    └─ 05 FUB Live Deal Report
 ├─ 03 DoorLoop API Snapshot          (no onError)
 └─ Time Doctor MCP inline loop  [Time Doctor MCP - Client]   (not 07)

02 WhatsApp Outside Payments         [inactive; trigger, POST and send disabled]
 ├─ DoorLoop reads [Bearer Auth account]
 ├─ DoorLoop POST /lease-payments     DISABLED
 └─ 03 DoorLoop API Snapshot          (ledger refresh after post)
```

Workflows referenced but **not in the bundle**: error workflow `6tvW40l2gMVEawwJK_XLt` (set on 06), tenant review queue `dg2Efw7ma_4dZO8fqFMwA`, BatchLeads receiver `_yeCBh7-s9yJSs7UVEb3e`, "RE - Gmail Priority Alerts - Asif".

## 2. Credentials by workflow

| Credential | Used in | Notes |
|---|---|---|
| FUB - Client (HTTP basic) | 04, 05 | 05 aborts unless `identity.account.domain == rotoloandcohomebuyers` |
| Bearer Auth account (DoorLoop) | 02, 03 | **The same credential is used for reads (03) and the payment POST (02).** |
| Time Doctor MCP - Client (header `x-api-key`) | 01, 07 | 07 aborts unless the company is `Y45ERHZWGqYEslJF` "Harry Rotolo's Company" and `readOnly === true` |
| Harry Gmail Auth | 04 | **Checked at runtime:** aborts unless the profile email is `harryrotoloiv@gmail.com` |
| Asif Gmail Auth | 06 | Reads Asif's inbox, and sends **to** `asifmahmoodai84@gmail.com`. Not Harry's mailbox, and the report is labeled as Asif's. |
| OpenAI - Harry | 06 | Model `gpt-5-nano` is **hardcoded** in the request body |

Gmail ownership: workflow 04 is correct and guarded. Workflow 06's inbox section and its delivery both use Asif's account, so the live daily brief currently goes to Asif, not Harry.

## 3. Per-workflow facts

### 01 — RE - WhatsApp Daily Operations - Connection Ready (`owe7GT-fVdORnF-xsBy1O`)
- **Triggers:** manual, plus a daily 09:15 schedule that is **disabled**.
- **CONFIG:** `useSyntheticData=false`, `sendWhatsApp=false`, `timeDoctorRestEnabled=false`, `timeDoctorNames="Lhaura Somera,Mary Dalipe"`, timezone `America/New_York`. The report day is yesterday in New York, with `from`, `to` and `until` stored as UTC instants. `reportKey=HARRYOPS<yyyyMMdd>`.
- **Synthetic branch:** `TEST - Combined Source Fixture` skips all sources and goes straight to Format. The fixture skips `Build Time Doctor Section`, so its shape is hand-written.
- **FUB:** calls 04 with no inputs. 04's output is 05's output plus email annotations.
- **DoorLoop:** calls 03 and uses only `balanceRows[].overdueBalance` from DoorLoop.
- **Time Doctor:** inline MCP JSON-RPC loop, separate from 07.
  - **Scope:** VAs are chosen by name and must not be archived. A missing name produces a warning. The run aborts only if *no* target is found.
  - **Metric queue:**
    - `td_get_time_summary` (groupBy user)
    - `td_list_low_activity_screencasts` (maxAvgActivity 30)
    - `td_get_worklog` (summary)
    - `td_get_uar_summary`
  - **Pagination:** follows cursors, with a safety limit of 30 calls.
  - **Failures:** a failing metric is marked `<kind>Unavailable` with a warning (soft fail).
  - **Output:** `timeDoctor.availability{summary,lowActivity,timeline,unusualActivity}`, `rows`, `lowActivity`, `timeline`, `unusualActivity`, `warnings`, and `inputMetrics.status='REST_CONNECTION_NOT_CONFIGURED'`.
- **Time Doctor REST screenshot metadata:** the node (`/api/1.0/files/screenshot`) is **disabled**. It would collect key, click and movement counts per screenshot interval, which is out of the initial scope.
- **Format Complete WhatsApp Report:** builds the text and 850-character chunks, checks the phone and template config, and keeps a best-effort, non-atomic duplicate guard in workflow static data. This is the WhatsApp layer to replace.
- **Delivery:** the WhatsApp send node is **disabled**, and the delivery check only writes static data.
- **Tracking gaps:** Format computes gaps of 5 minutes or more between worklog entries and labels them "not proven idle/non-work".

### 02 — RE - WhatsApp Outside Payments - Confirmed Receipt to DoorLoop (`V5YlOXafGVxSS1rL1PX-E`)
- **Triggers:** manual `Run Outside Payment TESTS`. The WhatsApp trigger is **disabled**.
- **CONFIG:**
  - `livePostingEnabled=false`, `sendWhatsApp=false`.
  - **`authorizedStaffPhones=""` and `depositAccountsByLeaseOrProperty={}`.** These are empty, so every live submission would currently stop at the account-mapping step. That is a safe failure.
  - `maximumPayment=50000`, `maximumBackdateDays=90`, USD only.
- **Parser (WhatsApp text command):**
  - The first line must be `PAYMENT RECEIVED`.
  - Fields: LEASE (24-hex or a configured alias), AMOUNT (converted to cents internally), METHOD, DATE (YYYY-MM-DD), REFERENCE (3–100 characters of `[A-Z0-9._/-]`), CONFIRMED=YES.
  - The sender must be on the approved staff list.
  - Method mapping: ZELLE, VENMO, CASHAPP and BANK TRANSFER become EFT. Also allowed: CASH, CHECK, MONEY_ORDER, CASHIERS_CHECK, OTHER. **EPAY is rejected.**
- **Idempotency:** `paymentId = sha256(lease|method|REFERENCE)[:24]` is sent as `id` in the POST body. A changed amount with the same reference keeps the same ID.
- **Pre-post checks:**
  1. **Lease:** GET the lease; it must be `ACTIVE` and its ID must match.
  2. **Deposit account:** must be mapped, then fetched, and must not be archived or deleted.
  3. **Same-day payments:** GET `lease-payments?filter_lease&filter_date_from=date&filter_date_to=date&limit=100`. The submission is blocked if:
     - history is incomplete;
     - an exact reference exists (`ALREADY_RECORDED` or `CONFLICTING_REFERENCE_REVIEW`);
     - or a payment with the same lease, date and amount exists (`POSSIBLE_DUPLICATE_REVIEW`).
- **POST body:** `{id, reference, amountReceived (float dollars), paymentMethod, lease, depositToAccount, autoApplyPaymentOnCharges:true, autoDeposit:false, date}`. The POST node is **DISABLED** and has no retry.
- **After posting:**
  - Verify the payment by ID, comparing ID, lease, amount, reference, method and date.
  - On a mismatch: `POST_NOT_VERIFIED_REVIEW_REQUIRED` with "do not retry".
  - Then refresh 03 and build the receipt.
- **Tests:** the 8 cases cover **only the parser and the SHA function**. The test branch never touches the DoorLoop read, validation, duplicate-check or post nodes.

### 03 — RE - DoorLoop API Snapshot - Read Only (`f181nRQxfGeiVgQ_5iPO9`)
- **Triggers:** manual, plus a sub-workflow trigger (passthrough).
- **Sources:** properties, leases, `leases/tenants`, `lease-charges`, `lease-payments`, `lease-credits`, `lease-reversed-payments` and `tasks`, fetched one after another.
- **Request settings:** `page_size=100`, `page_number` pagination, `retryOnFail`.
- **Per-source validation:**
  - the `{total,data}` shape must be present, and `total` must stay the same across pages;
  - `records.length === total`;
  - IDs must be unique and not null (lease tenants use `uniqueId`);
  - any failure throws an error.
- **Page cap:** `limitPagesFetched` is on with no explicit `maxRequests`. The n8n default is 100 pages, so about 10,000 records per source. Going over that would fail validation, which is a safe failure.
- **Output from `Mapping Review`:**
  - `status, collectedAt, reportDate, sourceCounts, paginationChecks`
  - `balanceRows[]`: `leaseId, reference, property(name), leaseName, status, calculatedStatus, collectionStatus, totalBalanceDue, overdueBalance, currentBalance, upcomingBalance`, all as **DoorLoop lease fields in float dollars**
  - `paymentRows[]`: **current month only**, with `id, date, leaseId, amountReceived, depositStatus, returnedPaymentLinked`
  - `taskStatuses, openTaskCount, overdueTaskCount, externalActionsExecuted:false, report (markdown)`
- **Fetched but not used:**
  - Charges, credits and lease tenants are fetched but **never used** in the output.
  - Returned payments are used only to set the `returnedPaymentLinked` flag.
  - **No reconciled balance is computed.** No unit or tenant names are mapped.
  - **Task rows exist only inside the markdown text**, capped at 50, with no assignee or priority.

### 04 — RE - FUB Attorney Email Evidence - Harry Gmail (`vnU7rkSlA3Oh_sQXXTFDs`)
- **Mailbox guard:** checks Harry's mailbox (see §2).
- **Search:** `newer_than:90d` limited to revellalaw.com plus `nicole.revellalaw@gmail.com`, `maxResults=100`, **no pagination**.
  - The coverage fields `complete` and `nextPagePending` are reported honestly.
- **Message handling:** full MIME bodies, no attachments. Drafts, spam and trash are dropped. Quoted replies and disclaimers are stripped. Bodies are kept up to 8,000 characters, and excerpts up to 320 characters.
- **Hardcoded business config:**
  - VA senders are matched by name: `Mary Dalipe` and `Brittany Lauzon`.
  - Attorney identities come from FUB people IDs `2216, 149045, 149046`.
- **Matching:** the email subject must contain exactly one normalized street-address key derived from the FUB deal name.
  - **Flagged for review:** subjects matching zero or several addresses are listed as unmatched; several deals sharing one address get `MULTIPLE_FUB_DEALS_SAME_PROPERTY_REVIEW`.
- **Status per deal:**
  - `ATTORNEY_REPLY_VERIFIED`: the reply is in the same thread, with `In-Reply-To` or `References` pointing at the VA outreach.
  - `VA_OUTREACH_VISIBLE`
  - `CORRESPONDENCE_VISIBLE_REVIEW`
  - `NO_MATCHED_EVIDENCE_IN_SCOPE`
- **Output:** 05's output plus `rows[].attorneyEmailReview`, `emailEvidenceCoverage`, `emailEvidenceReview[]`, `unmatchedEmailReview[]` and `attorneyEmailReport`. There are no writes.

### 05 — RE - FUB Live Deal Report - Read Only (`Z4X4z-NcqRJDD-0ma7hs3`)
- **Requests:** identity guard, then pipelines (limit 100), then `deals?status=Active&limit=100`, then linked people (limit 100).
  - **Paging:** it throws if another page exists, if the total doesn't match, or if there are more than 100 linked contacts. A note in 06 mentions 33 deals and 24 contacts.
- **Validation:** each deal's stage must exist in its pipeline, and the deal's labels must match the stage's labels.
- **Classification:**
  - `cancelled` if the stage name starts with "Cancelled"
  - `closed_by_system_flag` if `closedStage` is set
  - `closed_label_needs_review`
  - `open`
- **Flags:** no projected close date; projected close date passed; closing within 7 days.
- **Row fields:** `dealId, property, pipeline, stage, closedStage, classification, projectedCloseDate, daysToProjectedClose, stageEnteredAt, daysInStage, assignedUsers[], linkedPeopleCount, transactionTypeCode, flags[], linkedPersonIds, linkedContactEmails, latestLinkedCommunication{personId,personName,date,type,direction,content,personUrl}`.
- **Top level:** `fetchedAt, businessDate, timezone, complete, counts, byPipeline, attention, communicationRows, communicationCoverage`.
- **No deal URL** is produced; only person URLs (`…followupboss.com/2/people/view/<id>`).
- **Not done yet:** FUB `X-System` registration is still outstanding.

### 06 — RE - Daily Operations Report - Asif (`Ppvb0MNHerv1VTgOaIYHD`) — **live**
- **Schedule:** active, cron `0 9 * * *` with workflow timezone New York. Error workflow is set.
- **Partial runs:** sub-workflows run with `continueRegularOutput`, so a failed source gives `status:'PARTIAL'` with `issues[]`. This is the partial-report behavior the app needs.
- **Date checks:** `reportDay` is today and `workDay` is yesterday. It checks that `td.reportDate == workDay`.
- **Inbox review:** subject and snippet keyword rules over Asif's inbox. It also links an email to a deal when there is a unique property-text or contact-email match, marked "possible".
- **AI summary:**
  - It sends only status, issues, counts and fixed limitations. No raw emails or tenant data are sent.
  - The system prompt forbids digits, and **the output is discarded if it contains any digit**.
  - The owner-facing numbers are built in code.
  - This is a good pattern to reuse.
- **Format:** HTML email. **Maintenance rows are parsed back out of 03's markdown text** (`TENANT_REQUEST/`), which is fragile.
- **Delivery:** a duplicate guard searches Gmail Sent for the subject key. The note says this is not an atomic lock.

### 07 — RE - Time Doctor Live Daily Report - Read Only (`s7sjE_OYgY1Luiz14VcSb`)
- **Scope:** the report date is yesterday in New York. Target IDs are hardcoded: `atZbYo2u_1G5a1ed` (Lhaura Somera) and `Y5iTR_CAIiS6OG4x` (Mary Dalipe).
- **Hard stop:** the run **throws unless both are present** in `td_list_users` (limit 100). It does not filter out archived users.
- **Calls:**
  - `td_get_time_summary`, per user and team-wide
  - `td_get_worklog` (full)
  - `td_list_work_schedules`
- **Validation — the strictest in the system:**
  - Per-user totals must equal team totals across 10 metrics.
  - `activeSec == totalSec - idleSec`.
  - The mode split must sum to the tracked time.
  - Users must be resolved, timezone must match, and results must not be truncated.
- **Output:**
  - `rows[]`: `userId, name, trackedSec, nonIdleComputerSec, idleSec, wholeIdleMinutes, wholeIdleMinutePercent, idleSecondsPercent, meetingSec, …`
  - `teamTotal`, `timelineRows`
  - `betweenBlockGaps[]`: merged blocks, 5 minutes or more, "untracked interval, no non-work conclusion"
  - `plannedShiftCount`, `coverage`
  - `continuousIdleEventDetection.available=false`
- **Stale note:** the sticky note says "selects 4 November" and "Manual only; unpublished". The code uses yesterday, and the workflow is active.

## 4. What already works (per code), what's unverified, what's missing

| Area | Works in code | Unverified | Missing for app |
|---|---|---|---|
| FUB deals (05) | Identity guard, full-collection checks, stage validation, classification, flags | X-System registration; behaviour with more than 100 deals or contacts (hard fail) | Deal URL; structured storage |
| Email evidence (04) | Harry mailbox guard, conservative matching, ambiguity flags, coverage disclosure | Hardcoded VA and attorney lists still current; full 90-day pagination | Excerpt-only storage; making it independent of 05 so a Gmail failure doesn't drop deals |
| DoorLoop collection (03) | Complete pagination per source, ID uniqueness | Page cap at about 10k records; account currency | **Reconciled ledger** (charges, payments, credits, returns), pending vs cleared, unit and tenant mapping, **structured tasks** with assignee and priority, money in minor units |
| Time Doctor (07) | Strict reconciliation, read-only check, ID-scoped users | Lhaura's status: 07 requires her while 01 reports her absent from the active directory | Soft-fail per metric (01 has this); app storage |
| Time Doctor (01 inline) | Soft-fail per metric, cursor pagination, coverage warnings | `td_get_uar_summary` availability (may need an add-on); low-activity *screencast* listing is screenshot-derived | — |
| AI summary (06) | Guarded, figures stay in code, no digits allowed in output | Model pricing and availability; prompt-injection exposure is low because no email content is sent | Model as config; store the summary with provenance |
| Outside payment (02) | Strict parser, stable ID, lease, account and same-day duplicate checks, post verification, no automatic retry | **Whether DoorLoop honours a client-supplied `id` on POST** (the whole idempotency design depends on it); `filter_lease` and `filter_date_*` parameter names; the deposit-account mapping; `autoApplyPaymentOnCharges=true` as an accounting choice; behaviour for non-ACTIVE leases | App intake, approval workflow, persistent idempotency, audit trail |
| Delivery | 06 Gmail email works (to Asif) | — | Storing reports in the app backend, push notifications, app refresh endpoint |

## 5. Defects and risks found in the exports

1. **02 `Build Verified Payment Receipt`** reads `row.totalBalance`, but 03 emits `totalBalanceDue`. The updated total balance in the receipt is always `undefined`.
2. **02 idempotency depends on DoorLoop accepting a client-supplied `id`.** If DoorLoop ignores it and assigns its own ID:
   - `Verify Payment By Stable ID` fails. That fails safely to review, but a real payment would already have been created.
   - Re-submitting the same reference on a *different date* is not caught, because the duplicate check covers the payment date only.
3. **02 tests never exercise the DoorLoop path.** No check covers the lease, account, duplicate, post or verify steps.
4. **01 has no error handling on its sub-workflow calls.** An expired Gmail token in 04 fails the whole daily run, including DoorLoop and Time Doctor.
5. **Two diverging Time Doctor implementations** (01 inline vs 07). They handle missing users differently: 01 warns, 07 throws. They also call different tools.
6. **Task data is only available as markdown text** from 03. 06 re-parses it with string matching.
7. **Money is float dollars everywhere.** 02 converts to cents only for validation.
8. **Business config is hardcoded inside Code nodes:**
   - VA names in 01, 04 and 07
   - attorney IDs and domain in 04
   - the FUB domain in 05
   - the Time Doctor company in 07
9. **06 (live) emails an operations brief for Harry to Asif's address.** It includes tenant balances and VA activity. Confirm this is intended.
10. **Stale sticky notes:** 03 ("live run pending"), 07 ("4 November", "unpublished") and 01's notes on WhatsApp next steps.
