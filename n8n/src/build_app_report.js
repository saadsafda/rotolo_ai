// n8n Code node "Build App Report v1.0" (RE - APP - Daily Operations Report).
// Converts the outputs of the existing read-only workflows into report contract v1.0
// (docs/02-backend-contracts.md). Rules:
//  - money in integer cents; a missing value stays null (never 0)
//  - every section carries its source, status, cutoff and warnings
//  - a failed source becomes status "unavailable" with the error, never silently dropped
//  - email bodies, FUB communication content and other free text beyond short excerpts are dropped
const cfg = $('App Report Configuration').first().json;
const WF = {
  fub_deals: 'Z4X4z-NcqRJDD-0ma7hs3 / vnU7rkSlA3Oh_sQXXTFDs',
  email_evidence: 'vnU7rkSlA3Oh_sQXXTFDs',
  doorloop_rent: 'RE - APP - DoorLoop Snapshot',
  doorloop_tasks: 'RE - APP - DoorLoop Snapshot',
  time_doctor: 's7sjE_OYgY1Luiz14VcSb',
};
const execId = $execution.id ? String($execution.id) : null;

function one(nodeName) {
  let items;
  try { items = $(nodeName).all().map((i) => i.json); } catch (e) { return { error: 'Node did not run: ' + nodeName }; }
  if (items.length !== 1) return { error: 'Expected one result from ' + nodeName + ', got ' + items.length };
  const j = items[0];
  if (j.error) return { error: typeof j.error === 'string' ? j.error : (j.error.message || JSON.stringify(j.error)) };
  return j;
}
const W = (code, severity, message) => ({ code, severity, message: String(message).slice(0, 500) });
const iso = (v) => { if (!v) return null; const d = new Date(v); return isNaN(d.getTime()) ? null : d.toISOString(); };
const day = (v) => (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}/.test(v) ? v.slice(0, 10) : null);
const cents = (v) => (typeof v === 'number' && Number.isFinite(v) ? Math.round(v * 100) : null);
const int = (v) => (typeof v === 'number' && Number.isFinite(v) ? Math.round(v) : null);
const dealId = (v) => { const n = Number(v); return Number.isInteger(n) ? n : null; };
const envelope = (source, status, cutoff, collectedAt, coverage, warnings, payload) => ({
  source, status, data_mode: 'live', collected_at: collectedAt, cutoff, coverage: coverage || {},
  warnings: warnings || [], workflow: { id: WF[source] || null, execution_id: execId }, payload: payload || {},
});
const unavailable = (source, cutoff, err) =>
  envelope(source, 'unavailable', cutoff, null, {}, [W('SOURCE_ERROR', 'error', err)], {});

const nowIso = new Date().toISOString();
const sections = [];

