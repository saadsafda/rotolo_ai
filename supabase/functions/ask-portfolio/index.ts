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
import { languageCode, languageHint, type Reply, renderReplies, say } from "./reply.ts";
import { ambiguousDate, datesIn, localizedDate, mentionsDate, requestedWindow } from "./time_window.ts";

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });

const SYSTEM = `Choose read-only tools for the final user message, which may be in any language. FUB means Follow Up Boss. Cancellation leads are deals marked cancelled.
Earlier questions and lookup criteria are context only. Use them to resolve a follow-up, including a short reply to a clarification or a different-language follow-up. A clearly new topic, person, property or period takes priority. In a mixed request, only look up what the user actually asks for.
Include reply_language when the latest question is in a language other than English or requests a specific language. For a language-neutral reply like a person's name, keep the preceding question's language. When a needed detail or reference is genuinely ambiguous, call clarify_request with one short question in that language. Do not guess a person, result or date.
For Time Doctor, resolve dates in the supplied business timezone using its current date. An exact day uses date only. A contiguous period uses date and through, inclusive. Do not substitute the latest report for a date or range. If a date format is ambiguous or the user asks for a comparison that cannot be represented as one period, ask what dates to check. Do not add a date for an ordinary latest-hours question or change a previously selected date without a reason.`;

const clarifyTool = {
  name: "clarify_request", description: "Ask a focused question when a required reference, date or intent is unclear. Do not select a data tool for the unresolved lookup.",
  parameters: { type: "object", properties: {
    question: { type: "string", description: "One short question in the user's language, without any claimed facts or numbers" },
  }, required: ["question"], additionalProperties: false },
};
const replyLanguage = { type: "string", description: "ISO language code for the answer when requested or non-English, such as es, fr, ur, ar, de, hi, pt or zh" };

const HELP = "I can help with rent, leases, deals, maintenance, team hours, outside payments, and report freshness.";

function describeResult(result: ToolResult): Reply {
  if (result.reply) return result.reply;
  const data = result.data as { available?: boolean; matches?: number; drafted?: boolean };
  if (data?.matches != null && data.matches > 1) return say`Several leases match. Choose a lease below or enter its exact reference.`;
  if (data?.available === false) return say`That information is unavailable in the latest report.`;
  if (data?.matches === 0) return say`No matching record was found in the latest report.`;
  if (data?.drafted === false) return say`A reminder could not be drafted. Check the lease and its latest balance.`;
  if (result.blocks[0]?.type === "draft") return say`Your reminder draft is ready to review.`;
  if (result.blocks[0]?.type === "list") return say`Here is the latest information from your report.`;
  return say`The latest report has no details for this lookup.`;
}

type Lookup = { name: string; args: Record<string, string> };
type Msg = { role: "user" | "assistant"; text: string; lookups: Lookup[] };

const toolsByName = new Map(TOOL_SPECS.map(tool => [tool.name, tool]));
const toolGroups = [
  ["list_deals", "get_deal"],
  ["get_overdue_rent", "get_lease", "draft_rent_reminder", "list_tasks"],
  ["get_team_hours"],
  ["get_email_evidence", "get_deal"],
  ["list_outside_payments"],
  ["get_report_status"],
];

function namedSources(text: string): string[] {
  const categories = [
    fub,
    /\bdoor\s?loop\b/i,
    /\btime\s?doctor\b/i,
    /\b(?:gmail|attorney emails?|attorney repl(?:y|ies))\b/i,
    /\boutside payments?\b/i,
  ];
  const explicit = categories.flatMap((pattern, i) => pattern.test(text) ? toolGroups[i] : []);
  if (explicit.length) return explicit;
  return [
    ...(/\b(?:deals?|closing(?:s)?|cancelled leads?|canceled leads?|cancellation leads?)\b/i.test(text) ? toolGroups[0] : []),
    ...(/\b(?:rent|leases?|maintenance)\b/i.test(text) ? toolGroups[1] : []),
    ...(/\b(?:team hours|tracked hours|track(?:ed)? (?:time|hours))\b/i.test(text) ? toolGroups[2] : []),
  ];
}

function lookup(name: unknown, args: unknown): Lookup | null {
  if (typeof name !== "string" || !args || typeof args !== "object" || Array.isArray(args)) return null;
  const spec = toolsByName.get(name);
  if (!spec) return null;
  const properties = spec.parameters.properties as Record<string, { enum?: string[] }>;
  return { name, args: Object.fromEntries(Object.entries(args).filter(([key, value]) =>
    Object.hasOwn(properties, key) && typeof value === "string" && value.trim().length > 0 &&
    value.length <= 240 && (!properties[key].enum || properties[key].enum.includes(value))
  )) };
}

