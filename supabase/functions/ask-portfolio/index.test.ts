// deno test supabase/functions/ask-portfolio/index.test.ts --allow-read
// Full request flow with Supabase and OpenAI replaced by in-memory responses.
// deno-lint-ignore-file no-explicit-any
import { handle } from "./index.ts";

const fixture = JSON.parse(await Deno.readTextFile(new URL("../../../assets/fixtures/synthetic_reports.json", import.meta.url))).reports[0];
const report = { id: "r1", business_date: fixture.business_date, generated_at: fixture.generated_at, data_mode: "live", status: fixture.status,
  report_sections: fixture.sections };

function assert(cond: unknown, msg: string): asserts cond { if (!cond) throw new Error(msg); }
const env = (extra: Record<string, string> = {}) => ({ get: (k: string) => ({ SUPABASE_URL: "https://db.test", SUPABASE_ANON_KEY: "pk", OPENAI_API_KEY: "sk", ...extra } as any)[k] });
const ask = (text: string, auth = "Bearer user-jwt") =>
  new Request("https://fn.test/ask-portfolio", { method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", text }] }) });

/// Capture the model request and all caller-scoped reads.
function fakeHttp(openaiSteps: any[], seen: { openai: any[]; restAuth: string[] }, opts: { authOk?: boolean; sections?: any[]; history?: any[]; historyQueries?: string[] } = {}) {
  let step = 0;
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const headers = new Headers(init?.headers);
    if (url.endsWith("/auth/v1/user")) return new Response("{}", { status: opts.authOk === false ? 401 : 200 });
    if (url.startsWith("https://db.test/rest/v1/")) {
      seen.restAuth.push(headers.get("authorization") ?? "");
      const path = url.slice("https://db.test/rest/v1/".length);
      if (path.startsWith("profiles")) return Response.json([{ id: "u1", active: true }]);
      if (path.startsWith("reports")) {
        const params = new URL(url).searchParams;
        assert(params.get("data_mode") === "eq.live", "signed-in assistant must only query live reports");
        if (params.get("report_sections.source") === "eq.time_doctor") {
          opts.historyQueries?.push(params.get("report_sections.payload->>work_date") ?? "");
          assert(params.get("report_sections.data_mode") === "eq.live", "only live Time Doctor sections");
          return Response.json(opts.history ?? []);
        }
        return Response.json([{ ...report, report_sections: opts.sections ?? report.report_sections }]);
      }
      return Response.json([]);
    }
    if (url === "https://api.openai.com/v1/chat/completions") {
      seen.openai.push(JSON.parse(String(init?.body)));
      return Response.json({ choices: [{ message: openaiSteps[step++] }] });
    }
    throw new Error("unexpected " + url);
  }) as typeof fetch;
}
const call = (name: string, args: unknown = {}) => ({ role: "assistant", content: null, tool_calls: [{ id: "c1", type: "function", function: { name, arguments: JSON.stringify(args) } }] });

function afterTimeDoctor(text: string) {
  return new Request("https://fn.test/ask-portfolio", {
    method: "POST", headers: { authorization: "Bearer user-jwt", "content-type": "application/json" },
    body: JSON.stringify({ messages: [
      { role: "user", text: "Show team hours" },
      { role: "assistant", text: "Time Doctor recorded 8 hours." },
      { role: "user", text },
    ] }),
  });
}