// ───────── Follow Up Boss deals + Harry's attorney email evidence ─────────
const fubEmail = one('FUB + Harry Email Evidence (04)');
const fubOnly = one('FUB Deals Fallback (05)');
const fub = fubEmail.error ? fubOnly : fubEmail;
if (fub.error) {
  sections.push(unavailable('fub_deals', { kind: 'snapshot', as_of: nowIso }, fub.error));
} else {
  const rows = Array.isArray(fub.rows) ? fub.rows : [];
  const names = new Map();
  const remember = (c) => { if (c && c.personId != null && c.personName) names.set(String(c.personId), String(c.personName)); };
  for (const c of fub.communicationRows || []) remember(c);
  for (const r of rows) remember(r.latestLinkedCommunication);
  const deals = rows.map((r) => {
    const c = r.latestLinkedCommunication;
    return {
      deal_id: dealId(r.dealId),
      property: r.property || r.name || r.dealName || 'Unnamed deal',
      pipeline: r.pipeline || 'Unknown pipeline',
      stage: r.stage || 'Unknown stage',
      classification: r.classification || 'review',
      projected_close_date: day(r.projectedCloseDate),
      days_to_projected_close: int(r.daysToProjectedClose),
      stage_entered_at: iso(r.stageEnteredAt),
      days_in_stage: int(r.daysInStage),
      assigned_users: Array.isArray(r.assignedUsers) ? r.assignedUsers.map(String) : [],
      flags: Array.isArray(r.flags) ? r.flags.map(String) : [],
      fub_url: null,
      linked_people: (r.linkedPersonIds || []).map((id) => ({
        id: dealId(id), name: names.get(String(id)) || 'FUB contact ' + id, url: null })),
      // Communication content is not stored; only who/when/how.
      latest_linked_communication: c ? { date: iso(c.date), type: c.type || null, direction: c.direction || null, person_name: c.personName || null } : null,
    };
  });
  const counts = { open: 0, closed_by_system_flag: 0, closed_label_needs_review: 0, cancelled: 0 };
  for (const d of deals) if (counts[d.classification] !== undefined) counts[d.classification]++;
  const pipelines = [...new Set(deals.map((d) => d.pipeline))].map((name) => ({
    id: null, name, stages: [...new Set(deals.filter((d) => d.pipeline === name).map((d) => d.stage))].map((s) => ({ id: null, name: s })),
  }));
  const warnings = [];
  if (fubEmail.error) warnings.push(W('EMAIL_PATH_FAILED', 'review', 'Deals collected without email evidence: ' + fubEmail.error));
  if (fub.operationalNotice) warnings.push(W('FUB_NOTICE', 'info', fub.operationalNotice));
  sections.push(envelope('fub_deals', fub.complete === true ? 'complete' : 'partial',
    { kind: 'snapshot', as_of: iso(fub.fetchedAt) || nowIso }, iso(fub.fetchedAt) || nowIso,
    { deals_fetched: fub.dealsFetched ?? deals.length, pipelines_fetched: fub.pipelinesFetched ?? null, complete: fub.complete === true },
    warnings, { counts, pipelines, deals }));
}

if (fubEmail.error) {
  sections.push(unavailable('email_evidence', { kind: 'lookback', days: 90, as_of: nowIso }, fubEmail.error));
} else {
  const cov = fubEmail.emailEvidenceCoverage || {};
  const rows = Array.isArray(fubEmail.rows) ? fubEmail.rows : [];
  const owner = new Map();
  for (const r of rows) {
    const e = r.attorneyEmailReview || {};
    for (const m of [e.latest, e.lastVaOutreach, e.verifiedReply]) if (m && m.id && !owner.has(m.id)) owner.set(m.id, dealId(r.dealId));
  }
  const items = (fubEmail.emailEvidenceReview || []).filter(Boolean).map((m) => ({
    message_id: String(m.id), thread_id: m.threadId || null, date: iso(m.date), from: m.from || '',
    to: Array.isArray(m.to) ? m.to : [], subject: m.subject || '(no subject)',
    excerpt: String(m.excerpt || '').slice(0, 320), // untrusted text, displayed only
    kind: m.kind || 'CORRESPONDENCE_REVIEW',
    deal_id: m.mapping === 'UNIQUE_PROPERTY_DEAL' ? owner.get(m.id) ?? null : null,
    mapping: m.mapping || 'UNMATCHED', source_url: m.url || null,
  }));
  const dealStatus = rows.map((r) => {
    const e = r.attorneyEmailReview || {};
    return { deal_id: dealId(r.dealId), status: e.status || 'NO_MATCHED_EVIDENCE_IN_SCOPE', message_count: int(e.messageCount),
      latest_message_id: e.latest?.id ?? null, verified_reply_message_id: e.verifiedReply?.id ?? null };
  });
  const complete = cov.complete === true && !cov.nextPagePending;
  sections.push(envelope('email_evidence', complete ? 'complete' : 'partial',
    { kind: 'lookback', days: 90, as_of: iso(fubEmail.fetchedAt) || nowIso }, iso(fubEmail.fetchedAt) || nowIso,
    { complete, next_page_pending: !!cov.nextPagePending, readable: int(cov.readable), matched: int(cov.matched), unmatched: int(cov.unmatched) },
    (cov.warnings || []).filter(Boolean).map((w) => W('EMAIL_COVERAGE', 'review', w)),
    { mailbox: cov.mailbox || null, mailbox_verified: cov.mailbox === 'harryrotoloiv@gmail.com',
      query_scope: 'Attorney office correspondence, 90 days', items, deal_status: dealStatus,
      unmatched: (fubEmail.unmatchedEmailReview || []).map((u) => ({ message_id: String(u.id), subject: u.subject || '(no subject)', date: iso(u.date), reason: u.reason || '' })) }));
}

