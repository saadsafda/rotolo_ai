const mary = { id: 'Y5iTR_CAIiS6OG4x', name: 'Mary Dalipe' };
const employeeRoles = new Set(['user', 'regular', 'regularuser', 'employee', 'staff', 'manager']);
const inactiveStatuses = new Set(['archived', 'inactive', 'deleted', 'disabled', 'pending', 'invited', 'suspended']);
const normalize = (text) => String(text ?? '').toLowerCase().replace(/[^a-z]/g, '');

const raw = String($input.first().json.mcpRaw);
const event = raw.split('\n').filter(line => line.startsWith('data:')).at(-1);
const rpc = JSON.parse(event ? event.slice(5).trim() : raw);
if (rpc.error || !rpc.result || rpc.result.isError) throw Error('Time Doctor directory call failed');
const directory = rpc.result.structuredContent ?? JSON.parse(rpc.result.content.find(item => item.type === 'text').text);
if (directory.status !== 'ok' || directory.truncated || directory.nextCursor || directory.next_cursor || directory.cursor ||
    !Array.isArray(directory.data) || (directory.totalCount != null && directory.totalCount !== directory.data.length)) {
  throw Error('Incomplete Time Doctor directory');
}

const cfg = $('Time Doctor - Report Parameters').first().json;
if (!/^\d{4}-\d{2}-\d{2}$/.test(cfg.reportDate)) throw Error('Use YYYY-MM-DD');

const selected = directory.data.filter(user =>
  user.archived !== true && user.isArchived !== true &&
  user.active !== false && user.isActive !== false &&
  !inactiveStatuses.has(normalize(user.status)) &&
  (user.id === mary.id || employeeRoles.has(normalize(user.role)))
);
const userIds = selected.map(user => user.id);
if (!userIds.length || new Set(userIds).size !== userIds.length ||
    selected.some(user => typeof user.id !== 'string' || !/^[A-Za-z0-9_-]+$/.test(user.id) ||
      typeof user.name !== 'string' || !user.name.trim())) {
  throw Error('No valid, unique active Time Doctor staff scope');
}

const missing = userIds.includes(mary.id) ? [] : [mary];
const intended = [...selected.map(({id, name}) => ({id, name})), ...missing];
const args = { from: cfg.reportDate, to: cfg.reportDate, timezone: cfg.timezone, limit: 500, user: userIds.join(',') };
const rpcFor = (name, arguments_) => ({ jsonrpc: '2.0', method: 'tools/call', params: { name, arguments: arguments_ }, id: 1 });
return [{ json: {
  summaryByUser: rpcFor('td_get_time_summary', {...args, groupBy: 'user'}),
  teamSummary: rpcFor('td_get_time_summary', args),
  timeline: rpcFor('td_get_worklog', {...args, detail: 'full'}),
  plannedShifts: rpcFor('td_list_work_schedules', args),
  userIds, intended, missing,
} }];
