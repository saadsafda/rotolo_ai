"""Build a read-only Time Doctor snapshot that reports gaps in the approved scope."""

import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('export', type=Path)
args = parser.parse_args()
original = json.loads(args.export.read_text())
workflow = {key: original[key] for key in ('nodes', 'connections', 'settings')}
workflow['name'] = 'RE - APP - Time Doctor Snapshot - Read Only'
workflow['active'] = False
workflow['settings'].update({
    'saveDataErrorExecution': 'none',
    'saveDataSuccessExecution': 'none',
    'saveManualExecutions': False,
})
nodes = {node['name']: node for node in workflow['nodes']}
request = nodes['Time Doctor - Build Daily Requests']['parameters']
scope_start = request['jsCode'].index('const chosen=')
scope_end = request['jsCode'].index('const ids=', scope_start)
request['jsCode'] = request['jsCode'][:scope_start] + """const intended = [
  {id: cfg.targetUserIds[0], name: 'Lhaura Somera'},
  {id: cfg.targetUserIds[1], name: 'Mary Dalipe'},
];
const chosen = intended.flatMap(target => users.data.filter(user =>
  user.id === target.id && user.name === target.name &&
  user.archived !== true && user.isArchived !== true &&
  user.active !== false && user.isActive !== false &&
  !['archived', 'inactive', 'deleted'].includes(String(user.status || '').toLowerCase())
));
if (!chosen.length || new Set(chosen.map(user => user.id)).size !== chosen.length) {
  throw Error('No validated active Time Doctor users remain in the configured scope.');
}
const missing = intended.filter(target => !chosen.some(user => user.id === target.id));
""" + request['jsCode'][scope_end:]
request['jsCode'] = request['jsCode'].replace('userIds:chosen.map(u=>u.id)', 'userIds:chosen.map(u=>u.id), intended, missing')
final = nodes['Time Doctor - Validated Daily Report']['parameters']
final['jsCode'] = (Path(__file__).resolve().parent / 'src' / 'time_doctor_report.js').read_text()
for node in workflow['nodes']:
    if node['type'].endswith('.stickyNote'):
        node['parameters']['content'] = (
            '## Mobile Time Doctor snapshot\n'
            'Read-only report for the two previously configured staff identities. If a user is missing, '
            'collect metrics only for the remaining validated scope and record the coverage gap. '
            'Directory, company, pagination and amount checks still apply.'
        )
output = Path(__file__).resolve().parent / (workflow['name'] + '.json')
output.write_text(json.dumps(workflow, indent=2, ensure_ascii=False) + '\n')
