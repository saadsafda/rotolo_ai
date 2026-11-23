"""Builds the two importable n8n workflows for the app from the offline export bundle.

    python3 -I n8n/build_workflows.py <path-to-claude-workflow-handoff>

Outputs (new workflows only; the seven existing workflows are not modified):
  n8n/RE - APP - DoorLoop Snapshot - Read Only.json   copy of 03 that also returns structured tasks
  n8n/RE - APP - Daily Operations Report.json         sources -> report contract v1.0 -> Supabase
Both import unpublished (active: false); the schedule node is disabled.
"""
import copy
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE = sys.argv[1]
src = lambda f: open(os.path.join(HERE, 'src', f)).read()

# ───────── 1. DoorLoop snapshot copy (03 + structured task rows) ─────────
w03 = json.load(open(os.path.join(BUNDLE, '03_f181nRQxfGeiVgQ_5iPO9.json')))
dl = {k: copy.deepcopy(w03[k]) for k in ('nodes', 'connections', 'settings')}
dl['name'] = 'RE - APP - DoorLoop Snapshot - Read Only'
dl['active'] = False
mapping = next(n for n in dl['nodes'] if n['name'] == 'DoorLoop API Snapshot - Mapping Review')
code = mapping['parameters']['jsCode']
anchor = 'externalActionsExecuted:false,'
assert code.count(anchor) == 1, 'Mapping Review code changed; update build_workflows.py'
extra = (
    "appTaskRows:(()=>{const recent=$now.minus({days:14}).toISO();"
    "return data.Tasks.filter(t=>!/rent payment reminder/i.test(t.subject||'')&&(!closed.has(t.status)||"
    "(['COMPLETED','COMPLETE'].includes(t.status)&&String(t.updatedAt||'')>=recent)))"
    ".map(t=>({id:t.id,subject:clean(t.subject),type:t.type||null,status:t.status||null,priority:t.priority??null,"
    "dueDate:t.dueDate||null,property:props.get(t.property)||t.property||null,updatedAt:t.updatedAt||null}));})(),"
    "appReminderTaskCount:openTasks.filter(t=>/rent payment reminder/i.test(t.subject||'')).length,"
    "appLeasePropertyIds:Object.fromEntries(data.Leases.map(l=>[l.id,l.property])),"
)
mapping['parameters']['jsCode'] = code.replace(anchor, anchor + extra)
dl['nodes'].append({
    'parameters': {'content': '## RE - APP copy of 03 (read only)\nIdentical to "RE - DoorLoop API Snapshot - Read Only" except the last node also returns '
                   '`appTaskRows` (open tasks plus tasks completed in the last 14 days, with real task IDs), '
                   '`appReminderTaskCount` and `appLeasePropertyIds` for the Rotolo app. GET requests only.',
                   'height': 220, 'width': 420},
    'name': 'APP Copy Note', 'type': 'n8n-nodes-base.stickyNote', 'typeVersion': 1, 'position': [-400, -320],
    'id': 'app-copy-note'})
for n in dl['nodes']:
    if n['type'] == 'n8n-nodes-base.httpRequest':
        assert n['parameters'].get('method', 'GET') == 'GET', 'DoorLoop copy must stay read-only'

# ───────── 2. RE - APP - Daily Operations Report ─────────
def node(name, typ, ver, pos, params=None, **extra):
    n = {'parameters': params or {}, 'name': name, 'type': typ, 'typeVersion': ver, 'position': pos,
         'id': 'app-' + name.lower().replace(' ', '-').replace('(', '').replace(')', '').replace('+', 'and')[:50]}
    n.update(extra)
    return n

def run_sub(name, wf_id, pos):
    return node(name, 'n8n-nodes-base.executeWorkflow', 1.2, pos,
                {'workflowId': {'__rl': True, 'value': wf_id, 'mode': 'id'}, 'options': {'waitForSubWorkflow': True}},
                onError='continueRegularOutput')

