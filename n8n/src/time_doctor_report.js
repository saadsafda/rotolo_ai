
const cfg=$('Time Doctor - Report Parameters').first().json;
function unpack(name, allowNoData = false) {
  const input = $(name).first().json;
  let rpc;
  try {
    rpc = JSON.parse(input.mcpRaw);
  } catch {
    const events = String(input.mcpRaw).split('\n').filter(line => line.startsWith('data:'));
    rpc = JSON.parse(events.at(-1).slice(5).trim());
  }
  if (rpc.error || !rpc.result || rpc.result.isError) throw Error(name + ': Time Doctor request failed');
  const response = rpc.result;
  const data = response.structuredContent ?? JSON.parse(response.content.find(c => c.type === 'text').text);
  if (data.truncated || data.nextCursor || data.next_cursor || data.cursor) {
    throw Error(name + ': result is paged or truncated');
  }
  const noData = allowNoData && data.status === 'no_data_in_range';
  if (data.status !== 'ok' && !noData) throw Error(name + ': unexpected status ' + data.status);
  if (data.timezoneUsed && data.timezoneUsed !== cfg.timezone) throw Error(name + ': timezone mismatch');
  if (!Array.isArray(data.data) || (data.totalCount !== undefined && data.totalCount !== data.data.length) ||
      (noData && data.data.length !== 0)) throw Error(name + ': inconsistent rows');
  return data;
}
const users = unpack('Time Doctor MCP - Read User Directory');
const per = unpack('Time Doctor MCP - User Daily Totals', true);
const overall = unpack('Time Doctor MCP - Team Daily Total', true);
const timeline = unpack('Time Doctor MCP - Daily Timeline', true);
const shifts = unpack('Time Doctor MCP - Planned Shifts', true);
const who=$('Time Doctor - Validate Workspace').first().json;
const scope=$('Time Doctor - Build Daily Requests').first().json;
const selected=new Set(scope.userIds);
const toolsRpc=JSON.parse($('Time Doctor MCP - Discover Tools').first().json.mcpRaw);if(toolsRpc.error||!Array.isArray(toolsRpc.result?.tools))throw Error('Tool discovery failed');const tools=toolsRpc.result.tools;
const metrics = ['trackedSec', 'activeSec', 'idleSec', 'totalSec', 'meetingSec', 'productiveSec', 'unproductiveSec', 'neutralSec', 'unratedSec', 'idleMins'];
const emptyTeam = overall.status === 'no_data_in_range';
if (emptyTeam && (per.data.length || timeline.data.length)) throw Error('Time Doctor returned activity alongside an empty team total');
if (!emptyTeam && overall.data.length !== 1) throw Error('Expected one team total');
const total = emptyTeam
  ? {...Object.fromEntries(metrics.map(metric => [metric, 0])), trackedHms: '0:00:00', activeHms: '0:00:00', idleHms: '0:00:00', meetingHms: '0:00:00'}
  : overall.data[0];
for (const metric of metrics) {
  const sum = per.data.reduce((value, user) => value + Number(user[metric] || 0), 0);
  if (sum !== Number(total[metric] || 0)) throw Error('User/team reconciliation failed for ' + metric);
}
const noActivity = per.data.length === 0 && timeline.data.length === 0 &&
  (emptyTeam || total.trackedSec === 0);
