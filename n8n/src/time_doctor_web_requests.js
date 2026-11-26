const scope = $('Time Doctor - Build Daily Requests').first().json;
const cfg = $('Time Doctor - Report Parameters').first().json;
const tools = JSON.parse($('Time Doctor MCP - Discover Tools').first().json.mcpRaw).result.tools;
const available = tools.some(tool => tool.name === 'td_get_productivity_breakdown' && tool.annotations?.readOnlyHint === true);
if (!available) return [{json: { skip: true }}];
return scope.userIds.map((userId, index) => ({json: {
  userId,
  request: {
    jsonrpc: '2.0', id: 1000 + index, method: 'tools/call',
    params: { name: 'td_get_productivity_breakdown', arguments: {
      from: cfg.reportDate, to: cfg.reportDate, timezone: cfg.timezone,
      user: userId, groupBy: 'webApp', limit: 500,
      fields: ['name', 'entity', 'trackedSec', 'activeSec', 'idleSec', 'idleMins'],
    }},
  },
}}));