x = lambda i: -200 + 240 * i
nodes = [
    node('Run App Report', 'n8n-nodes-base.manualTrigger', 1, [x(0), 0]),
    node('Daily 09:05 - New York (enable after review)', 'n8n-nodes-base.scheduleTrigger', 1.2, [x(0), 200],
         {'rule': {'interval': [{'field': 'cronExpression', 'expression': '5 9 * * *'}]}}, disabled=True),
    node('App Report Configuration', 'n8n-nodes-base.code', 2, [x(1), 0], {'jsCode': src('config.js')}),
    run_sub('FUB + Harry Email Evidence (04)', 'vnU7rkSlA3Oh_sQXXTFDs', [x(2), 0]),
    run_sub('FUB Deals Fallback (05)', 'Z4X4z-NcqRJDD-0ma7hs3', [x(3), 0]),
    run_sub('DoorLoop Snapshot (APP copy of 03)', 'PASTE_ID_OF_RE_APP_DOORLOOP_SNAPSHOT', [x(4), 0]),
    run_sub('Time Doctor (07)', 's7sjE_OYgY1Luiz14VcSb', [x(5), 0]),
    node('Build App Report v1.0', 'n8n-nodes-base.code', 2, [x(6), 0], {'jsCode': src('build_app_report.js')}),
    node('OpenAI - Guarded Summary', 'n8n-nodes-base.httpRequest', 4.2, [x(7), 0], {
        'method': 'POST', 'url': 'https://api.openai.com/v1/chat/completions',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'openAiApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.aiRequest) }}',
        'options': {'timeout': 60000}},
        credentials={'openAiApi': {'id': '3nHgJjg9d6TzDyqd', 'name': 'OpenAI - Harry'}}, onError='continueRegularOutput'),
    node('Attach Guarded AI Summary', 'n8n-nodes-base.code', 2, [x(8), 0], {'jsCode': src('attach_summary.js')}),
    node('Store Report in Rotolo App (Supabase)', 'n8n-nodes-base.httpRequest', 4.2, [x(9), 0], {
        'method': 'POST',
        'url': "={{ $('App Report Configuration').first().json.supabaseUrl }}/rest/v1/rpc/n8n_ingest_report",
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'sendHeaders': True,
        'headerParameters': {'parameters': [
            {'name': 'apikey', 'value': "={{ $('App Report Configuration').first().json.supabasePublishableKey }}"}]},
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify({ p_report: $json.report }) }}',
        'options': {'timeout': 60000}},
        credentials={'httpHeaderAuth': {'name': 'Rotolo App - Ingest Secret'}}),
    node('Ingest Receipt', 'n8n-nodes-base.code', 2, [x(10), 0], {'jsCode': src('receipt.js')}),
    node('Setup Note', 'n8n-nodes-base.stickyNote', 1, [x(1), -420], {
        'content': '## RE - APP - Daily Operations Report\n'
                   'Collects the read-only sources, converts them to the app report format (contract v1.0) and stores the '
                   'report in the Rotolo app (Supabase). No email, WhatsApp, DoorLoop writes or tenant contact.\n\n'
                   '**Before the first run**\n'
                   '1. Import "RE - APP - DoorLoop Snapshot - Read Only", save it, and paste its workflow ID into '
                   '"DoorLoop Snapshot (APP copy of 03)".\n'
                   '2. Create credential "Rotolo App - Ingest Secret" (Header Auth): name `x-ingest-secret`, value = the secret '
                   'from the Supabase setup SQL.\n'
                   '3. Run manually. Keep the schedule disabled until a manual run has been reviewed in the app.\n\n'
                   'A failing source becomes "unavailable" in the report; it never stops the other sources. '
                   'The FUB-only report (05) also runs each time (read only); its deals are used only if 04 fails, '
                   'for example on Gmail authorisation.',
        'height': 360, 'width': 720}),
]
chain = ['App Report Configuration', 'FUB + Harry Email Evidence (04)', 'FUB Deals Fallback (05)',
         'DoorLoop Snapshot (APP copy of 03)', 'Time Doctor (07)', 'Build App Report v1.0', 'OpenAI - Guarded Summary',
         'Attach Guarded AI Summary', 'Store Report in Rotolo App (Supabase)', 'Ingest Receipt']
conn = {a: {'main': [[{'node': b, 'type': 'main', 'index': 0}]]} for a, b in zip(chain, chain[1:])}
conn['Run App Report'] = {'main': [[{'node': 'App Report Configuration', 'type': 'main', 'index': 0}]]}
conn['Daily 09:05 - New York (enable after review)'] = {'main': [[{'node': 'App Report Configuration', 'type': 'main', 'index': 0}]]}
app = {'name': 'RE - APP - Daily Operations Report', 'nodes': nodes, 'connections': conn, 'active': False,
       'settings': {'executionOrder': 'v1', 'timezone': 'America/New_York', 'callerPolicy': 'workflowsFromSameOwner',
                    'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'all'}}

for wf in (dl, app):
    path = os.path.join(HERE, wf['name'] + '.json')
    with open(path, 'w') as f:
        json.dump(wf, f, indent=2, ensure_ascii=False)
    print('wrote', os.path.relpath(path, os.path.dirname(HERE)), len(wf['nodes']), 'nodes')
