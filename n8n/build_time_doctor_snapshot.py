"""Build the read-only Time Doctor snapshot used by Rotolo."""

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
root = Path(__file__).resolve().parent
nodes = {node['name']: node for node in workflow['nodes']}
nodes['Time Doctor - Report Parameters']['parameters']['jsCode'] = (
    "return [{json:{reportDate:$now.setZone('America/New_York').minus({days:1}).toISODate(),"
    "timezone:'America/New_York'}}];"
)
nodes['Time Doctor - Build Daily Requests']['parameters']['jsCode'] = (root / 'src' / 'time_doctor_scope.js').read_text()
nodes['Time Doctor - Validated Daily Report']['parameters']['jsCode'] = (root / 'src' / 'time_doctor_report.js').read_text()
for node in workflow['nodes']:
    if node['type'].endswith('.stickyNote'):
        node['parameters']['content'] = (
            '## Mobile Time Doctor snapshot\n'
            'Read-only report for Mary Dalipe and active Time Doctor employees with a Regular User or Manager role. '
            'The directory is checked on every run. Company, pagination, and totals checks still apply.'
        )
output = root / (workflow['name'] + '.json')
output.write_text(json.dumps(workflow, indent=2, ensure_ascii=False) + '\n')