Deno.test("all cancellation leads from FUB return only cancelled deals, even after Time Doctor", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const section = report.report_sections.find((s: any) => s.source === "fub_deals");
  const cancelled = section.payload.deals.find((d: any) => d.classification === "cancelled");
  const deals = [
    ...section.payload.deals.filter((d: any) => d.classification !== "cancelled"),
    ...Array.from({ length: 17 }, (_, i) => ({ ...cancelled, deal_id: 100 + i, property: "Test cancelled deal " + i })),
  ];
  const sections = report.report_sections.map((s: any) => s === section ? { ...s, payload: { ...s.payload, deals } } : s);
  const response = await handle(afterTimeDoctor("give me all cancellation lead from fub"), env(), fakeHttp([
    call("get_team_hours"),
  ], seen, { sections }));
  const body = await response.json();
  assert(body.answer.includes("17 deals marked cancelled"), "plain-English answer gives the cancellation count");
  assert(body.blocks[0].items.length === 17, "all matches are returned, including those beyond the usual list limit");
  assert(body.blocks[0].items.every((item: any) => item.title.startsWith("Test cancelled deal")), "only cancelled deals");
  assert(body.sources.length === 1 && body.sources[0].kind === "deal", "no Time Doctor data");
  assert(seen.openai.length === 0, "unambiguous cancellation lookup skips model routing");
});

Deno.test("new source excludes prior questions and unrelated model tool calls", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const calls = [...call("get_team_hours").tool_calls, ...call("list_deals", { filter: "open" }).tool_calls];
  const body = await (await handle(
    afterTimeDoctor("Could you check cancellation deals recorded in FUB?"),
    env(), fakeHttp([{ tool_calls: calls }], seen),
  )).json();
  assert(body.answer.includes("deal marked cancelled"), "uses the requested cancellation filter");
  assert(body.sources.length === 1 && body.sources[0].kind === "deal", "ignores Time Doctor tool call");
  assert(seen.openai[0].messages.filter((m: any) => m.role === "user").length === 1, "standalone FUB query has no previous turns");
});

Deno.test("cancelled lookup respects restricted and empty FUB sections", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const fub = report.report_sections.find((s: any) => s.source === "fub_deals");
  const empty = { ...fub, payload: { ...fub.payload, deals: fub.payload.deals.filter((d: any) => d.classification !== "cancelled") } };
  const noAccess = await (await handle(ask("Show canceled deals"), env(), fakeHttp([], seen, { sections: [] }))).json();
  const zero = await (await handle(ask("Show canceled deals"), env(), fakeHttp([], seen, { sections: [empty] }))).json();
  assert(noAccess.answer.includes("not available") && noAccess.blocks.length === 0, "restricted data is not treated as zero");
  assert(zero.answer.includes("no deals marked cancelled") && zero.sources[0].kind === "deal", "zero in a visible report has a clear answer");
});

Deno.test("a vague follow-up asks for a person rather than repeating the team total", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const body = await (await handle(afterTimeDoctor("What about him?"), env(), fakeHttp([call("get_team_hours")], seen))).json();
  assert(body.answer === "Who do you mean? Please give me their name." && body.blocks.length === 0, "clarification without irrelevant hours");
});

Deno.test("saved lookup criteria resolve a follow-up without sending saved answers to the model", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const http = fakeHttp([call("get_team_hours", { user: "Alpha" })], seen);
  const askWithHistory = (messages: unknown[]) => new Request("https://fn.test/ask-portfolio", {
    method: "POST", headers: { authorization: "Bearer user-jwt" }, body: JSON.stringify({ messages }),
  });
  const original = await (await handle(ask("Give me all cancellation leads from FUB"), env(), http)).json();
  const turns = [
    { role: "user", text: "Give me all cancellation leads from FUB" },
    { role: "assistant", text: "Private reply with a property address", context_tools: original.context_tools },
  ];
  const count = await (await handle(askWithHistory([...turns, { role: "user", text: "How many of those?" }]), env(), http)).json();
  assert(count.answer === original.answer && count.sources[0].kind === "deal", "follow-up reuses the saved cancellation lookup");
  const newQuestion = await (await handle(askWithHistory([...turns, { role: "user", text: "And what about Alpha's Time Doctor hours?" }]), env(), http)).json();
  assert(newQuestion.sources[0].kind === "time", "explicit new source takes priority over saved history");
  assert(!JSON.stringify(seen.openai).includes("Private reply"), "old answer content is never sent to OpenAI");
  assert(!JSON.stringify(seen.openai).includes("cancellation leads from FUB"), "irrelevant prior question is omitted");
});

