import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const workflow = JSON.parse(readFileSync(new URL('../RE - APP - Time Doctor Snapshot - Read Only.json', import.meta.url)));
const code = name => workflow.nodes.find(node => node.name === name).parameters.jsCode;
const cfg = {reportDate: '2026-11-25', timezone: 'America/New_York'};
const mary = {id: 'Y5iTR_CAIiS6OG4x', name: 'Mary Dalipe', role: 'admin'};
const owner = {id: 'owner', name: 'Company owner', role: 'owner'};
const admin = {id: 'admin', name: 'Other administrator', role: 'admin'};
const employee = {id: 'employee-new', name: 'New Employee', role: 'user'};
const manager = {id: 'manager-new', name: 'New Manager', role: 'manager'};
const envelope = data => ({mcpRaw: JSON.stringify({result: {structuredContent: data}})});

function scope(users, extra = {}) {
  const input = envelope({status: 'ok', data: users, totalCount: users.length, ...extra});
  const $ = () => ({first: () => ({json: cfg})});
  return new Function('$', '$input', code('Time Doctor - Build Daily Requests'))($, {first: () => ({json: input})})[0].json;
}

test('current company reports only Mary even though she is an Admin', () => {
  const result = scope([admin, owner, mary]);
  assert.deepEqual(result.intended, [{id: mary.id, name: mary.name}]);
  assert.deepEqual(result.missing, []);
  assert.equal(result.summaryByUser.params.arguments.user, mary.id);
});

test('future employees join automatically and only if active', () => {
  const result = scope([admin, owner, mary, employee, manager,
    {id: 'regular', name: 'Regular User', role: 'Regular User'},
    {id: 'client', name: 'Client', role: 'client'},
    {id: 'archive', name: 'Archived User', role: 'user', archived: true},
    {id: 'pending', name: 'Pending User', role: 'user', status: 'invited'},
    {id: 'inactive', name: 'Inactive User', role: 'user', isActive: false}]);
  assert.deepEqual(result.userIds, [mary.id, employee.id, manager.id, 'regular']);
  for (const query of [result.summaryByUser, result.teamSummary, result.timeline, result.plannedShifts]) {
    assert.equal(query.params.arguments.user, result.userIds.join(','));
  }
});

test('missing Mary and incomplete or invalid directories remain visible', () => {
  assert.deepEqual(scope([owner, employee]).missing, [{id: mary.id, name: mary.name}]);
  assert.throws(() => scope([owner, admin]), /No valid, unique/);
  assert.throws(() => scope([mary, employee], {nextCursor: 'next-page'}), /Incomplete Time Doctor directory/);
  assert.throws(() => scope([mary, employee, employee]), /No valid, unique/);
});

test('a new employee with no returned totals remains visible without invented hours', () => {
  const directory = [mary, employee, owner];
  const maryTotals = {
    userId: mary.id, userName: mary.name, trackedSec: 3600, activeSec: 3600, idleSec: 0,
    totalSec: 3600, meetingSec: 0, productiveSec: 0, unproductiveSec: 0, neutralSec: 0,
    unratedSec: 3600, idleMins: 0, computerSec: 3600,
  };
  const outputs = {
    'Time Doctor - Report Parameters': cfg,
    'Time Doctor MCP - Read User Directory': envelope({status: 'ok', data: directory}),
    'Time Doctor MCP - User Daily Totals': envelope({status: 'ok', data: [maryTotals]}),
    'Time Doctor MCP - Team Daily Total': envelope({status: 'ok', data: [maryTotals]}),
    'Time Doctor MCP - Daily Timeline': envelope({status: 'no_data_in_range', data: []}),
    'Time Doctor MCP - Planned Shifts': envelope({status: 'no_data_in_range', data: []}),
    'Time Doctor - Validate Workspace': {companyName: 'Test company', readOnly: true},
    'Time Doctor - Build Daily Requests': scope(directory),
    'Time Doctor MCP - Discover Tools': {mcpRaw: JSON.stringify({result: {tools: []}})},
  };
  const $ = name => ({first: () => ({json: outputs[name]})});
  const report = new Function('$', code('Time Doctor - Validated Daily Report'))($)[0].json;
  assert.deepEqual(report.rows.map(row => [row.userId, row.trackedSec]), [[mary.id, 3600], [employee.id, null]]);
  assert.deepEqual(report.missingUsers, []);
  assert.match(report.timezoneWarnings[0], /New Employee has no returned activity totals/);
});

test('web usage binds responses to the requested staff and records gaps in coverage', () => {
  const requests = [{userId: mary.id, request: {id: 1000}}, {userId: employee.id, request: {id: 1001}}];
  const response = {mcpRaw: JSON.stringify({id: 1000, result: {structuredContent: {
    status: 'ok', timezoneUsed: cfg.timezone, totalCount: 2, truncated: true,
    data: [{name: 'https://app.doorloop.com/leases?private=x', trackedSec: 58, activeSec: 29, idleSec: 29, idleMins: 0}],
  }}})};
  const $ = name => ({
    first: () => ({json: name.endsWith('Report Parameters') ? cfg : {reportDate: cfg.reportDate}}),
    all: () => (name.includes('Build Web App Requests') ? requests : [response]).map(json => ({json})),
  });
  const report = new Function('$', code('Time Doctor - Attach Web App Usage'))($)[0].json;
  assert.deepEqual(report.webAppUsage, [
    {userId: mary.id, status: 'partial', rows: [{name: 'app.doorloop.com', tracked_sec: 58, active_sec: 29, idle_sec: 29, idle_minutes: 0}]},
    {userId: employee.id, status: 'unavailable', rows: []},
  ]);
});
