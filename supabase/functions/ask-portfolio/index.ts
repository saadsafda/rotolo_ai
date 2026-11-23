// deno-lint-ignore-file no-explicit-any
// "Ask your portfolio" — grounded chat over the user's own Rotolo data.
//
// POST /functions/v1/ask-portfolio   (the app calls it with the signed-in user's JWT)
// body: { messages: [{ role: "user" | "assistant", text: string }] }
//
// Data is read with the caller's JWT, so row-level security applies exactly as in
// the app (staff only see what their role allows). Tools in tools.ts compute every
// figure. The model selects tools from the user’s questions before any tool returns data. Secrets
// (OPENAI_API_KEY) live in Supabase function secrets, never in the app.
import { type Ctx, runTool, TOOL_SPECS, type ToolResult } from "./tools.ts";

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });

const SYSTEM = `Choose the read-only tools that answer the user's portfolio question. Use the wording of the user messages to supply tool arguments. If an entity is unclear, ask for a property, unit, or lease reference. If the question is outside rent, leases, deals, maintenance, team hours, payment requests, or report freshness, choose no tool. Records are processed by the app after your choice.`;

const HELP = "I can help with rent, leases, deals, maintenance, team hours, outside payments, and report freshness.";

function describeResult(result: ToolResult): string {
  const data = result.data as { available?: boolean; matches?: number; drafted?: boolean; reason?: string };
  if (data?.matches != null && data.matches > 1) return "Several leases match. Choose a lease below or enter its exact reference.";
  if (data?.available === false) return data.reason ?? "That information is unavailable in the latest report.";
  if (data?.matches === 0) return "No matching record was found in the latest report.";
  if (data?.drafted === false) return "A reminder could not be drafted. Check the lease and its latest balance.";
  const first = result.blocks[0];
  if (first?.type === "metric") return `${first.label} — ${first.value}.`;
  if (first?.type === "draft") return "Your reminder draft is ready to review.";
  return first ? "Here are the matching records." : HELP;
}

type Msg = { role: "user" | "assistant"; text: string };

async function rest(http: typeof fetch, url: string, path: string, apikey: string, auth: string) {
  const r = await http(url + "/rest/v1/" + path, { headers: { apikey, authorization: auth }, signal: AbortSignal.timeout(15_000) });
  if (!r.ok) return null; // missing access is treated as "not available", never as an error the model sees
  return await r.json();
}

async function loadContext(http: typeof fetch, url: string, apikey: string, auth: string): Promise<Ctx> {
  const [reports, payments, tasks, evidence, config] = await Promise.all([
    rest(http, url, "reports?select=id,business_date,generated_at,data_mode,status,report_sections(source,status,collected_at,cutoff,warnings,payload)&data_mode=eq.live&order=generated_at.desc&limit=1", apikey, auth),
    rest(http, url, "payment_submissions?select=id,lease_id,amount_minor,payment_date,method,method_detail,status,property_name,unit,tenant_name,created_at&order=created_at.desc&limit=50", apikey, auth),
    rest(http, url, "task_reviews?select=task_id,review_status", apikey, auth),
    rest(http, url, "deal_evidence_reviews?select=deal_id", apikey, auth),
    rest(http, url, "app_config?select=key,value&key=eq.business_timezone", apikey, auth),
  ]);
  const r = Array.isArray(reports) && reports.length ? reports[0] : null;
  const timezone = (Array.isArray(config) && typeof config[0]?.value === "string") ? config[0].value : "America/New_York";
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  return {
    report: r ? { id: r.id, business_date: r.business_date, generated_at: r.generated_at, data_mode: r.data_mode, status: r.status } : null,
    sections: Object.fromEntries((r?.report_sections ?? []).map((s: any) => [s.source, s])),
    payments: Array.isArray(payments) ? payments : [],
    taskReviews: Object.fromEntries((Array.isArray(tasks) ? tasks : []).map((t: any) => [t.task_id, t.review_status])),
    evidenceReviewed: new Set((Array.isArray(evidence) ? evidence : []).map((e: any) => Number(e.deal_id))),
    today, timezone,
  };
}