Deno.test("named follow-up carries forward the topic and prefers the new person", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const http = fakeHttp([{ tool_calls: [...call("get_team_hours", { user: "Bravo" }).tool_calls, ...call("list_deals").tool_calls] }], seen);
  const request = new Request("https://fn.test/ask-portfolio", {
    method: "POST", headers: { authorization: "Bearer user-jwt" },
    body: JSON.stringify({ messages: [
      { role: "user", text: "How many hours did Alpha track?" },
      { role: "assistant", text: "Previously displayed private hours", context_tools: [{ name: "get_team_hours", args: { user: "Alpha" } }] },
      { role: "user", text: "And what about Bravo?" },
    ] }),
  });
  const body = await (await handle(request, env(), http)).json();
  assert(body.answer.includes("Bravo") && !body.answer.includes("Alpha"), "new person replaces previous person");
  assert(body.sources.length === 1 && body.sources[0].kind === "time", "the follow-up stays in Time Doctor");
  assert(JSON.stringify(seen.openai).includes("prior_lookup_criteria") && !JSON.stringify(seen.openai).includes("Previously displayed private hours"), "only earlier question and lookup are forwarded");
});

Deno.test("grounded answer: tool cards, sources, user-scoped reads", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const res = await handle(ask("Which tenants are late on rent?"), env(), fakeHttp([
    call("get_overdue_rent"),
    { role: "assistant", content: "Three leases are past due, totalling **$3,125.50**." },
  ], seen));
  assert(res.status === 200, "status " + res.status);
  const body = await res.json();
  assert(body.answer.includes("$3,125.50"), "answer kept");
  assert(body.blocks[0].type === "metric" && body.blocks[0].value === "$3,125.50", "metric from tool");
  assert(body.sources[0].kind === "ledger", "source");
  assert(body.data_mode === "live", "data mode passed through");
  assert(seen.restAuth.every((a) => a === "Bearer user-jwt"), "every read uses the caller's JWT (RLS)");
  assert(seen.openai.length === 1, "the model only selects tools");
  const transmitted = JSON.stringify(seen.openai);
  assert(!transmitted.includes("$3,125.50") && !transmitted.includes("Tenant Bravo"), "retrieved figures and names stay in Supabase");
});

Deno.test("model copy is ignored, exact figures and cards come from the report", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const res = await handle(ask("How much is late?"), env(), fakeHttp([
    call("get_overdue_rent"),
    { role: "assistant", content: "Roughly $3,100 is late." },
  ], seen));
  const body = await res.json();
  assert(body.answer.includes("$3,125.50") && !body.answer.includes("$3,100"), "only verified figures are used");
  assert(body.blocks.length > 0, "cards kept");
});

Deno.test("no session → 401; no OpenAI key → 503 assistant_not_configured", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const r1 = await handle(ask("hi", ""), env(), fakeHttp([], seen));
  assert(r1.status === 401, "missing bearer");
  const r2 = await handle(ask("hi"), env(), fakeHttp([], seen, { authOk: false }));
  assert(r2.status === 401, "bad jwt");
  const r3 = await handle(ask("hi"), env({ OPENAI_API_KEY: "" }), fakeHttp([], seen));
  assert(r3.status === 503 && (await r3.json()).error === "assistant_not_configured", "no key");
  assert(seen.openai.length === 0, "OpenAI never called");
});

Deno.test("staff (deals only): rent tool reports unavailable, no rent cards", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const res = await handle(ask("Who is late on rent?"), env(), fakeHttp([
    call("get_overdue_rent"),
    { role: "assistant", content: "Rent data isn't available for your role." },
  ], seen, { sections: report.report_sections.filter((s: any) => s.source === "fub_deals") }));
  const body = await res.json();
  assert(body.blocks.length === 0, "no rent cards for staff");
  assert(body.answer.includes("not available"), "assistant tells the user the data is unavailable");
});

