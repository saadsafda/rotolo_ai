"""Build the read-only Time Doctor snapshot used by Rotolo."""

import argparse
from copy import deepcopy
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('export', type=Path)
args = parser.parse_args()
original = json.loads(args.export.read_text())
usage_names = {'Time Doctor - Build Web App Requests', 'Time Doctor MCP - Web App Usage', 'Time Doctor - Attach Web App Usage'}
workflow = {key: original[key] for key in ('nodes', 'connections', 'settings')}
workflow['nodes'] = [node for node in workflow['nodes'] if node['name'] not in usage_names]
for name in usage_names:
    workflow['connections'].pop(name, None)
workflow['name'] = 'RE - APP - Time Doctor Snapshot - Read Only'
workflow['active'] = False
workflow['settings'].update({
    'saveDataErrorExecution': 'none',
    'saveDataSuccessExecution': 'none',
    'saveManualExecutions': False,
})
root = Path(__file__).resolve().parent
nodes = {node['name']: node for node in workflow['nodes']}
nodes['Time Doctor - Report Parameters']['parameters']['jsCode'] = (
    "return [{json:{reportDate:$now.setZone('America/New_York').minus({days:1}).toISODate(),"
    "timezone:'America/New_York'}}];"
)
nodes['Time Doctor - Build Daily Requests']['parameters']['jsCode'] = (root / 'src' / 'time_doctor_scope.js').read_text()
nodes['Time Doctor - Validated Daily Report']['parameters']['jsCode'] = (root / 'src' / 'time_doctor_report.js').read_text()
def code(name, node_id, path, x, y):
    return {'name': name, 'id': node_id, 'type': 'n8n-nodes-base.code', 'typeVersion': 2,
            'position': [x, y], 'parameters': {'jsCode': (root / 'src' / path).read_text()}}

planned = nodes['Time Doctor MCP - Planned Shifts']
validated = nodes['Time Doctor - Validated Daily Report']
x, y = validated['position']
requests = code('Time Doctor - Build Web App Requests', '7e0302e4-8c51-4a5f-a8fa-d42b38e929ab',
                'time_doctor_web_requests.js', x+240, y)
usage = deepcopy(planned)
usage.update(name='Time Doctor MCP - Web App Usage', id='0774e546-63b9-45b2-8a30-2d0d3894b2e4',
             position=[x+480, y], onError='continueRegularOutput')
usage['parameters']['jsonBody'] = "={{ JSON.stringify($json.request ?? {jsonrpc:'2.0',id:0,method:'tools/list'}) }}"
usage['parameters']['options']['timeout'] = 10000
attach = code('Time Doctor - Attach Web App Usage', '238bf21a-f298-4d45-a397-5d09deacacd5',
              'time_doctor_web_report.js', x+720, y)
for before, after in zip([validated, requests, usage], [requests, usage, attach]):
    workflow['connections'][before['name']] = {'main': [[{'node': after['name'], 'type': 'main', 'index': 0}]]}
workflow['nodes'].extend([requests, usage, attach])

for node in workflow['nodes']:
    if node['type'].endswith('.stickyNote'):
        node['parameters']['content'] = (
            '## Mobile Time Doctor snapshot\n'
            'Read-only report for Mary Dalipe and active Time Doctor employees with a Regular User or Manager role. '
            'The directory is checked on every run. Company, pagination, and totals checks still apply.'
        )
output = root / (workflow['name'] + '.json')
output.write_text(json.dumps(workflow, indent=2, ensure_ascii=False) + '\n')
