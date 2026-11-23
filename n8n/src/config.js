// n8n Code node "App Report Configuration".
const now = $now.setZone('America/New_York');
return [{ json: {
  timezone: 'America/New_York',
  reportDay: now.toISODate(),                    // snapshot day (business date of the report)
  workDay: now.minus({ days: 1 }).toISODate(),   // previous day for Time Doctor
  reportKey: 'OPS-' + now.toFormat('yyyyLLdd'),
  aiModel: 'gpt-5-nano',                         // decision D9; mirrors app_config.ai_summary_model
  // Public values (not secrets). The ingest secret lives in the n8n credential.
  supabaseUrl: 'https://pdobiwupwvbegzjlmnox.supabase.co',
  supabasePublishableKey: 'sb_publishable_x7LCRjKE9d2m-UqVp-fJAQ_jOjLnbic',
} }];