Deno.test("the latest question gets a distinct result even without a model tool call", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const http = fakeHttp([{ role: "assistant", content: "No tool" }, { role: "assistant", content: "No tool" }], seen);
  const rent = await (await handle(ask("Who is behind on rent?"), env(), http)).json();
  const followUp = new Request("https://fn.test/ask-portfolio", {
    method: "POST",
    headers: { authorization: "Bearer user-jwt" },
    body: JSON.stringify({ messages: [
      { role: "user", text: "Who is behind on rent?" },
      { role: "assistant", text: rent.answer },
      { role: "user", text: "Show open deals" },
    ] }),
  });
  const deals = await (await handle(followUp, env(), http)).json();
  assert(rent.answer.includes("$3,125.50"), "rent figures available without a model tool call");
  assert(deals.answer.includes("Open deals") && !deals.answer.includes("$3,125.50"), "new topic answered independently");
  assert(!JSON.stringify(seen.openai).includes("$3,125.50"), "prior private replies stay in Supabase");
  assert(seen.openai[1].messages.at(-1).content === "Show open deals", "latest question sent last");
});

Deno.test("Gmail coverage and a missing staff member get distinct, scoped answers", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const http = fakeHttp([call("get_email_evidence"), call("get_team_hours", { user: "Charlie" })], seen);
  const gmail = await (await handle(ask("How complete is Gmail?"), env(), http)).json();
  const time = await (await handle(ask("How many hours did Charlie track?"), env(), http)).json();
  assert(gmail.sources[0].kind === "email" && gmail.answer.includes("more results"), "partial Gmail coverage is explicit");
  assert(time.sources[0].kind === "time" && time.answer.includes("didn’t return tracked hours"), "named missing staff does not get the team total");
});

const historyRequest = (messages: unknown[]) => new Request("https://fn.test/ask-portfolio", {
  method: "POST", headers: { authorization: "Bearer user-jwt" }, body: JSON.stringify({ messages }),
});

const translation = (...translations: string[]) => ({ content: JSON.stringify({ translations }) });

Deno.test("Spanish answer and count-only follow-up keep the verified FUB count private", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const first = "La cuenta verificada de Follow Up Boss es {{slot_0}}.";
  const section = report.report_sections.find((s: any) => s.source === "fub_deals");
  const cancelled = section.payload.deals.find((d: any) => d.classification === "cancelled");
  const sections = [{ ...section, payload: { deals: [{ ...cancelled, property: "Private record" }, cancelled] } }];
  const http = fakeHttp([call("list_deals", { filter: "open" }), translation(first), translation("Hay {{slot_0}} negocios cancelados.")], seen, { sections });
  const question = "Total de negocios cancelados en FUB";
  const original = await (await handle(ask(question), env(), http)).json();
  const body = await (await handle(historyRequest([
    { role: "user", text: question },
    { role: "assistant", text: original.answer, context_tools: original.context_tools },
    { role: "user", text: "Solo el total" },
  ]), env(), http)).json();
  assert(original.answer === "La cuenta verificada de Follow Up Boss es 2.", "translated original with numeric value restored");
  assert(body.answer === "Hay 2 negocios cancelados." && !body.blocks.length, "Spanish follow-up carries the cancellation filter and gives just the count");
  const translatedInput = JSON.stringify(seen.openai[1]);
  assert(!translatedInput.includes("Private record") && !translatedInput.includes("2 deals"), "translation receives templates without report values");
});

Deno.test("a fresh chat asks what to count in the language requested", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const body = await (await handle(ask("Solo el total"), env(), fakeHttp([
    translation("¿Qué registros quieres que cuente?"),
  ], seen))).json();
  assert(body.answer === "¿Qué registros quieres que cuente?" && body.context_tools.length === 0, "no inherited topic or generic help");
});

Deno.test("a clarification can be answered with just the missing detail", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const http = fakeHttp([
    call("clarify_request", { question: "Which staff member’s hours would you like to see?" }),
    call("get_team_hours", { user: "Alpha" }),
  ], seen);
  const question = "Can you tell me how long that person worked?";
  const first = await (await handle(ask(question), env(), http)).json();
  const next = await (await handle(historyRequest([
    { role: "user", text: question },
    { role: "assistant", text: first.answer },
    { role: "user", text: "Alpha" },
  ]), env(), http)).json();
  assert(first.answer.startsWith("Which staff member"), "specific clarification");
  assert(next.answer.includes("Alpha") && next.sources[0].kind === "time", "short answer continues the topic");
  assert(JSON.stringify(seen.openai[1]).includes(question), "original question is available to resolve the short answer");
});

