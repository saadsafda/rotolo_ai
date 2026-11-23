// Runs the n8n Code-node scripts outside n8n with sample sub-workflow outputs.
// Usage: node n8n/test/run_nodes.mjs [scenario] > report.json
import fs from 'node:fs';
const src = (f) => fs.readFileSync(new URL('../src/' + f, import.meta.url), 'utf8');
const scenario = process.argv[2] || 'ok';

const outputs = {
  'App Report Configuration': [{ timezone: 'America/New_York', reportDay: '2026-11-20', workDay: '2026-11-19',
    reportKey: 'OPS-20261120', aiModel: 'gpt-5-nano' }],
  'FUB + Harry Email Evidence (04)': [scenario === 'gmail_down' ? { error: { message: 'Gmail mailbox guard failed' } } : {
    fetchedAt: '2026-11-20T14:01:00.000Z', complete: true, dealsFetched: 2, pipelinesFetched: 1,
    rows: [
      { dealId: 101, property: '12 Main St Middletown', pipeline: 'Acquisitions', stage: 'Under Contract', classification: 'open',
        projectedCloseDate: '2026-11-25', daysToProjectedClose: 5, stageEnteredAt: '2026-11-01T10:00:00Z', daysInStage: 19,
        assignedUsers: ['Harry Rotolo'], flags: ['Projected close within 7 calendar days'], linkedPersonIds: [5001],
        latestLinkedCommunication: { personId: 5001, personName: 'Seller One', date: '2026-11-19T15:00:00Z', type: 'Email', direction: 'outbound', content: 'PRIVATE BODY' },
        attorneyEmailReview: { status: 'VA_OUTREACH_VISIBLE', messageCount: 1, latest: { id: 'g1' }, lastVaOutreach: { id: 'g1' }, verifiedReply: null } },
      { dealId: '102', property: '7 Oak Rd Binghamton', pipeline: 'Acquisitions', stage: 'Closed', classification: 'closed_by_system_flag',
        projectedCloseDate: null, daysToProjectedClose: null, daysInStage: 3, assignedUsers: [], flags: [], linkedPersonIds: [],
        latestLinkedCommunication: null, attorneyEmailReview: { status: 'NO_MATCHED_EVIDENCE_IN_SCOPE', messageCount: 0 } },
    ],
    communicationRows: [],
    emailEvidenceCoverage: { complete: false, nextPagePending: true, mailbox: 'harryrotoloiv@gmail.com', readable: 40, matched: 1, unmatched: 1,
      warnings: ['Email result batch incomplete: older messages remain.'] },
    emailEvidenceReview: [{ id: 'g1', threadId: 't1', date: 'Wed, 19 Nov 2026 10:00:00 -0500', from: 'va@rotolo.example', to: ['law@revellalaw.com'],
      subject: '12 Main St - title', excerpt: 'Could you send the title commitment?', kind: 'VA_OUTREACH', mapping: 'UNIQUE_PROPERTY_DEAL', url: null }],
    unmatchedEmailReview: [{ id: 'g2', subject: 'Invoice', date: '2026-11-18T10:00:00Z', reason: 'No exact property address in subject' }],
  }],
  'FUB Deals Fallback (05)': [{ fetchedAt: '2026-11-20T14:01:30.000Z', complete: true, dealsFetched: 1, pipelinesFetched: 1,
    rows: [{ dealId: 101, property: '12 Main St Middletown', pipeline: 'Acquisitions', stage: 'Under Contract', classification: 'open', flags: [] }] }],
  'DoorLoop Snapshot (APP copy of 03)': [scenario === 'doorloop_down' ? { error: 'Incomplete source: Charges' } : {
    collectedAt: '2026-11-20T14:03:00.000Z', reportDate: '2026-11-20', sourceCounts: { Leases: 2, Tasks: 3 },
    balanceRows: [
      { leaseId: '64a1b2c3d4e5f60718293a4b', reference: 'L-1', property: '22 Oak St', leaseName: 'Tenant A', status: 'ACTIVE', collectionStatus: 'OVERDUE',
        totalBalanceDue: 1450.07, overdueBalance: 700, currentBalance: 750.07, upcomingBalance: 0 },
      { leaseId: '64a1b2c3d4e5f60718293a4c', reference: 'L-2', property: '22 Oak St', leaseName: 'Tenant B', status: 'ACTIVE', collectionStatus: 'CURRENT',
        totalBalanceDue: null, overdueBalance: null, currentBalance: null, upcomingBalance: null },
    ],
    paymentRows: [{ id: 'p1', date: '2026-11-03', leaseId: '64a1b2c3d4e5f60718293a4b', amountReceived: 750.1, depositStatus: 'DEPOSITED', returnedPaymentLinked: false }],
    taskStatuses: { NOT_STARTED: 1, COMPLETED: 1 }, openTaskCount: 1,
    appTaskRows: [
      { id: 't-1', subject: 'Leaking faucet', type: 'TENANT_REQUEST', status: 'NOT_STARTED', priority: 'high', dueDate: '2026-11-10', property: '22 Oak St', updatedAt: '2026-11-18T10:00:00Z' },
      { id: 't-2', subject: 'Smoke detector', type: 'TENANT_REQUEST', status: 'COMPLETED', priority: null, dueDate: '2026-11-15', property: '22 Oak St', updatedAt: '2026-11-19T10:00:00Z' },
    ],
    appReminderTaskCount: 4, appLeasePropertyIds: { '64a1b2c3d4e5f60718293a4b': 'prop1' },
  }],
  'Time Doctor (07)': [scenario === 'td_down' ? { error: { message: 'Target user missing: Lhaura Somera' } } : {
    reportDate: '2026-11-19', timezoneUsed: 'America/New_York', generatedAt: '2026-11-20T14:04:00.000Z',
    directoryUsers: [{ id: 'u1', name: 'Mary Dalipe' }, { id: 'u2', name: 'Lhaura Somera' }],
    rows: [{ userId: 'u1', name: 'Mary Dalipe', trackedSec: 28800, nonIdleComputerSec: 27000, idleSec: 1800, wholeIdleMinutes: 30, meetingSec: 600 },
           { userId: 'u2', name: 'Lhaura Somera', trackedSec: 25200, nonIdleComputerSec: 24000, idleSec: 1200, wholeIdleMinutes: 20, meetingSec: null }],
    teamTotal: { trackedSec: 54000 }, betweenBlockGaps: [{ userId: 'u1', start: '2026-11-19T17:00:00.000Z', end: '2026-11-19T17:20:00.000Z', approxMinutes: 20, interpretation: 'Untracked interval.' }],
    validation: { apiUserTeamTotalsReconcile: true }, timezoneWarnings: [],
  }],
  'OpenAI - Guarded Summary': [scenario === 'ai_digits'
    ? { choices: [{ message: { content: 'Two sources need review.' + ' 3 issues.' } }] }
    : { choices: [{ message: { content: JSON.stringify([
      'doorloop_tasks', 'fub_deals', 'doorloop_rent', 'email_evidence', 'time_doctor',
    ]) } }] }],
};