// ───────── DoorLoop rent + tasks (APP copy of 03) ─────────
const door = one('DoorLoop Snapshot (APP copy of 03)');
if (door.error) {
  sections.push(unavailable('doorloop_rent', { kind: 'snapshot', as_of: nowIso }, door.error));
  sections.push(unavailable('doorloop_tasks', { kind: 'snapshot', as_of: nowIso }, door.error));
} else {
  const at = iso(door.collectedAt) || nowIso;
  const propertyIds = door.appLeasePropertyIds || {};
  const leases = (door.balanceRows || []).map((l) => {
    const api = { total_due_minor: cents(l.totalBalanceDue), overdue_minor: cents(l.overdueBalance), current_minor: cents(l.currentBalance), upcoming_minor: cents(l.upcomingBalance) };
    const flags = [];
    if (api.total_due_minor === null || api.overdue_minor === null) flags.push('balance_fields_missing');
    if ((api.overdue_minor || 0) > 0 && l.collectionStatus !== 'OVERDUE') flags.push('collection_status_conflict');
    return {
      lease_id: String(l.leaseId), reference: l.reference ?? null, property_id: propertyIds[l.leaseId] ?? null,
      property_name: l.property || 'Unknown property', unit: null, lease_name: l.leaseName || 'Unnamed lease', tenants: null,
      status: l.status || 'UNKNOWN', collection_status: l.collectionStatus || null, api_balance: api,
      // Reconciled ledger is not computed until decision D6 is made.
      ledger: { charges_minor: null, cleared_payments_minor: null, pending_payments_minor: null, applied_credits_minor: null,
        returned_payments_minor: null, reconciled_balance_minor: null, status: 'not_computed' },
      flags,
    };
  });
  const payments = (door.paymentRows || []).map((p) => ({
    payment_id: String(p.id), lease_id: String(p.leaseId), date: day(p.date), amount_minor: cents(p.amountReceived),
    deposit_status: p.depositStatus || null, returned_linked: !!p.returnedPaymentLinked,
    classification: p.returnedPaymentLinked ? 'returned' : 'unclassified',
  }));
  sections.push(envelope('doorloop_rent', 'complete', { kind: 'snapshot', as_of: at }, at,
    { source_counts: door.sourceCounts || {}, complete: true, payments_scope: 'current month to date' },
    [W('API_BALANCES_ONLY', 'info', 'Balances are DoorLoop lease fields. A reconciled ledger is not computed yet.'),
     W('PAYMENTS_THIS_MONTH', 'info', 'Payment records cover the current month only. Deposit statuses are not yet classified as cleared or pending.')],
    { currency: 'USD', leases, payments, promises: { status: 'not_connected' } }));

  const today = cfg.reportDay;
  const done = new Set(['COMPLETED', 'COMPLETE']);
  const tasks = (door.appTaskRows || []).map((t) => {
    const due = day(t.dueDate);
    const claimed = done.has(t.status);
    return {
      task_id: String(t.id), subject: t.subject || 'Untitled task', type: t.type || null, status: t.status || 'UNKNOWN',
      priority: typeof t.priority === 'string' ? t.priority.toUpperCase() : null, property_name: t.property || null,
      unit: null, due_date: due, assignees: null, updated_at: iso(t.updatedAt),
      is_overdue: !claimed && !!due && due < today,
      completion_claim: { source: 'doorloop_status', claimed },
    };
  });
  sections.push(envelope('doorloop_tasks', Array.isArray(door.appTaskRows) ? 'complete' : 'unavailable', { kind: 'snapshot', as_of: at }, at,
    { complete: Array.isArray(door.appTaskRows), open_tasks: int(door.openTaskCount) },
    [W('DUE_DATES_NOT_APPOINTMENTS', 'info', 'Task due dates are not confirmed contractor appointments.'),
     W('ASSIGNEES_NOT_COLLECTED', 'info', 'Assignee and unit are not collected from DoorLoop yet.')],
    { status_counts: door.taskStatuses || {}, excluded: { rent_reminder_tasks: int(door.appReminderTaskCount) }, tasks }));
}