Deno.test("an explicit reply language protects computed numbers and does not expose record data", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const http = fakeHttp([call("list_tasks", { filter: "overdue" }),
    translation("مرمت کے {{slot_0}} کام مقررہ وقت سے گزر چکے ہیں۔")], seen);
  const body = await (await handle(ask("How many DoorLoop maintenance tasks are overdue? Answer in Urdu."), env(), http)).json();
  assert(body.answer.includes("مرمت کے 2 کام"), "translated in Urdu");
  assert(!JSON.stringify(seen.openai[1]).includes("tasks · 2"), "translation has no computed value");
  const invalid = await (await handle(ask("Overdue tasks in DoorLoop. Answer in Urdu."), env(),
    fakeHttp([call("list_tasks", { filter: "overdue" }), translation("مرمت 99")], seen))).json();
  assert(invalid.answer.includes("· 2") && !invalid.answer.includes("99"), "bad translation cannot replace the actual count");
});

const timeSnapshot = (workDate: string, hours: number) => {
  const time = report.report_sections.find((s: any) => s.source === "time_doctor");
  return { id: "history-" + workDate, report_sections: [{ ...time, status: "complete",
    payload: { work_date: workDate, scope: { intended: [{ name: "Alpha" }] },
      users: [{ name: "Alpha", tracked_sec: hours * 3600 }], team_total: { tracked_sec: hours * 3600 } },
  }] };
};

Deno.test("historical date takes priority over latest report and any wrong date proposed by the model", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const historyQueries: string[] = [];
  const http = fakeHttp([call("get_team_hours", { date: "2025-11-02" })], seen, {
    history: [timeSnapshot("2025-11-02", 55), timeSnapshot("2025-11-01", 7)], historyQueries,
  });
  const body = await (await handle(ask("How many hours did the team work in Time Doctor on November 1, 2025?"), env(), http)).json();
  assert(body.answer.includes("7.0 hours for the team on 2025-11-01") && !body.answer.includes("55"), "the exact work date wins");
  assert(historyQueries.length === 1 && historyQueries[0] === "in.(2025-11-01)", "database reads only the requested date");
  assert(body.sources[0].route === "/reports/history-2025-11-01", "source points to historical report");
  assert(seen.restAuth.every(auth => auth === "Bearer user-jwt"), "historical lookup respects caller permissions");
});

Deno.test("a missing date is unavailable and a range counts only dates with confirmed totals", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const http = fakeHttp([call("get_team_hours"), call("get_team_hours", { date: "2025-11-01", through: "2025-11-03" })], seen, {
    history: [timeSnapshot("2025-11-03", 6), timeSnapshot("2025-11-01", 0)],
  });
  const missing = await (await handle(ask("How many hours did the team work in Time Doctor on 2025-11-02?"), env(), http)).json();
  const range = await (await handle(ask("Show Time Doctor team hours from 2025-11-01 to 2025-11-03."), env(), http)).json();
  assert(missing.answer.includes("no saved Time Doctor report available for 2025-11-02") && !missing.blocks.length, "does not pass off current hours or a zero");
  assert(range.answer.includes("6.0 team hours") && range.answer.includes("2 of 3 days"), "confirmed zeros are counted, missing days are explicit");
  assert(range.blocks[0].items[1].trailing === "Unavailable", "day-level coverage identifies the gap");
});

