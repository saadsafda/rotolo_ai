"""Generate the queue worker from the separate app report workflow and demo fixture."""

import argparse
import json
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--doorloop-workflow-id', default='PASTE_ID_OF_RE_APP_DOORLOOP_SNAPSHOT')
parser.add_argument('--time-doctor-workflow-id', default='s7sjE_OYgY1Luiz14VcSb')
parser.add_argument('--edge-anon-jwt', help='Public Supabase legacy anon JWT for the push Edge Function gateway')
parser.add_argument('--credential-id', help='Existing Rotolo worker Header Auth credential ID')
deployment = parser.parse_args()
if deployment.edge_anon_jwt and not deployment.credential_id:
    parser.error('Report push also requires the worker Header Auth credential ID')

HERE = Path(__file__).resolve().parent
app = json.loads((HERE / 'RE - APP - Daily Operations Report.json').read_text())
fixture = json.loads((HERE.parent / 'assets/fixtures/synthetic_reports.json').read_text())
public_config = json.loads((HERE.parent / 'config/supabase.json').read_text())
if isinstance(fixture, dict):
    fixture = fixture['reports']
demo_sections = fixture[0]['sections']

workflow = {
    'name': 'RE - APP - Report Queue Worker',
    'nodes': [],
    'connections': {},
    'active': False,
    # Avoid retaining vendor records or error payloads in the worker's history.
    'settings': {
        'executionOrder': 'v1', 'timezone': 'America/New_York',
        'saveDataErrorExecution': 'none', 'saveDataSuccessExecution': 'none',
        'saveManualExecutions': False, 'executionTimeout': 840,
    },
}
existing = {node['name']: node for node in app['nodes']}


def add(name, kind, version, params, *, row=0, x=None, **extra):
    position = [len(workflow['nodes']) * 225 if x is None else x, row * 210]
    workflow['nodes'].append({
        'id': str(uuid5(NAMESPACE_URL, workflow['name'] + '/' + name)),
        'name': name, 'type': 'n8n-nodes-base.' + kind, 'typeVersion': version,
        'position': position, 'parameters': params, **extra,
    })
    return name


def code(name, script, **extra):
    return add(name, 'code', 2, {'jsCode': script}, **extra)


def existing_node(name):
    item = existing[name]
    return add(name, item['type'].split('.')[-1], item['typeVersion'], item['parameters'],
               **{k: item[k] for k in ('credentials', 'onError') if k in item},
               alwaysOutputData=True)


def rpc(name, endpoint, body, *, full_response=False, functions_api=False):
    response = {'fullResponse': True, 'responseFormat': 'text'} if full_response else {}
    api_path = '/functions/v1/' if functions_api else '/rest/v1/rpc/'
    api_key = deployment.edge_anon_jwt if functions_api else public_config['SUPABASE_PUBLISHABLE_KEY']
    if functions_api:
        response = {'fullResponse': True, 'neverError': True}
    return add(name, 'httpRequest', 4.2, {
        'method': 'POST',
        'url': public_config['SUPABASE_URL'].rstrip('/') + api_path + endpoint,
        'authentication': 'genericCredentialType' if deployment.credential_id else 'none',
        **({'genericAuthType': 'httpHeaderAuth'} if deployment.credential_id else {}),
        'sendHeaders': True, 'headerParameters': {'parameters': [
            {'name': 'apikey', 'value': api_key},
            *([{'name': 'Authorization', 'value': 'Bearer ' + deployment.edge_anon_jwt}] if functions_api else []),
        ]},
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': body,
        'options': {'timeout': 15000, 'response': {'response': response}},
    }, **({'onError': 'continueRegularOutput'} if functions_api else {}), **({'credentials': {'httpHeaderAuth': {
        'name': 'Rotolo App - Ingest Secret', 'id': deployment.credential_id,
    }}} if deployment.credential_id else {}))


def branch(name, expression, **extra):
    return add(name, 'if', 2.2, {
        'conditions': {
            'options': {'caseSensitive': True, 'typeValidation': 'strict', 'version': 2},
            'conditions': [{'id': str(uuid5(NAMESPACE_URL, name)), 'leftValue': expression,
                            'rightValue': '', 'operator': {'type': 'boolean', 'operation': 'true',
                                                          'singleValue': True}}],
            'combinator': 'and',
        },
        'options': {},
    }, **extra)


def connect(source, destination, output=0):
    edges = workflow['connections'].setdefault(source, {'main': []})['main']
    while len(edges) <= output:
        edges.append([])
    edges[output].append({'node': destination, 'type': 'main', 'index': 0})


def chain(*names):
    for source, destination in zip(names, names[1:]):
        connect(source, destination)


run_id = "$('Claim Report Request').first().json.sync_run_id"


def progress(stage, status="'running'"):
    return rpc('Progress - ' + stage, 'n8n_app_report_progress',
               "={{ JSON.stringify({ p_run: " + run_id + ", p_stage: '" + stage
               + "', p_status: " + status + " }) }}", full_response=True)


manual = add('Poll Once', 'manualTrigger', 1, {}, row=-1, x=0)
schedule = add('Poll Every Minute', 'scheduleTrigger', 1.2,
               {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 1}]}}, x=0)