const seenIds=new Set();for(const u of per.data){if(seenIds.has(u.userId)||!selected.has(u.userId))throw Error('Unresolved/duplicate user');seenIds.add(u.userId);for(const m of metrics)if(!Number.isFinite(u[m])||u[m]<0)throw Error('Invalid '+m);if(u.activeSec!==u.totalSec-u.idleSec)throw Error('Activity identity mismatch');const modeTotal=['computerSec','offcomputerSec','mobileSec','manualSec','paidBreakSec','paidLeaveSec'].reduce((a,k)=>a+Number(u[k]||0),0);if(modeTotal!==u.trackedSec)throw Error('Tracked mode split mismatch');}
const nameMap=new Map();for(const u of users.data){if(!nameMap.has(u.name))nameMap.set(u.name,[]);nameMap.get(u.name).push(u.id);}
const spans=new Map();for(const w of timeline.data){const matches=nameMap.get(w.userName)||[];const id=w.userId||(matches.length===1?matches[0]:null);if(!id || !selected.has(id))throw Error('Unresolved or out-of-scope timeline user');const a=Date.parse(w.start),b=Date.parse(w.end);if(!Number.isFinite(a)||!Number.isFinite(b)||b<=a)throw Error('Invalid timeline boundaries');if(!spans.has(id))spans.set(id,[]);spans.get(id).push({start:a,end:b,mode:w.mode,startRaw:w.start,endRaw:w.end});}
const timeLocal=v=>new Intl.DateTimeFormat('en-GB',{timeZone:cfg.timezone,hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(new Date(v));
const gaps=[];for(const [id,ss] of spans){const sorted=ss.sort((a,b)=>a.start-b.start),merged=[];for(const s of sorted){const last=merged[merged.length-1];if(last&&s.start<=last.end)last.end=Math.max(last.end,s.end);else merged.push({start:s.start,end:s.end});}for(let i=1;i<merged.length;i++){const before=merged[i-1],after=merged[i],seconds=(after.start-before.end)/1000;if(seconds>=300)gaps.push({userId:id,userName:users.data.find(u=>u.id===id).name,type:'between_recorded_blocks',start:new Date(before.end).toISOString(),end:new Date(after.start).toISOString(),startLocal:timeLocal(before.end),endLocal:timeLocal(after.start),approxMinutes:seconds/60,boundaryPrecision:'MCP start/end values are minute-resolution; gap duration is approximate',requiresReview:true,interpretation:'Untracked interval. May be a break or offline work; no non-work conclusion.'});}}
const uiValidation = { status: 'not_checked_for_this_date' };
const warnings=[
  ...scope.missing.map(user => user.name + ' is missing from the active configured directory scope.'),
  ...scope.intended.filter(user => !noActivity && selected.has(user.id) && !seenIds.has(user.id))
    .map(user => user.name + ' has no returned activity totals for this date.'),
  per.timezoneWarning,overall.timezoneWarning,timeline.timezoneWarning,shifts.timezoneWarning].filter(Boolean);
const rows=per.data.map(u=>({userId:u.userId,name:u.userName,tracked:u.trackedHms,trackedSec:u.trackedSec,nonIdleComputer:u.activeHms,nonIdleComputerSec:u.activeSec,idleSecondsTotal:u.idleHms,idleSec:u.idleSec,wholeIdleMinutes:u.idleMins,wholeIdleMinutePercent:u.idlePct,idleSecondsPercent:u.idleSecPct,meeting:u.meetingHms,meetingSec:u.meetingSec,unproductiveWebsiteAppPercent:u.unproductivePct,manual:u.manualHms,mobile:u.mobileHms}));
for (const user of scope.intended) {
  if (selected.has(user.id) && !seenIds.has(user.id)) {
    rows.push({userId: user.id, name: user.name, tracked: noActivity ? '0:00:00' : 'Not returned',
      trackedSec: noActivity ? 0 : null});
  }
}
const report=['# Time Doctor - Validated Daily Activity',cfg.reportDate+' | '+cfg.timezone+' | '+who.companyName,'Live read-only MCP connection. '+tools.length+' available tools.','','## Validation','User totals equal the separate team total for tracked, active, idle, meetings and productivity metrics.','Web comparison: '+uiValidation.status+'.','','## Selected team total','Tracked: '+total.trackedHms+' | Non-idle computer: '+total.activeHms+' | Meeting: '+total.meetingHms,'Whole idle minutes: '+total.idleMins+' | All idle seconds expressed as duration: '+total.idleHms,'Whole idle minutes and idle seconds use different measures and must not be substituted for each other.','','## Per user','| User | Tracked | Non-idle computer | Whole idle minutes | Idle-minute % | Meetings |','|---|---|---|---|---|---|',...rows.map(u=>'| '+[u.name,u.tracked,u.nonIdleComputer,u.wholeIdleMinutes,u.wholeIdleMinutePercent,u.meeting].join(' | ')+' |'),'','## Timeline gaps of at least 5 minutes',...(gaps.length?gaps.map(g=>'- '+g.userName+': approximately '+g.approxMinutes+' minutes, '+g.startLocal+'–'+g.endLocal+' '+cfg.timezone+'. Review only; a break or offline work may explain it.'):['No between-block gaps of at least 5 minutes in the returned timeline.']),'','Planned shifts returned: '+shifts.data.length+'. No start-of-shift/end-of-shift absence conclusions are made.','Continuous five-minute idle events: unavailable from these aggregate/time-block results. Aggregate idle does not establish a continuous idle interval.','Users without entries: '+(per.coverage?.usersWithNoEntries??'not supplied')+'; no entries is not a non-work finding.','Scope: Mary Dalipe and active employees selected from the Time Doctor directory. No screenshots, payroll or employment actions were used.',...warnings].join('\n');
return [{json:{reportTitle:'Time Doctor Validated Daily Activity',source:'LIVE Time Doctor MCP',company:who.companyName,companyId:who.companyId,readOnly:true,reportDate:cfg.reportDate,timezoneUsed:per.timezoneUsed || overall.timezoneUsed || cfg.timezone,activityStatus:noActivity ? 'no_activity' : 'recorded',generatedAt:new Date().toISOString(),availableToolCount:tools.length,availableTools:tools.map(t=>({name:t.name,readOnly:t.annotations?.readOnlyHint===true})),validation:{apiUserTeamTotalsReconcile:true,metricsCompared:metrics,web:uiValidation},coverage:per.coverage,intendedUsers:scope.intended,missingUsers:scope.missing,
directoryUsers:users.data.filter(u=>selected.has(u.id)).map(u=>({id:u.id,name:u.name,timezone:u.timezone||who.timezone})),teamTotal:{tracked:total.trackedHms,trackedSec:total.trackedSec,activeSec:total.activeSec,idleSec:total.idleSec,meetingSec:total.meetingSec,nonIdleComputer:total.activeHms,meeting:total.meetingHms,wholeIdleMinutes:total.idleMins,idleSecondsDuration:total.idleHms},rows,timelineRows:timeline.data,betweenBlockGaps:gaps,plannedShiftCount:shifts.data.length,continuousIdleEventDetection:{available:false,reason:'MCP returned aggregate idle and work blocks, not continuous idle-event boundaries'},timezoneWarnings:warnings,report}}];