Deno.test("changing the staff name in a Time Doctor follow-up preserves the saved work date", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const http = fakeHttp([call("get_team_hours", { user: "Alpha" })], seen, { history: [timeSnapshot("2025-11-01", 7)] });
  const body = await (await handle(historyRequest([
    { role: "user", text: "Time Doctor team hours on 2025-11-01" },
    { role: "assistant", text: "Reply", context_tools: [{ name: "get_team_hours", args: { date: "2025-11-01" } }] },
    { role: "user", text: "And what about Alpha?" },
  ]), env(), http)).json();
  assert(body.answer.includes("Alpha tracked 7.0 h on 2025-11-01"), "subject changes while work date stays in scope");
});

Deno.test("reply language is part of the lookup, with a safe maintenance fallback if routing stalls", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const body = await (await handle(ask("How many overdue maintenance tasks are in DoorLoop? Answer in Urdu."), env(),
    fakeHttp([{ content: null }, translation("مرمت کے {{slot_0}} کام تاخیر کا شکار ہیں۔")], seen))).json();
  assert(body.answer.includes("مرمت کے 2 کام") && body.sources[0].kind === "tasks", "language change keeps the requested lookup");
  const tasks = seen.openai[0].tools.find((item: any) => item.function.name === "list_tasks");
  assert(tasks.function.parameters.properties.reply_language, "one data tool call also carries the requested language");
});

Deno.test("ambiguous numeric Time Doctor date is clarified before querying hours", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const body = await (await handle(ask("How many hours did the team work in Time Doctor on 03/04/2025?"), env(),
    fakeHttp([], seen))).json();
  assert(body.answer.startsWith("Which date did you mean") && !body.context_tools.length, "no unsupported date guess or latest result");
});

Deno.test("native-script Time Doctor question with reply language uses exact dates", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const body = await (await handle(ask("2026-11-24 کو Time Doctor میں ٹیم نے کتنے گھنٹے کام کیا؟"), env(), fakeHttp([
    call("get_team_hours", { reply_language: "ur", date: "2026-11-25" }),
    translation("Time Doctor کے مطابق ٹیم نے {{slot_1}} کو {{slot_0}} گھنٹے کام کیا۔"),
  ], seen, { history: [timeSnapshot("2026-11-24", 7)] }))).json();
  assert(body.answer.includes("2026-11-24 کو 7.0 گھنٹے") && body.context_tools[0].args.date === "2026-11-24", "Urdu keeps the exact work date and verified hours");
});

Deno.test("Time Doctor details distinguish idle sites from tracked hours in DoorLoop", async () => {
  const snapshot = timeSnapshot("2026-11-25", 8);
  const time = snapshot.report_sections[0];
  time.payload.users = [{ user_id: "mary", name: "Mary Dalipe", tracked_sec: 28_800, idle_sec: 450 }];
  time.payload.web_app_usage = [{
    user_id: "mary", status: "complete", rows: [
      { name: "example.com", tracked_sec: 3000, active_sec: 2700, idle_sec: 300 },
      { name: "app.doorloop.com", tracked_sec: 58, active_sec: 29, idle_sec: 29 },
      { name: "notdoorloop.com", tracked_sec: 509, active_sec: 504, idle_sec: 5 },
    ],
  }];
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const http = fakeHttp([call("get_team_hours", { user: "Mary" }), call("get_team_hours")], seen, {
    sections: [time], history: [snapshot],
  });
  const base = "How many hours did Marry work in DoorLoop on 2026-11-25?";
  const first = await (await handle(ask(base), env(), http)).json();
  const second = await (await handle(historyRequest([
    { role: "user", text: base },
    { role: "assistant", text: first.answer, context_tools: first.context_tools },
    { role: "user", text: "Where was she during that idel time?" },
  ]), env(), http)).json();
  assert(first.answer.includes("58 s") && first.answer.includes("29 s of active time"), "DoorLoop activity is sourced from its domain only");
  assert(first.blocks[0].items.length === 1 && first.sources[0].kind === "time", "website activity stays in Time Doctor");
  assert(second.answer.includes("example.com") && second.answer.includes("5 min") && second.answer.includes("2026-11-25"),
    "idle follow-up uses original staff and date");
  assert(second.answer.includes("exact idle timestamps"), "does not infer an idle timestamp or physical location");
});