const fub = /\b(?:fub|follow[ -]?up boss)\b/i;
const cancellation = /\b(?:canceled|cancelled|cancell?ation|cancelad[oa]|annul[ée]e?|storniert[en]?)s?\b/i;
const allCancelled = /^(?:(?:please\s+)?(?:(?:give|show|list|get|find)(?:\s+me)?|(?:what|which) are)\s+)?(?:(?:all|the|my)\s+)*(?:(?:fub|follow[ -]?up boss)\s+)?(?:canceled|cancelled|cancell?ations?)(?:\s+(?:leads?|deals?))?(?:\s+(?:from|in|on)\s+(?:fub|follow[ -]?up boss))?(?:\s+please)?[.!?]*$/i;
const followUp = /^(?:(?:and\s+)?(?:what|how) about\b|(?:and|same|only|just)\b)|\b(?:those|these|that deal|that property|that lease|that team|them|him|her)\b/i;
const countOnly = /^(?:(?:solo|solamente) (?:el )?total|just (?:the )?(?:count|total)|(?:le total seulement|seulement le total))(?:[, ]+(?:please|por favor|s’il vous pla[iî]t))?[.!?]*$/i;
const countLookups = new Set(["list_deals", "list_tasks", "list_outside_payments", "get_overdue_rent", "get_team_hours"]);
const restateCount = /^(?:and\s+)?how many (?:of )?(?:those|these|them)(?: are there)?[?!.]*$/i;

function fallback(question: string): { chosen: Lookup[]; answer?: string } {
  const text = question.trim().toLowerCase().replace(/(?:[?!.] |^)(?:answer|reply|respond) in [a-z]+[!.: ]*$/, "").replace(/[?!.]+$/, "");
  const lookup = (name: string, args: Record<string, string> = {}) => ({ chosen: [{ name, args }] });
  if (/^(hi|hello|hey|good morning|good afternoon)$/.test(text)) {
    return { chosen: [], answer: "Hi! Try asking who is behind on rent, which deals are closing soon, or whether Gmail and Time Doctor are up to date." };
  }
  if (/\b(remind|reminder|payment history|lease details)\b/.test(text)) {
    return { chosen: [], answer: "Which tenant, property and unit, or lease reference should I use?" };
  }
  if (/^(?:show (?:me )?)?(?:gmail|email evidence|attorney emails?|gmail status)$/.test(text)) return lookup("get_email_evidence");
  if (/^(?:show (?:me )?)?(?:time doctor|timedoctor|time doctor status|team hours|tracked hours)$/.test(text)) return lookup("get_team_hours");
  if (/^(?:show (?:me )?)?door\s?loop(?: overview)?$/.test(text)) {
    return { chosen: [{ name: "get_overdue_rent", args: {} }, { name: "list_tasks", args: { filter: "overdue" } }] };
  }
  if (/^(?:who is behind on rent|who owes rent|how much rent is overdue|show overdue rent)$/.test(text)) return lookup("get_overdue_rent");
  if (/^(?:how many |show (?:me )?|count )?(?:(?:overdue maintenance tasks?|maintenance tasks? (?:are )?overdue)(?: (?:are )?(?:in|on|from) doorloop)?|doorloop overdue maintenance)$/.test(text)) {
    return lookup("list_tasks", { filter: "overdue" });
  }
  if (/^(?:(?:show )?(?:open deals|deals closing soon|closing soon|overdue maintenance|outside payments|report status)|which deals close in the next two weeks)$/.test(text)) {
    if (text.includes("maintenance")) return lookup("list_tasks", { filter: "overdue" });
    if (text.includes("payments")) return lookup("list_outside_payments");
    if (text.includes("report")) return lookup("get_report_status");
    return lookup("list_deals", { filter: /soon|two weeks/.test(text) ? "closing_soon" : "open" });
  }
  if (/\b(gmail|email|attorney)\b/.test(text)) {
    return { chosen: [], answer: "Do you want the latest Gmail coverage, or attorney correspondence for a particular property?" };
  }
  if (/\b(time doctor|hours|tracked|activity)\b/.test(text)) {
    return { chosen: [], answer: "Do you want team hours or a particular staff member’s hours from the latest Time Doctor report?" };
  }
  return { chosen: [], answer: /^(?:help|what can you do|what can i ask)$/.test(text)
    ? HELP : "What would you like me to look up? You can mention the report, person, or property." };
}

async function rest(http: typeof fetch, url: string, path: string, apikey: string, auth: string) {
  const r = await http(url + "/rest/v1/" + path, { headers: { apikey, authorization: auth }, signal: AbortSignal.timeout(15_000) });
  if (!r.ok) return null; // missing access is treated as "not available", never as an error the model sees
  return await r.json();
}