// ───────── Time Doctor (07) ─────────
const td = one('Time Doctor (07)');
const workCutoff = { kind: 'business_day', date: cfg.workDay, timezone: cfg.timezone };
if (td.error) {
  sections.push(unavailable('time_doctor', workCutoff, td.error));
} else {
  const users = (td.rows || []).map((u) => ({
    user_id: u.userId || null, name: u.name || 'Unknown user', tracked_sec: int(u.trackedSec), active_sec: int(u.nonIdleComputerSec),
    idle_sec: int(u.idleSec), whole_idle_minutes: int(u.wholeIdleMinutes), meeting_sec: int(u.meetingSec),
    unavailable_metrics: ['trackedSec', 'nonIdleComputerSec', 'idleSec', 'meetingSec'].filter((k) => typeof u[k] !== 'number'),
  }));
  const intended = td.intendedUsers || td.directoryUsers || [];
  const missing = (td.missingUsers || []).map(user => ({...user, reason: 'Not in the active configured directory scope'}));
  const warnings = (td.timezoneWarnings || []).filter(Boolean).map((w) => W('TIMEZONE', 'review', w));
  if (td.reportDate && td.reportDate !== cfg.workDay) warnings.push(W('WORKDAY_MISMATCH', 'review', 'Time Doctor reported ' + td.reportDate + ', expected ' + cfg.workDay));
  sections.push(envelope('time_doctor', warnings.length || missing.length || users.length < intended.length ? 'partial' : 'complete',
    { kind: 'business_day', date: td.reportDate || cfg.workDay, timezone: td.timezoneUsed || cfg.timezone }, iso(td.generatedAt) || nowIso,
    { users_requested: intended.length || users.length, users_resolved: users.length }, warnings,
    { work_date: td.reportDate || cfg.workDay, activity_status: td.activityStatus || 'recorded',
      scope: { intended: intended.map((u) => ({ id: u.id, name: u.name })), missing },
      users,
      web_app_usage: (Array.isArray(td.webAppUsage) ? td.webAppUsage : [])
        .filter(entry => users.some(user => user.user_id === entry.userId))
        .map(entry => ({ user_id: entry.userId, status: entry.status, rows: entry.rows })),
      team_total: { tracked_sec: int(td.teamTotal?.trackedSec), active_sec: int(td.teamTotal?.activeSec),
        idle_sec: int(td.teamTotal?.idleSec), meeting_sec: int(td.teamTotal?.meetingSec) },
      gaps: (td.betweenBlockGaps || []).map((g) => ({ user_id: g.userId || null, start: iso(g.start), end: iso(g.end),
        approx_minutes: int(g.approxMinutes), interpretation: g.interpretation || 'Untracked interval. No non-work conclusion.' })),
      metric_availability: { summary: true, timeline: true, planned_shifts: true, low_activity: false, unusual_activity: false },
      validation: { user_team_reconciled: td.validation?.apiUserTeamTotalsReconcile === true },
      continuous_idle_detection_available: false }));
}

// Keep verified result sentences inside n8n. The AI only selects their order.
const findings = [];
const finding = (id, text, priority = 2) => findings.push({ id, text, priority });
const countLabel = (count, singular, plural = singular + 's') =>
  count + ' ' + (count === 1 ? singular : plural);
const covered = (section) => section.status === 'partial' ? ' in the records reviewed' : '';

