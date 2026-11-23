// node --test supabase/functions/ask-portfolio/tools.test.ts   (Node 22.6+ strips the types)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { amountsAreGrounded, money, compact, runTool, type Ctx } from "./tools.ts";

function ctxFrom(report: any, extra: Partial<Ctx> = {}): Ctx {
  return {
    report: { id: "r1", business_date: report.business_date, generated_at: report.generated_at, data_mode: report.data_mode, status: report.status },
    sections: Object.fromEntries(report.sections.map((s: any) => [s.source, s])),
    payments: [], taskReviews: {}, evidenceReviewed: new Set(), today: "2026-11-18", timezone: "America/New_York", ...extra,
  };
}
const fixture = JSON.parse(readFileSync(new URL("../../../assets/fixtures/synthetic_reports.json", import.meta.url), "utf8")).reports[0];
const live = JSON.parse(readFileSync(new URL("../../../n8n/test/sample_report.json", import.meta.url), "utf8"));

test("money formatting is exact cents", () => {
  assert.equal(money(145007), "$1,450.07");
  assert.equal(money(-5), "-$0.05");
  assert.equal(compact(482000), "$4.8k");
  assert.equal(compact(95000), "$950");
});

test("overdue rent totals integer cents and builds cards + sources", () => {
  const r = runTool("get_overdue_rent", {}, ctxFrom(fixture));
  const d: any = r.data;
  // fixture: 70000 + 32550 + 210000 (inactive) = 312550; L-302 balance not returned
  assert.equal(d.total_overdue, "$3,125.50");
  assert.equal(d.leases_overdue, 3);
  assert.equal(d.balance_fields_missing, 1);
  assert.equal(r.blocks[0].type, "metric");
  assert.ok(r.blocks.some((b) => b.type === "bars"));
  assert.equal(r.sources[0].kind, "ledger");
  assert.ok(r.amounts.includes("$3,125.50"));
});

test("lease lookup by tenant, unit or reference; reminder draft is never sent", () => {
  const ctx = ctxFrom(fixture);
  const l: any = runTool("get_lease", { query: "Tenant Bravo" }, ctx).data;
  assert.equal(l.overdue, "$325.50");
  assert.equal(runTool("get_lease", { query: "L-101" }, ctx).sources[0].route, "/payments/balance/aaaaaaaaaaaaaaaaaaaaaaa1");
  const draft = runTool("draft_rent_reminder", { query: "2B Maple Court" }, ctx);
  assert.equal((draft.data as any).sent, false);
  assert.equal(draft.blocks[0].type, "draft");
  assert.match((draft.blocks[0] as any).body, /\$325\.50/);
  assert.equal((runTool("draft_rent_reminder", { query: "Tenant Charlie" }, ctx).data as any).drafted, false); // nothing overdue
});

test("deals: evidence review flag respects reviews; untrusted excerpt is labelled", () => {
  const ctx = ctxFrom(fixture);
  const nr: any = runTool("list_deals", { filter: "needs_review" }, ctx).data;
  assert.deepEqual(nr.deals.map((d: any) => d.property).sort(), ["TEST 220 Oak Ave Riverton", "TEST 220 Oak Ave Riverton"]);
  const reviewed: any = runTool("list_deals", { filter: "needs_review" }, ctxFrom(fixture, { evidenceReviewed: new Set([9002, 9003]) })).data;
  assert.equal(reviewed.count, 0);
  const deal: any = runTool("get_deal", { query: "220 Oak Ave" }, ctx).data;
  assert.ok(deal.emails[0].untrusted_excerpt.includes("ignore previous instructions"));
  assert.equal(deal.stage, "Clear to Close");
});

test("tasks, team hours, status and the live n8n report shape", () => {
  const ctx = ctxFrom(fixture);
  assert.equal((runTool("list_tasks", { filter: "overdue" }, ctx).data as any).count, 2);
  assert.equal((runTool("list_tasks", { filter: "claimed" }, ctxFrom(fixture, { taskReviews: { "task-02": "verified_complete" } })).data as any).count, 0);
  assert.equal((runTool("get_team_hours", {}, ctx).data as any).total_tracked, "16.1 h");
  assert.equal(runTool("get_report_status", {}, ctx).blocks[0].type, "list");
  const lc = ctxFrom(live, { today: "2026-11-20" });
  assert.equal((runTool("get_overdue_rent", {}, lc).data as any).total_overdue, "$700.00");
  assert.equal((runTool("list_tasks", { filter: "overdue" }, lc).data as any).count, 1);
});

test("role limits: a missing section is reported as unavailable, not empty", () => {
  const staff = ctxFrom({ ...fixture, sections: fixture.sections.filter((s: any) => s.source === "fub_deals") });
  assert.equal((runTool("get_overdue_rent", {}, staff).data as any).available, false);
  assert.equal(runTool("get_overdue_rent", {}, staff).blocks.length, 0);
});

test("dollar guard rejects figures no tool produced", () => {
  const ok = new Set(["$3,125.50", "$700"]);
  assert.equal(amountsAreGrounded("Total is **$3,125.50**.", ok), true);
  assert.equal(amountsAreGrounded("About $3,100 is late.", ok), false);
  assert.equal(amountsAreGrounded("No money mentioned.", ok), true);
});
