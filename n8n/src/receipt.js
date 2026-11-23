// n8n Code node "Ingest Receipt": fails the execution loudly if Supabase refused the report.
const r = $input.first().json;
const report = $('Attach Guarded AI Summary').first().json.report;
if (r.error) throw new Error('Supabase refused the report: ' + JSON.stringify(r.error).slice(0, 500));
const id = typeof r === 'string' ? r : r.data ?? r.id ?? r;
return [{ json: { stored: true, reportId: id, reportKey: report.report_key, status: report.status,
  sections: report.sections.map((s) => s.source + ':' + s.status) } }];