claim = rpc('Claim Report Request', 'n8n_claim_app_report', '{}')
claimed = branch('Work Available?', '={{ $json.claimed === true }}')
config = code('App Report Configuration', """
const request = $input.first().json;
const reportDay = request.business_date;
const previousDay = new Date(reportDay + 'T00:00:00Z');
previousDay.setUTCDate(previousDay.getUTCDate() - 1);
const workDay = previousDay.toISOString().slice(0, 10);
if (!workDay || !request.sync_run_id) throw Error('Invalid report request');
return [{json: {
  id: request.sync_run_id, mode: request.mode, timezone: request.timezone, reportDay, workDay,
  reportKey: 'OPS-' + reportDay.replaceAll('-', ''), aiModel: request.model,
}}];
""")
live = branch('Collect Live Data?', "={{ $json.mode === 'live' }}")
demo = code('Build Synthetic Report', """
const cfg = $('App Report Configuration').first().json;
const sections = FIXTURE;
const generatedAt = new Date().toISOString();
for (const section of sections) {
  section.data_mode = 'synthetic';
  section.workflow = {id: $workflow.id, execution_id: $execution.id};
}
return [{json: {report: {
  contract_version: '1.0', sync_run_id: cfg.id, report_key: 'DEMO-' + cfg.reportKey,
  business_date: cfg.reportDay, timezone: cfg.timezone, data_mode: 'synthetic',
  status: 'complete', generated_at: generatedAt, sections,
}}}];
""".replace('FIXTURE', json.dumps(demo_sections, ensure_ascii=False)), row=1)
fub_status = progress('fub')
mail = existing_node('FUB + Harry Email Evidence (04)')
fallback_needed = branch('FUB Fallback Needed?', '={{ !!$json.error || !Array.isArray($json.rows) || !Array.isArray($json.emailEvidenceReview) }}')
fub = existing_node('FUB Deals Fallback (05)')
email_status = progress('email', "Array.isArray($('FUB + Harry Email Evidence (04)').first().json.emailEvidenceReview) ? 'ok' : 'failed'")
door_status = progress('doorloop')
existing['DoorLoop Snapshot (APP copy of 03)']['parameters']['workflowId']['value'] = deployment.doorloop_workflow_id
door = existing_node('DoorLoop Snapshot (APP copy of 03)')
time_status = progress('time_doctor')
existing['Time Doctor (07)']['parameters']['workflowId']['value'] = deployment.time_doctor_workflow_id
time = existing_node('Time Doctor (07)')
# Read-only child outputs must carry their expected shape. Vendor errors can
# contain request details, so expose a fixed error in the app.
script = existing['Build App Report v1.0']['parameters']['jsCode']
start = script.index('  const j = items[0];')
end = script.index('  return j;', start)
script = script[:start] + """  const j = items[0];
  const valid = {
    'FUB + Harry Email Evidence (04)': () => Array.isArray(j.rows) && Array.isArray(j.emailEvidenceReview),
    'FUB Deals Fallback (05)': () => Array.isArray(j.rows),
    'DoorLoop Snapshot (APP copy of 03)': () => Array.isArray(j.balanceRows) && Array.isArray(j.appTaskRows),
    'Time Doctor (07)': () => Array.isArray(j.rows) && j.validation?.apiUserTeamTotalsReconcile === true,
  };
  if (j.error || !valid[nodeName]?.()) {
    return {error: 'Source did not return a validated result. Check its connection or latest n8n execution.'};
  }
""" + script[end:]
script = script.replace("time_doctor: 's7sjE_OYgY1Luiz14VcSb'", "time_doctor: " + json.dumps(deployment.time_doctor_workflow_id))
existing['Build App Report v1.0']['parameters']['jsCode'] = script
normalise = existing_node('Build App Report v1.0')
summary_status = progress('summary')
# Progress RPC emits an empty response. Read the saved normalizer result explicitly.
ai = existing['OpenAI - Guarded Summary']
ai['parameters']['jsonBody'] = "={{ JSON.stringify($('Build App Report v1.0').first().json.aiRequest) }}"
summarize = existing_node('OpenAI - Guarded Summary')
attach = existing_node('Attach Guarded AI Summary')
prepare = code('Attach Queued Request', """
const report = $input.first().json.report;
report.sync_run_id = $('App Report Configuration').first().json.id;
return [{json: {report}}];
""")
store = rpc('Store App Report', 'n8n_finish_app_report',
            '={{ JSON.stringify({ p_report: $json.report }) }}', full_response=True)
code_receipt = code('Verify Stored Report', """
const response = $input.first().json;
const value = response.data ?? response.body;
const text = typeof value === 'string' ? value.trim() : '';
const id = text.startsWith('"') && text.endsWith('"') ? text.slice(1, -1) : text;
if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id)) {
  throw Error('No valid report ID returned');
}
return [{json: {report_id: id}}];
""")
chain(manual, claim)
chain(schedule, claim, claimed, config, live)
chain(live, fub_status, mail, fallback_needed, fub, email_status, door_status, door, time_status,
      time, normalise, summary_status, summarize, attach, prepare, store, code_receipt)
connect(fallback_needed, email_status, 1)
connect(live, demo, 1)
connect(demo, store)
if deployment.edge_anon_jwt:
    should_notify = branch('Notify for Live Reports Only',
                           "={{ $('App Report Configuration').first().json.mode === 'live' }}")
    notify = rpc('Send Device Alerts', 'report-push',
                 '={{ JSON.stringify({ report_id: $json.report_id }) }}', functions_api=True)
    chain(code_receipt, should_notify, notify)

add('Setup', 'stickyNote', 1, {
    'content': '## Mobile report queue\nConnect app report RPCs and select the server-only Header Auth credential '
               'on the Supabase nodes. Set the DoorLoop child workflow ID. Use Poll Once with a queued request '
               'before publishing. Publishing starts the queue poll. Daily collection is controlled in Supabase.',
    'width': 590, 'height': 190,
}, row=-2, x=225)
(HERE / (workflow['name'] + '.json')).write_text(json.dumps(workflow, indent=2, ensure_ascii=False) + '\n')
