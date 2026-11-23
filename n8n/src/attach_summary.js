// Use the model's topic order, with exact report-derived sentences for the text.
const built = $('Build App Report v1.0').first().json;
const res = $input.first().json;
const report = JSON.parse(JSON.stringify(built.report));
const findings = built.findings;
const expected = new Set(findings.map(item => item.id));
const answer = res?.choices?.[0]?.message?.content;
let order;
try { order = JSON.parse(answer); } catch { order = null; }
const valid = !res?.error && Array.isArray(order) && order.length === expected.size &&
  new Set(order).size === expected.size && order.every(id => expected.has(id));
const position = new Map((valid ? order : findings.map(item => item.id)).map((id, index) => [id, index]));
const text = [...findings].sort((a, b) => a.priority - b.priority || position.get(a.id) - position.get(b.id))
  .map(item => item.text).join(' ');
const hasResults = report.sections.some(section => section.status !== 'unavailable');
report.sections.unshift({
  source: 'ai_summary', status: hasResults ? 'complete' : 'unavailable', data_mode: 'live',
  collected_at: hasResults ? new Date().toISOString() : null,
  cutoff: { kind: 'snapshot', as_of: report.generated_at },
  coverage: { composition: valid ? 'ai_ordered' : 'report_order' }, warnings: [],
  workflow: { id: 'OpenAI', execution_id: $execution.id ? String($execution.id) : null },
  payload: { text: hasResults ? text : null, model: built.aiRequest.model, guard: 'verified_findings', status: hasResults ? 'ok' : 'unavailable' },
});
report.status = !hasResults ? 'failed' : report.sections.every(section => section.status === 'complete') ? 'complete' : 'partial';
return [{ json: { report } }];
