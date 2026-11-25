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
function fakeHttp(openaiSteps: any[], seen: { openai: any[]; restAuth: string[] }, opts: { authOk?: boolean; sections?: any[] } = {}) {
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
        assert(new URL(url).searchParams.get("data_mode") === "eq.live", "signed-in assistant must only query live reports");
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
