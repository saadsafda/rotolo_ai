// deno test supabase/functions/ask-portfolio/index.test.ts --allow-read
// Full request flow with Supabase and OpenAI replaced by in-memory responses.
// deno-lint-ignore-file no-explicit-any
import { handle } from "./index.ts";

const fixture = JSON.parse(await Deno.readTextFile(new URL("../../../assets/fixtures/synthetic_reports.json", import.meta.url))).reports[0];
const report = { id: "r1", business_date: fixture.business_date, generated_at: fixture.generated_at, data_mode: fixture.data_mode, status: fixture.status,
  report_sections: fixture.sections };

function assert(cond: unknown, msg: string): asserts cond { if (!cond) throw new Error(msg); }
const env = (extra: Record<string, string> = {}) => ({ get: (k: string) => ({ SUPABASE_URL: "https://db.test", SUPABASE_ANON_KEY: "pk", OPENAI_API_KEY: "sk", ...extra } as any)[k] });
const ask = (text: string, auth = "Bearer user-jwt") =>
  new Request("https://fn.test/ask-portfolio", { method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", text }] }) });

/// openaiSteps: successive model messages (tool calls, then a final answer).
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
      if (path.startsWith("reports")) return Response.json([{ ...report, report_sections: opts.sections ?? report.report_sections }]);
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
  assert(body.data_mode === "synthetic", "data mode passed through");
  assert(seen.restAuth.every((a) => a === "Bearer user-jwt"), "every read uses the caller's JWT (RLS)");
  const toolMsg = seen.openai[1].messages.find((m: any) => m.role === "tool");
  assert(toolMsg && toolMsg.content.includes("$3,125.50"), "tool result sent to the model");
});

Deno.test("invented dollar figure is replaced, cards stay", async () => {
  const seen = { openai: [] as any[], restAuth: [] as string[] };
  const res = await handle(ask("How much is late?"), env(), fakeHttp([
    call("get_overdue_rent"),
    { role: "assistant", content: "Roughly $3,100 is late." },
  ], seen));
  const body = await res.json();
  assert(body.answer === "Here is what the latest records show.", "guard replaced text: " + body.answer);
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
  const toolMsg = seen.openai[1].messages.find((m: any) => m.role === "tool");
  assert(toolMsg.content.includes('"available":false'), "model told it is unavailable");
});