for (const section of sections) {
  const { source, status, payload } = section;
  if (status === 'unavailable') {
    const labels = {
      fub_deals: 'Deal results', email_evidence: 'Attorney email results',
      doorloop_rent: 'Rent balances', doorloop_tasks: 'Maintenance tasks', time_doctor: 'Time Doctor results',
    };
    finding(source, labels[source] + ' were unavailable for this report.', 3);
    continue;
  }

  if (source === 'fub_deals') {
    const open = payload.deals.filter(deal => deal.classification === 'open');
    const dates = open.map(deal => deal.days_to_projected_close).filter(Number.isInteger);
    const past = dates.filter(days => days < 0).length;
    const soon = dates.filter(days => days >= 0 && days <= 7).length;
    finding(source, 'Follow Up Boss shows ' + countLabel(open.length, 'open deal') + covered(section) +
      ', including ' + past + ' past their projected closing date and ' + soon + ' projected to close within 7 days.', past > 0 ? 0 : 2);
  }

  if (source === 'email_evidence') {
    const verified = new Set(payload.deal_status.filter(deal => deal.verified_reply_message_id && deal.deal_id != null)
      .map(deal => deal.deal_id)).size;
    const matched = payload.items.filter(item => item.deal_id != null).length;
    finding(source, 'Attorney email review found ' + countLabel(matched, 'matched message') +
      ' and verified replies for ' + countLabel(verified, 'deal') + covered(section) + '.');
  }

  if (source === 'doorloop_rent') {
    const leases = payload.leases;
    const known = leases.filter(lease => lease.api_balance.overdue_minor != null);
    const overdue = known.filter(lease => lease.api_balance.overdue_minor > 0).length;
    finding(source, 'DoorLoop lists overdue balances on ' + countLabel(overdue, 'lease') +
      (known.length < leases.length ? ', with balance data missing for ' + countLabel(leases.length - known.length, 'lease') : '') + '.', overdue > 0 ? 1 : 2);
  }

  if (source === 'doorloop_tasks') {
    const open = payload.tasks.filter(task => !task.completion_claim.claimed);
    const overdue = open.filter(task => task.is_overdue).length;
    finding(source, 'DoorLoop shows ' + countLabel(open.length, 'open maintenance task') +
      ', including ' + countLabel(overdue, 'overdue task') + '.', overdue > 0 ? 0 : 2);
  }

  if (source === 'time_doctor') {
    const tracked = payload.team_total.tracked_sec;
    const activity = payload.activity_status === 'no_activity' ? 'recorded no activity' :
      tracked == null ? 'did not return a tracked-time total' :
      'recorded ' + (tracked > 0 && tracked < 60 ? 'less than 1 minute' :
        countLabel(Math.floor(tracked / 3600), 'hour') + ' and ' +
        countLabel(Math.floor(tracked % 3600 / 60), 'minute')) + ' of tracked time';
    const scope = section.coverage.users_resolved < section.coverage.users_requested
      ? ' (coverage: ' + section.coverage.users_resolved + ' of ' + section.coverage.users_requested + ' configured staff)'
      : '';
    finding(source, 'Time Doctor ' + activity + ' on ' + payload.work_date + scope + '.');
  }
}

const aiRequest = {
  model: cfg.aiModel, reasoning_effort: 'minimal', max_completion_tokens: 450,
  messages: [
    { role: 'system', content: 'Order the report topics for a real estate operations briefing. Return only a JSON array of the supplied topic IDs, each exactly once. Prefer topics that have results, with deal and maintenance results early. Do not write prose.' },
    { role: 'user', content: JSON.stringify(sections.map(section => ({ id: section.source, status: section.status }))) },
  ],
};

const anyOk = sections.some((s) => s.status !== 'unavailable');
const allComplete = sections.every((s) => s.status === 'complete');
return [{ json: { aiRequest, findings, report: {
  contract_version: '1.0', report_key: cfg.reportKey, business_date: cfg.reportDay, timezone: cfg.timezone,
  data_mode: 'live', status: !anyOk ? 'failed' : allComplete ? 'complete' : 'partial', generated_at: nowIso, sections,
} } }];