function run(code, nodeOutputs, input) {
  const $ = (name) => ({ all: () => (nodeOutputs[name] || (() => { throw new Error('no node ' + name); })()).map((json) => ({ json })),
    first: () => ({ json: nodeOutputs[name][0] }) });
  const fn = new Function('$', '$input', '$execution', '$now', code);
  return fn($, { first: () => ({ json: input }), all: () => [{ json: input }] }, { id: 'exec-test-1' }, null);
}
if (scenario === 'td_no_activity' || scenario === 'td_partial') {
  const [snapshot] = outputs['Time Doctor (07)'];
  Object.assign(snapshot, {
    activityStatus: 'no_activity',
    rows: snapshot.directoryUsers.map(user => ({ userId: user.id, name: user.name, trackedSec: 0 })),
    teamTotal: { trackedSec: 0 }, betweenBlockGaps: [],
  });
  if (scenario === 'td_partial') {
    snapshot.intendedUsers = [...snapshot.directoryUsers];
    snapshot.missingUsers = snapshot.directoryUsers.splice(1);
    snapshot.rows.splice(1);
  }
}
const built = run(src('build_app_report.js'), outputs)[0].json;
outputs['Build App Report v1.0'] = [built];
const final = run(src('attach_summary.js'), outputs, outputs['OpenAI - Guarded Summary'][0])[0].json;
process.stdout.write(JSON.stringify(final.report, null, 1));
