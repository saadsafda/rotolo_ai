// These fields are per-app totals on the selected work date. No URLs, page titles,
// screenshots, device locations, or reconstructed idle intervals are collected.
const number = value => Number.isSafeInteger(value) && value >= 0 ? value : null;
const label = value => {
  if (typeof value !== 'string') return null;
  const name = value.trim().replace(/[\u0000-\u001f\u007f]/g, '');
  if (!name || name.length > 180) return null;
  if (/^(?:https?:\/\/|www\.)|[/?#]/i.test(name)) {
    try { return new URL(/^https?:\/\//i.test(name) ? name : 'https://' + name).hostname.toLowerCase(); }
    catch { return null; }
  }
  return name;
};
const requests = $('Time Doctor - Build Web App Requests').all().map(item => item.json);
const cfg = $('Time Doctor - Report Parameters').first().json;
const output = new Map(requests.filter(item => item.request).map(item => [item.request.id, { userId: item.userId, status: 'unavailable', rows: [] }]));
const seen = new Set();
let responses = [];
try { responses = $('Time Doctor MCP - Web App Usage').all(); } catch { /* optional tool is unavailable */ }
for (const item of responses) {
  try {
    const raw = String(item.json.mcpRaw ?? '');
    const rpc = JSON.parse(raw.startsWith('{') ? raw : raw.split('\n').filter(line => line.startsWith('data:')).at(-1)?.slice(5));
    const row = output.get(rpc.id);
    if (!row) continue;
    if (seen.has(rpc.id)) { row.status = 'unavailable'; row.rows = []; continue; }
    seen.add(rpc.id);
    if (rpc.error || rpc.result?.isError) continue;
    const data = rpc.result?.structuredContent ?? JSON.parse(rpc.result?.content?.find(item => item.type === 'text')?.text ?? '{}');
    if (!['ok', 'no_data_in_range'].includes(data.status) || data.timezoneUsed !== cfg.timezone || !Array.isArray(data.data) ||
        data.status === 'no_data_in_range' && data.data.length) continue;
    row.rows = data.data.flatMap(source => {
      const name = label(source.name);
      const tracked = number(source.trackedSec);
      return name && tracked != null ? [{
        name, tracked_sec: tracked, active_sec: number(source.activeSec), idle_sec: number(source.idleSec),
        idle_minutes: number(source.idleMins),
      }] : [];
    });
    row.status = data.truncated || data.nextCursor || data.next_cursor || data.cursor ||
      data.totalCount !== row.rows.length || row.rows.length !== data.data.length || data.timezoneWarning
      ? 'partial' : 'complete';
  } catch { /* usage collection is optional; the core activity report still works */ }
}
const webAppUsage = [...output.values()];
return [{json: {...$('Time Doctor - Validated Daily Report').first().json, webAppUsage}}];