async function loadContext(http: typeof fetch, url: string, apikey: string, auth: string): Promise<Ctx> {
  const [reports, payments, tasks, evidence, config] = await Promise.all([
    rest(http, url, "reports?select=id,business_date,generated_at,data_mode,status,report_sections(source,status,collected_at,cutoff,coverage,warnings,payload)&data_mode=eq.live&order=generated_at.desc&limit=1", apikey, auth),
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

async function loadTimeHistory(http: typeof fetch, url: string, apikey: string, auth: string, lookups: Lookup[], ctx: Ctx) {
  const windows = lookups.filter(item => item.name === "get_team_hours" && item.args.date);
  const dates = new Set(windows.flatMap(item => datesIn({ date: item.args.date, through: item.args.through })));
  if (!dates.size) return;
  const period = [...dates].sort();
  const params = new URLSearchParams({
    select: "id,report_sections!inner(source,status,collected_at,cutoff,coverage,warnings,payload)",
    data_mode: "eq.live",
    "report_sections.data_mode": "eq.live",
    "report_sections.source": "eq.time_doctor",
    "report_sections.status": "neq.unavailable",
    "report_sections.payload->>work_date": `in.(${period.join(",")})`,
    order: "generated_at.desc",
    limit: "250",
  });
  const reports = await rest(http, url, "reports?" + params, apikey, auth);
  if (!Array.isArray(reports)) return;
  ctx.timeHistory = {};
  for (const report of reports) {
    for (const section of report.report_sections ?? []) {
      const date = section.payload?.work_date;
      if (section.source === "time_doctor" && section.status !== "unavailable" && dates.has(date) &&
        !Object.hasOwn(ctx.timeHistory, date)) {
        ctx.timeHistory[date] = { section, reportId: report.id };
      }
    }
  }
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
      .map((m: any) => ({
        role: m.role, text: String(m.text).slice(0, 2000),
        lookups: m.role === "assistant" && Array.isArray(m.context_tools)
          ? m.context_tools.slice(0, 4).map((item: any) => lookup(item?.name, item?.args)).filter(Boolean)
          : [],
      }));
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  if (!messages.length || messages[messages.length - 1].role !== "user") return json({ error: "bad_request" }, 400);

  const ctx = await loadContext(http, url, apikey, auth);
  const text = messages[messages.length - 1].text.trim();
  let language = languageHint(text);
  let chosen: Lookup[] = [];
  let reply: Reply | undefined;
  let clarification: string | undefined;
  const latest = messages.slice(0, -1);
  const explicitSource = namedSources(text);
  const wantsCount = restateCount.test(text) || countOnly.test(text);
  const isFollowUp = followUp.test(text) || wantsCount;
  const previous = latest.findLast(message => message.role === "assistant")?.lookups ?? [];
  const relevantLookups = explicitSource.length ? previous.filter(item => explicitSource.includes(item.name)) : previous;
  const relatedTools = toolGroups.filter(group => relevantLookups.some(item => group.includes(item.name))).flat();
  const specs = TOOL_SPECS.filter(tool => explicitSource.length
    ? explicitSource.includes(tool.name)
    : !isFollowUp || !relatedTools.length || relatedTools.includes(tool.name));
  const earlierMessages = !explicitSource.length || isFollowUp ? latest.slice(-8) : [];
  const priorQuestions = earlierMessages.filter(message => message.role === "user" &&
      (!explicitSource.length || namedSources(message.text).some(name => explicitSource.includes(name))))
    .map(message => message.text);
  const historyLookups = earlierMessages.length ? relevantLookups : [];
  const unclearPerson = /^(?:and\s+)?(?:what|how) about (?:him|her|them)[?!.]*$/i.test(text);
  const previousPerson = relevantLookups.length === 1 && relevantLookups[0].name === "get_team_hours" &&
    relevantLookups[0].args.user ? relevantLookups[0] : null;
  const date = requestedWindow(text, ctx.today);
  const timeContext = explicitSource.includes("get_team_hours") ||
    (!explicitSource.length && relevantLookups.some(item => item.name === "get_team_hours"));
  const dateMention = date != null || mentionsDate.test(text) || localizedDate.test(text);
  const hasDateRequest = timeContext && dateMention;

  if (timeContext && ambiguousDate(text)) {
    reply = say`Which date did you mean? Please spell out the month or use year-month-day.`;
  } else if (allCancelled.test(text)) {
    chosen = [{ name: "list_deals", args: { filter: "cancelled" } }];
  } else if (unclearPerson) {
    if (previousPerson) chosen = [previousPerson];
    else reply = say`Who do you mean? Please give me their name.`;
  } else if (wantsCount && relevantLookups.length === 1 && countLookups.has(relevantLookups[0].name)) {
    chosen = relevantLookups;
  } else if (wantsCount && (!priorQuestions.length || relevantLookups.length > 1)) {
    reply = say`Which records would you like me to count?`;
  } else try {
    const response = await http("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { authorization: "Bearer " + openaiKey, "content-type": "application/json" },
      body: JSON.stringify({
        model, reasoning_effort: "low", max_completion_tokens: 1600,
        messages: [
          { role: "system", content: SYSTEM + ` Business date: ${ctx.today}. Business timezone: ${ctx.timezone}.` },
          ...(priorQuestions.length || historyLookups.length ? [{
            role: "user", content: JSON.stringify({ context_only: { prior_questions: priorQuestions, prior_lookup_criteria: historyLookups } }),
          }] : []),
          { role: "user", content: text },
        ],
        tools: [...specs, clarifyTool].map((tool) => ({
          type: "function",
          function: { ...tool, parameters: {
            ...tool.parameters,
            properties: { ...tool.parameters.properties, reply_language: replyLanguage },
          } },
        })), tool_choice: "auto",
      }),
      signal: AbortSignal.timeout(30_000),
    });
    const calls = response.ok ? (await response.json()).choices?.[0]?.message?.tool_calls ?? [] : [];
    const names = new Set(specs.map((tool) => tool.name));
    for (const call of calls.slice(0, 8)) {
      try {
        const name = call.function?.name;
        const args = JSON.parse(call.function.arguments || "{}");
        if (name === clarifyTool.name || names.has(name)) language ??= languageCode(args.reply_language);
        if (name === clarifyTool.name && typeof args.question === "string" && args.question.trim().length <= 350) {
          clarification = args.question.trim();
        }
        if (!names.has(name) || chosen.length >= 4) continue;
        const parsed = lookup(name, args);
        if (!parsed) continue;
        if (name === "list_deals" && fub.test(text) && cancellation.test(text)) {
          parsed.args.filter = "cancelled";
        }
        chosen.push(parsed);
      } catch {
        // Malformed calls do not affect the other selections.
      }
    }
  } catch {
    // The common report lookups can still respond if the model is unavailable.
  }
  if (!chosen.length && !reply && !clarification) {
    if (hasDateRequest && date && /\bteam (?:hours|work|track|log)|\bhours did the team\b/i.test(text)) {
      chosen = [{ name: "get_team_hours", args: { ...date } }];
    } else if (hasDateRequest) {
      reply = say`Which work date should I check in Time Doctor? You can give one date or a date range.`;
    } else {
      const safe = fallback(text);
      chosen = safe.chosen;
      if (safe.answer) reply = { template: safe.answer, slots: [] };
    }
  }
  const priorTime = historyLookups.find(item => item.name === "get_team_hours" && item.args.date);
  chosen = chosen.filter(item => {
    if (item.name !== "get_team_hours") return true;
    if (date) {
      item.args.date = date.date;
      if (date.through) item.args.through = date.through;
      else delete item.args.through;
    } else if (!item.args.date && priorTime && isFollowUp && !hasDateRequest && !/\b(latest|current|most recent)\b/i.test(text)) {
      item.args.date = priorTime.args.date;
      if (priorTime.args.through) item.args.through = priorTime.args.through;
    }
    if ((dateMention || item.args.through) && !item.args.date) {
      reply = say`Which work date should I check in Time Doctor? You can give one date or a date range.`;
      return false;
    }
    return true;
  });

  await loadTimeHistory(http, url, apikey, auth, chosen, ctx);
  const results = chosen.map(item => runTool(item.name, item.args, ctx));
  const replies = [...new Map(results.map(result => {
    const message = describeResult(result);
    return [JSON.stringify(message), message];
  })).values()];
  if (reply) replies.push(reply);
  if (!replies.length && !clarification) {
    replies.push(ctx.report ? say`What would you like me to look up?` : say`There is no report stored yet. Generate a report first, then ask again.`);
  }
  const answer = await renderReplies(replies, language, http, openaiKey, model);
  const seen = new Set<string>();
  return json({
    answer: [answer, clarification].filter(Boolean).join(" "),
    blocks: countOnly.test(text) ? [] : results.flatMap((r) => r.blocks).slice(0, 8),
    sources: results.flatMap((r) => r.sources).filter((source) => !seen.has(source.title) && seen.add(source.title)).slice(0, 6),
    suggestions: [...new Set(results.flatMap((r) => r.suggestions))].slice(0, 3),
    context_tools: chosen,
    data_mode: ctx.report?.data_mode ?? null,
    as_of: ctx.report?.generated_at ?? null,
  });
}

if (import.meta.main) Deno.serve((req) => handle(req));