type Env = { get(name: string): string | undefined };

/// Request handler. `env` and `http` are injectable so the full flow can be tested
/// without network access (index.test.ts).
export async function handle(req: Request, env: Env = Deno.env, http: typeof fetch = fetch): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = env.get("SUPABASE_URL");
  const apikey = env.get("SUPABASE_ANON_KEY") ?? req.headers.get("apikey") ?? "";
  const openaiKey = env.get("OPENAI_API_KEY");
  const model = env.get("ROTOLO_CHAT_MODEL") ?? "gpt-5-mini";
  const auth = req.headers.get("authorization") ?? "";
  if (!url || !apikey) return json({ error: "server_not_configured" }, 503);
  if (!auth.startsWith("Bearer ")) return json({ error: "sign_in_required" }, 401);

  // Signed-in, active app user only.
  const me = await http(url + "/auth/v1/user", { headers: { apikey, authorization: auth }, signal: AbortSignal.timeout(10_000) });
  if (!me.ok) return json({ error: "sign_in_required" }, 401);
  const profile = await rest(http, url, "profiles?select=id,active&active=eq.true&limit=1", apikey, auth);
  if (!Array.isArray(profile) || !profile.length) return json({ error: "no_app_access" }, 403);
  if (!openaiKey) return json({ error: "assistant_not_configured" }, 503);

  let messages: Msg[];
  try {
    const body = await req.json();
    messages = (Array.isArray(body?.messages) ? body.messages : [])
      .filter((m: any) => (m?.role === "user" || m?.role === "assistant") && typeof m?.text === "string" && m.text.trim())
      .slice(-12)
      .map((m: any) => ({ role: m.role, text: String(m.text).slice(0, 2000) }));
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  if (!messages.length || messages[messages.length - 1].role !== "user") return json({ error: "bad_request" }, 400);

  const ctx = await loadContext(http, url, apikey, auth);
  if (!ctx.report) {
    return json({ answer: "There is no report stored yet. Generate a report first, then ask again.", blocks: [], sources: [], suggestions: [], data_mode: null, as_of: null });
  }

  let results: ToolResult[];
  try {
    const response = await http("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { authorization: "Bearer " + openaiKey, "content-type": "application/json" },
      body: JSON.stringify({
        model, reasoning_effort: "low", max_completion_tokens: 1200,
        messages: [
          { role: "system", content: SYSTEM },
          ...messages.filter((m) => m.role === "user").map((m) => ({ role: "user", content: m.text })),
        ],
        tools: TOOL_SPECS.map((t) => ({ type: "function", function: t })), tool_choice: "auto",
      }),
      signal: AbortSignal.timeout(45_000),
    });
    if (!response.ok) return json({ error: "assistant_unavailable" }, 502);
    const calls = (await response.json()).choices?.[0]?.message?.tool_calls ?? [];
    const names = new Set(TOOL_SPECS.map((tool) => tool.name));
    results = calls.slice(0, 4).flatMap((call: any) => {
      if (!names.has(call.function?.name)) return [];
      try {
        const args = JSON.parse(call.function.arguments || "{}");
        return [runTool(call.function.name, args, ctx)];
      } catch {
        return [];
      }
    });
  } catch {
    return json({ error: "assistant_unavailable" }, 502);
  }

  // Render the selected records inside Supabase instead of sending them back to OpenAI.
  const seen = new Set<string>();
  return json({
    answer: results.length ? [...new Set(results.map(describeResult))].join(" ") : HELP,
    blocks: results.flatMap((r) => r.blocks).slice(0, 8),
    sources: results.flatMap((r) => r.sources).filter((source) => !seen.has(source.title) && seen.add(source.title)).slice(0, 6),
    suggestions: [...new Set(results.flatMap((r) => r.suggestions))].slice(0, 3),
    data_mode: ctx.report.data_mode,
    as_of: ctx.report.generated_at,
  });
}

if (import.meta.main) Deno.serve((req) => handle(req));
