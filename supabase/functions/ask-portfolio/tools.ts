// Read-only tools for the "Ask your portfolio" assistant.
//
// Every figure the user sees is computed here from the stored report (contract
// v1.0) with integer cents. The language model only chooses tools. The reply
// data, UI cards (metrics, bars, lists, drafts), and sources are
// built here, so they never contain model-made numbers. Nothing here writes,
// sends or posts anything.

// deno-lint-ignore-file no-explicit-any
import { type Reply, combine, say } from "./reply.ts";
import { type TimeWindow, datesIn } from "./time_window.ts";
import { appActivity, duration, staffMatches, type TimeArgs } from "./time_activity.ts";

export type Tone = "ac" | "ok" | "wa" | "er" | "na";
export type Block =
  | { type: "metric"; label: string; value: string; caption?: string; chip?: { text: string; tone: Tone } }
  | { type: "bars"; title?: string; bars: { label: string; value: number; display: string; highlight?: boolean }[] }
  | { type: "list"; title: string; items: { title: string; subtitle?: string; trailing?: string; tone?: Tone; route?: string }[] }
  | { type: "draft"; title: string; body: string; note: string };
export type Source = { kind: "ledger" | "lease" | "deal" | "email" | "tasks" | "time" | "payments" | "report"; title: string; subtitle: string; route?: string };
export type ToolResult = { reply?: Reply; data: unknown; blocks: Block[]; sources: Source[]; amounts: string[]; suggestions: string[] };

export type Section = { source: string; status: string; collected_at: string | null; cutoff: any; coverage?: Record<string, unknown>; warnings: any[]; payload: any };
export type Ctx = {
  report: { id: string; business_date: string; generated_at: string; data_mode: string; status: string } | null;
  sections: Record<string, Section>;
  payments: any[];
  taskReviews: Record<string, string>;
  evidenceReviewed: Set<number>;
  timeHistory?: Record<string, { section: Section; reportId: string }>;
  today: string; // business date, YYYY-MM-DD
  timezone: string;
};

// ───────── formatting ─────────
export function money(minor: number): string {
  const neg = minor < 0;
  const abs = Math.abs(Math.trunc(minor));
  const dollars = Math.floor(abs / 100).toLocaleString("en-US");
  return (neg ? "-" : "") + "$" + dollars + "." + String(abs % 100).padStart(2, "0");
}
export function compact(minor: number): string {
  const d = minor / 100;
  if (Math.abs(d) >= 1000) return "$" + (Math.round(d / 100) / 10).toLocaleString("en-US") + "k";
  return "$" + Math.round(d).toLocaleString("en-US");
}
const when = (iso: string | null, tz: string) =>
  iso ? new Date(iso).toLocaleString("en-US", { timeZone: tz, month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "not collected";
const norm = (s: unknown) => String(s ?? "").toLowerCase().replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
const matches = (hay: unknown[], query: string) => {
  const words = norm(query).split(" ").filter((w) => w.length > 0 && !["the", "at", "unit", "lease", "for", "of", "apt"].includes(w));
  const text = " " + norm(hay.join(" ")) + " ";
  return words.length > 0 && words.every((w) => text.includes(" " + w) || text.includes(w + " "));
};
const daysBetween = (a: string, b: string) => Math.round((Date.parse(b + "T00:00:00Z") - Date.parse(a + "T00:00:00Z")) / 86400000);

function section(ctx: Ctx, key: string): Section | null {
  const s = ctx.sections[key];
  return s && s.status !== "unavailable" ? s : null;
}
const unavailable = (what: string): ToolResult => ({
  reply: { template: what + " is not in the latest report or not available for this user’s role.", slots: [] },
  data: { available: false, reason: what + " is not in the latest report or not available for this user's role." },
  blocks: [], sources: [], amounts: [], suggestions: [],
});
const reportSource = (ctx: Ctx, s: Section, kind: Source["kind"], title: string, label: string): Source => ({
  kind, title, subtitle: "Collected " + when(s.collected_at, ctx.timezone) + " · " + label,
  route: ctx.report ? "/reports/" + ctx.report.id : undefined,
});

// ───────── rent ─────────
type Lease = {
  lease_id: string; reference: string | null; property_name: string; unit: string | null; lease_name: string;
  tenants: string[] | null; status: string; collection_status: string | null;
  api_balance: { total_due_minor: number | null; overdue_minor: number | null; current_minor: number | null; upcoming_minor: number | null };
};
const leaseLabel = (l: Lease) => [l.property_name, l.unit].filter(Boolean).join(" · ");
const tenantName = (l: Lease) => (l.tenants && l.tenants.length ? l.tenants.join(", ") : l.lease_name);
function findLeases(ctx: Ctx, query: string): Lease[] {
  const rent = section(ctx, "doorloop_rent");
  if (!rent) return [];
  const leases: Lease[] = rent.payload?.leases ?? [];
  return leases.filter((l) => matches([l.lease_name, l.property_name, l.unit, l.reference, ...(l.tenants ?? [])], query));
}

function overdueRent(ctx: Ctx, args: { property?: string }): ToolResult {
  const rent = section(ctx, "doorloop_rent");
  if (!rent) return unavailable("DoorLoop rent");
  const all: Lease[] = rent.payload?.leases ?? [];
  const scope = args.property ? all.filter((l) => matches([l.property_name], args.property!)) : all;
  if (args.property && !scope.length) {
    return unavailable("No leases matching the property");
  }
  const late = scope.filter((l) => (l.api_balance?.overdue_minor ?? 0) > 0)
    .sort((a, b) => (b.api_balance.overdue_minor ?? 0) - (a.api_balance.overdue_minor ?? 0));
  const missing = scope.filter((l) => l.api_balance?.overdue_minor == null).length;
  if (scope.length > 0 && missing === scope.length) {
    return unavailable("Overdue balances for these leases");
  }
  const total = late.reduce((s, l) => s + (l.api_balance.overdue_minor ?? 0), 0);
  const missingNote = missing === 1 ? say` DoorLoop did not report a balance for 1 lease.`
    : missing > 1 ? say` DoorLoop did not report balances for ${missing} leases.` : say``;
  const mainReply = late.length === 1 ? say`1 lease has overdue rent, totaling ${money(total)} in DoorLoop.`
    : late.length > 1 ? say`${late.length} leases have overdue rent, totaling ${money(total)} in DoorLoop.`
    : say`DoorLoop shows no overdue rent for the leases it reported.`;
  const reply = combine(mainReply, missingNote);
  const top = late.slice(0, 6);
  const max = top.length ? top[0].api_balance.overdue_minor! : 0;
  const amounts = [money(total), ...late.map((l) => money(l.api_balance.overdue_minor!)), ...top.map((l) => compact(l.api_balance.overdue_minor!))];
  const blocks: Block[] = [
    { type: "metric", label: missing ? "Known overdue rent" : "Overdue rent snapshot", value: money(total),
      caption: `Across ${late.length} of ${scope.length} leases · DoorLoop balance fields${missing ? ` · ${missing} not returned` : ""}` },
  ];
  if (top.length > 1) {
    blocks.push({ type: "bars", title: "Largest overdue balances", bars: top.map((l) => ({
      label: l.unit ? `${l.unit} · ${l.property_name.split(" ").slice(0, 2).join(" ")}` : l.property_name.split(" ").slice(0, 3).join(" "),
      value: l.api_balance.overdue_minor!, display: money(l.api_balance.overdue_minor!), highlight: l.api_balance.overdue_minor === max })) });
  }
  if (late.length) {
    blocks.push({ type: "list", title: "Leases with an overdue balance", items: late.slice(0, 12).map((l) => ({
      title: tenantName(l), subtitle: leaseLabel(l) + (l.status !== "ACTIVE" ? " · " + l.status.toLowerCase() : ""),
      trailing: money(l.api_balance.overdue_minor!), tone: l.status === "ACTIVE" ? "er" as Tone : "na" as Tone,
      route: "/payments/balance/" + l.lease_id })) });
  }
  return {
    reply,
    data: { as_of: rent.collected_at, total_overdue: money(total), leases_overdue: late.length, leases_in_scope: scope.length,
      balance_fields_missing: missing,
      leases: late.slice(0, 12).map((l) => ({ tenant: tenantName(l), lease: leaseLabel(l), overdue: money(l.api_balance.overdue_minor!), status: l.status })),
      note: "Balances are DoorLoop lease fields, not a reconciled ledger. Verify before contacting a tenant." },
    blocks, amounts,
    sources: [reportSource(ctx, rent, "ledger", "DoorLoop rent snapshot", "Rent")],
    suggestions: late.length ? [`Show ${tenantName(late[0])}'s payment history`, `Draft a reminder to ${tenantName(late[0])}`] : ["Any outside payments waiting?"],
  };
}

function ambiguousLease(matches: Lease[]): ToolResult {
  return {
    data: { matches: matches.length, reason: "Multiple leases match. Ask for the lease reference or exact property and unit." },
    blocks: [{ type: "list", title: "Multiple leases match", items: matches.slice(0, 8).map((lease) => ({
      title: leaseLabel(lease), subtitle: lease.reference ?? undefined, route: "/payments/balance/" + lease.lease_id,
    })) }],
    sources: [], amounts: [], suggestions: [],
  };
}

function leaseDetails(ctx: Ctx, args: { query: string }): ToolResult {
  const rent = section(ctx, "doorloop_rent");
  if (!rent) return unavailable("DoorLoop rent");
  const found = findLeases(ctx, args.query ?? "");
  if (!found.length) return { data: { matches: 0, query: args.query }, blocks: [], sources: [], amounts: [], suggestions: ["Who is behind on rent?"] };
  if (found.length > 1) return ambiguousLease(found);
  const l = found[0];
  const pays: any[] = (rent.payload?.payments ?? []).filter((p: any) => p.lease_id === l.lease_id);
  const outside = ctx.payments.filter((p) => String(p.lease_id).toLowerCase() === l.lease_id.toLowerCase());
  const b = l.api_balance ?? ({} as Lease["api_balance"]);
  const amounts = [b.total_due_minor, b.overdue_minor, ...pays.map((p) => p.amount_minor), ...outside.map((p) => p.amount_minor)]
    .filter((v): v is number => typeof v === "number").map(money);
  const blocks: Block[] = [{ type: "metric", label: "Balance · " + leaseLabel(l), value: b.total_due_minor == null ? "Not returned" : money(b.total_due_minor),
    caption: `${tenantName(l)} · Overdue ${b.overdue_minor == null ? "not returned" : money(b.overdue_minor)}`,
    chip: (b.overdue_minor ?? 0) > 0 ? { text: "Overdue", tone: "er" } : { text: l.status.toLowerCase(), tone: "na" } }];
  blocks.push({ type: "list", title: "Payments this month (DoorLoop)", items: pays.length ? pays.map((p) => ({
    title: p.date ?? "Date not returned", subtitle: (p.deposit_status ?? "status not returned").toLowerCase() + (p.returned_linked ? " · returned" : ""),
    trailing: p.amount_minor == null ? "—" : money(p.amount_minor), tone: p.returned_linked ? "er" as Tone : "na" as Tone })) : [{ title: "No DoorLoop payments recorded this month", tone: "na" }] });
  if (outside.length) {
    blocks.push({ type: "list", title: "Outside payment requests", items: outside.map((p) => ({
      title: money(p.amount_minor) + " · " + (p.method_detail ?? p.method), subtitle: p.payment_date + " · " + String(p.status).replace("_", " "),
      tone: p.status === "rejected" ? "na" as Tone : "ac" as Tone, route: "/payments/" + p.id })) });
  }
  return {
    reply: b.total_due_minor == null ? say`DoorLoop did not return the balance for ${leaseLabel(l)}.`
      : say`The DoorLoop balance for ${leaseLabel(l)} is ${money(b.total_due_minor)}.`,
    data: { lease: leaseLabel(l), tenant: tenantName(l), status: l.status, total_due: b.total_due_minor == null ? null : money(b.total_due_minor),
      overdue: b.overdue_minor == null ? null : money(b.overdue_minor),
      payments_this_month: pays.map((p) => ({ date: p.date, amount: p.amount_minor == null ? null : money(p.amount_minor), returned: !!p.returned_linked })),
      outside_requests: outside.map((p) => ({ amount: money(p.amount_minor), status: p.status, date: p.payment_date })),
      history_scope: "DoorLoop payments in the report cover the current month only." },
    blocks, amounts,
    sources: [{ kind: "lease", title: "Lease — " + leaseLabel(l), subtitle: tenantName(l) + " · DoorLoop", route: "/payments/balance/" + l.lease_id }],
    suggestions: (b.overdue_minor ?? 0) > 0 ? [`Draft a reminder to ${tenantName(l)}`] : [],
  };
}

function draftReminder(ctx: Ctx, args: { query: string }): ToolResult {
  const rent = section(ctx, "doorloop_rent");
  if (!rent) return unavailable("DoorLoop rent");
  const found = findLeases(ctx, args.query ?? "");
  if (found.length > 1) return ambiguousLease(found);
  const l = found[0];
  if (!l) return { data: { drafted: false, reason: "No lease matched " + JSON.stringify(args.query) }, blocks: [], sources: [], amounts: [], suggestions: [] };
  const overdue = l.api_balance?.overdue_minor;
  if (overdue == null || !rent.collected_at) return unavailable("The lease balance or its collection date");
  if (overdue <= 0) return { data: { drafted: false, reason: "DoorLoop shows no overdue balance for this lease." }, blocks: [], sources: [], amounts: [], suggestions: [] };
  const asOf = new Date(rent.collected_at).toLocaleDateString("en-US", { timeZone: ctx.timezone, month: "long", day: "numeric" });
  const body = `Hi ${tenantName(l)},\n\nOur records show an overdue balance of ${money(overdue)} on your lease at ${leaseLabel(l)} as of ${asOf}. ` +
    `If you have already paid, please reply with the payment date and reference so we can match it.\n\nThank you,\nRotolo Properties`;
  return {
    data: { drafted: true, tenant: tenantName(l), overdue: money(overdue), sent: false },
    blocks: [{ type: "draft", title: "Reminder draft · " + leaseLabel(l), body,
      note: "Not sent. Check the ledger and any pending payments before contacting the tenant." }],
    sources: [{ kind: "lease", title: "Lease — " + leaseLabel(l), subtitle: tenantName(l) + " · DoorLoop", route: "/payments/balance/" + l.lease_id }],
    amounts: [money(overdue)], suggestions: [`Show ${tenantName(l)}'s payment history`],
  };
}

// ───────── deals ─────────
function dealViews(ctx: Ctx) {
  const fub = section(ctx, "fub_deals");
  if (!fub) return null;
  const email = section(ctx, "email_evidence");
  const ev = email?.payload?.mailbox_verified === true ? email.payload : null;
  const status = new Map<number, any>((ev?.deal_status ?? []).map((s: any) => [s.deal_id, s]));
  const items: any[] = ev?.items ?? [];
  return { fub, deals: (fub.payload?.deals ?? []).map((d: any) => {
    const s = status.get(d.deal_id);
    const ambiguous = s?.status === "CORRESPONDENCE_VISIBLE_REVIEW" ||
      items.some((m) => (m.deal_id === d.deal_id || m.message_id === s?.latest_message_id) && m.mapping !== "UNIQUE_PROPERTY_DEAL");
    return { ...d, evidence: s?.status ?? null, needsReview: ambiguous && !ctx.evidenceReviewed.has(d.deal_id) };
  }) };
}

function listDeals(ctx: Ctx, args: { filter?: string; query?: string; stage?: string; assignee?: string; pipeline?: string }): ToolResult {
  const v = dealViews(ctx);
  if (!v) return unavailable("Follow Up Boss deals");
  const f = args.filter ?? "open";
  let deals = v.deals.filter((d: any) =>
    (!args.query || matches([d.property, d.pipeline, d.stage], args.query)) &&
    (!args.stage || matches([d.stage], args.stage)) &&
    (!args.pipeline || matches([d.pipeline], args.pipeline)) &&
    (!args.assignee || (d.assigned_users ?? []).some((name: string) => staffMatches(name, args.assignee!))));
  deals = deals.filter((d: any) => f === "all" ? true
    : f === "cancelled" ? d.classification === "cancelled"
    : f === "needs_review" ? d.needsReview
    : f === "closing_soon" ? d.classification === "open" && d.days_to_projected_close != null && d.days_to_projected_close >= 0 && d.days_to_projected_close <= 14
    : f === "past_due" ? d.classification === "open" && (d.days_to_projected_close ?? 0) < 0
    : d.classification === "open");
  const title = { needs_review: "Deals needing evidence review", closing_soon: "Closing in the next 14 days", past_due: "Projected close date passed", all: "All deals", open: "Open deals", cancelled: "Cancelled Follow Up Boss deals" }[f] ?? "Deals";
  const listed = f === "cancelled" ? deals : deals.slice(0, 15);
  const reply = f === "cancelled"
    ? deals.length === 0
      ? say`The latest Follow Up Boss report contains no deals marked cancelled.`
      : deals.length === 1
      ? say`The latest Follow Up Boss report contains 1 deal marked cancelled.`
      : say`The latest Follow Up Boss report contains ${deals.length} deals marked cancelled.`
    : combine({ template: title, slots: [] }, say` · ${deals.length}.`);
  return {
    reply,
    data: { filter: f, count: deals.length, deals: listed.map((d: any) => ({ property: d.property, pipeline: d.pipeline, stage: d.stage,
      projected_close: d.projected_close_date, days_to_close: d.days_to_projected_close, flags: d.flags, needs_review: d.needsReview })) },
    blocks: [{ type: "list", title: `${title} · ${deals.length}`, items: listed.map((d: any) => ({
      title: d.property, subtitle: `${d.pipeline} · ${d.stage}`,
      trailing: f !== "cancelled" && d.projected_close_date ? "Close " + d.projected_close_date.slice(5).replace("-", "/") : undefined,
      tone: d.needsReview ? "wa" as Tone : d.classification === "open" ? "ac" as Tone : d.classification === "closed_by_system_flag" ? "ok" as Tone : "na" as Tone,
      route: "/more/deals/" + d.deal_id })) }],
    sources: [reportSource(ctx, v.fub, "deal", "Follow Up Boss deals", "CRM")],
    amounts: [], suggestions: f === "needs_review" ? ["Which deals close in the next two weeks?"] : ["Which deals need evidence review?"],
  };
}

function dealDetails(ctx: Ctx, args: { query: string }): ToolResult {
  const v = dealViews(ctx);
  if (!v) return unavailable("Follow Up Boss deals");
  const query = args.query?.trim() ?? "";
  const matched = v.deals.filter((x: any) => String(x.deal_id) === query || matches([x.property, x.stage, x.pipeline], query));
  if (matched.length > 1) return { reply: say`More than one Follow Up Boss deal matches. Which deal should I open? You can give the property and stage or the deal ID.`,
    data: {}, blocks: [], sources: [], amounts: [], suggestions: [] };
  const d = matched[0];
  if (!d) return { data: { matches: 0, query: args.query }, blocks: [], sources: [], amounts: [], suggestions: ["Show open deals"] };
  const email = section(ctx, "email_evidence");
  const ev = email?.payload?.mailbox_verified === true ? email : null;
  const st = (ev?.payload?.deal_status ?? []).find((s: any) => s.deal_id === d.deal_id);
  const ids = new Set([st?.latest_message_id, st?.verified_reply_message_id].filter(Boolean));
  const emails = (ev?.payload?.items ?? []).filter((m: any) => m.deal_id === d.deal_id || ids.has(m.message_id));
  const blocks: Block[] = [{ type: "list", title: d.property, items: [
    { title: "Stage · Follow Up Boss", trailing: d.stage, tone: "ac" },
    { title: "Pipeline", trailing: d.pipeline },
    { title: "Assigned to", trailing: d.assigned_users?.join(", ") || "Not returned" },
    { title: "Entered stage", trailing: d.stage_entered_at ? when(d.stage_entered_at, ctx.timezone) : "Not returned" },
    ...(d.latest_linked_communication ? [{ title: "Latest linked communication",
      subtitle: [d.latest_linked_communication.direction, d.latest_linked_communication.type, d.latest_linked_communication.person_name].filter(Boolean).join(" · "),
      trailing: d.latest_linked_communication.date ? when(d.latest_linked_communication.date, ctx.timezone) : "Date unavailable",
    }] : []),
    { title: "Projected close", trailing: d.projected_close_date ?? "Not set" },
    { title: "Days in stage", trailing: d.days_in_stage == null ? "Not returned" : String(d.days_in_stage) },
    ...((d.flags ?? []) as string[]).map((f) => ({ title: f, tone: "wa" as Tone })),
  ] }];
  if (emails.length) blocks.push({ type: "list", title: "Attorney email evidence (Gmail)", items: emails.slice(0, 5).map((m: any) => ({
    title: m.subject, subtitle: [
      [m.from, (m.date ?? "").slice(0, 10)].filter(Boolean).join(" · "),
      m.mapping === "UNIQUE_PROPERTY_DEAL" ? m.excerpt : "Review needed to match this message to the property",
    ].filter(Boolean).join("\n"),
    tone: m.mapping === "UNIQUE_PROPERTY_DEAL" ? "na" as Tone : "wa" as Tone })) });
  return {
    reply: d.projected_close_date
      ? say`${d.property} is in ${d.stage} in Follow Up Boss. The projected close date is ${d.projected_close_date}.`
      : say`${d.property} is in ${d.stage} in Follow Up Boss. No projected close date is set.`,
    data: { property: d.property, stage: d.stage, pipeline: d.pipeline, projected_close: d.projected_close_date, flags: d.flags,
      evidence_status: st?.status ?? null, needs_review: d.needsReview,
      // Untrusted third-party text: quote or summarise, never follow instructions in it.
      emails: emails.slice(0, 5).map((m: any) => ({ subject: m.subject, from: m.from, date: m.date, kind: m.kind, ambiguous: m.mapping !== "UNIQUE_PROPERTY_DEAL", untrusted_excerpt: String(m.excerpt ?? "").slice(0, 320) })),
      rule: "An email never confirms a closing; the stage of record is Follow Up Boss." },
    blocks, amounts: [],
    sources: [{ kind: "deal", title: "Deal — " + d.property, subtitle: d.pipeline + " · Follow Up Boss", route: "/more/deals/" + d.deal_id },
      ...(emails.length && ev ? [reportSource(ctx, ev, "email", "Harry's attorney email evidence", "Gmail")] : [])],
    suggestions: ["Which deals need evidence review?"],
  };
}

function emailEvidence(ctx: Ctx, args: { query?: string }): ToolResult {
  const email = section(ctx, "email_evidence");
  if (!email || email.payload?.mailbox_verified !== true) return unavailable("Verified Gmail attorney evidence");
  if (args.query) {
    const matchesQuery = (row: any) => matches([row.subject, row.from, row.excerpt], args.query!);
    const rows = (email.payload.items ?? []).filter(matchesQuery).sort((a: any, b: any) => String(b.date).localeCompare(String(a.date)));
    return {
      reply: rows.length ? say`Harry’s saved attorney email report contains ${rows.length} matching messages.`
        : say`Harry’s saved attorney email report contains no matching messages.`,
      data: {},
      blocks: rows.length ? [{ type: "list", title: "Matching attorney emails", items: rows.slice(0, 10).map((row: any) => ({
        title: row.subject,
        subtitle: [[row.from, String(row.date ?? "").slice(0, 10)].filter(Boolean).join(" · "), row.excerpt].filter(Boolean).join("\n"),
        trailing: row.mapping === "UNIQUE_PROPERTY_DEAL" ? "Matched" : "Match needs review",
      })) }] : [],
      sources: [reportSource(ctx, email, "email", "Harry’s attorney email evidence", "Gmail")], amounts: [], suggestions: [],
    };
  }
  const coverage = email.coverage ?? {};
  const verifiedReplies = (email.payload.deal_status ?? []).filter((deal: any) => deal.status === "ATTORNEY_REPLY_VERIFIED").length;
  const matched = typeof coverage.matched === "number" ? coverage.matched : "Not reported";
  const unmatched = typeof coverage.unmatched === "number" ? coverage.unmatched : "Not reported";
  const complete = email.status === "complete" && coverage.next_page_pending !== true;
  const note = complete ? "The report completed its 90-day attorney search."
    : coverage.next_page_pending === true ? "Gmail had more results than this report collected."
    : "The report has partial Gmail coverage.";
  return {
    reply: combine(verifiedReplies === 1
      ? say`The latest report found verified attorney replies for 1 deal in Harry’s Gmail.`
      : say`The latest report found verified attorney replies for ${verifiedReplies} deals in Harry’s Gmail.`,
      { template: " " + note, slots: [] }),
    data: { count: verifiedReplies },
    blocks: [{ type: "list", title: "Harry’s Gmail · 90-day attorney search", items: [
      { title: "Deals with verified attorney replies", trailing: String(verifiedReplies) },
      { title: "Matched correspondence", trailing: String(matched) },
      { title: "Unmatched correspondence", trailing: String(unmatched) },
      { title: "Search coverage", trailing: complete ? "Complete" : "Partial", tone: complete ? "ok" : "wa" },
    ] }],
    sources: [reportSource(ctx, email, "email", "Harry’s attorney email evidence", "Gmail")],
    amounts: [],
    suggestions: ["Which deals need evidence review?"],
  };
}

// ───────── tasks, team, payments, status ─────────
function listTasks(ctx: Ctx, args: { filter?: string; property?: string; query?: string; priority?: string }): ToolResult {
  const s = section(ctx, "doorloop_tasks");
  if (!s) return unavailable("DoorLoop maintenance tasks");
  const f = args.filter ?? (args.query ? "all" : "overdue");
  const tasks = (s.payload?.tasks ?? []).map((t: any) => {
    const review = ctx.taskReviews[t.task_id];
    const claimed = !!t.completion_claim?.claimed && review !== "verified_complete" && review !== "disputed";
    return { ...t, claimed, verified: review === "verified_complete", days: t.due_date ? daysBetween(t.due_date, ctx.today) : null };
  }).filter((t: any) => (!args.property || matches([t.property_name], args.property)) &&
    (!args.query || String(t.task_id) === args.query || matches([t.subject], args.query)) &&
    (!args.priority || String(t.priority).toLowerCase() === args.priority.toLowerCase()))
    .filter((t: any) => f === "all" ? true : f === "overdue" ? t.is_overdue : f === "claimed" ? t.claimed : !t.completion_claim?.claimed)
    .sort((a: any, b: any) => (b.days ?? -999) - (a.days ?? -999));
  if (args.query && tasks.length === 1) {
    const task = tasks[0];
    return {
      reply: say`DoorLoop lists ${task.subject} as ${task.status}.`,
      data: {},
      blocks: [{ type: "list", title: task.subject, items: [
        { title: "Property", trailing: task.property_name ?? "Not returned" },
        { title: "DoorLoop status", trailing: task.status },
        { title: "Priority", trailing: task.priority ?? "Not returned" },
        { title: "Due date", trailing: task.due_date ?? "Not returned" },
        { title: "Last updated", trailing: when(task.updated_at, ctx.timezone) },
        { title: "Assigned to", trailing: task.assignees?.join(", ") || "Not returned" },
        { title: "Completion review", trailing: task.verified ? "Verified" : task.claimed ? "DoorLoop reports complete · needs review" : "Pending" },
      ] }],
      sources: [reportSource(ctx, s, "tasks", "DoorLoop maintenance tasks", "Tasks")],
      amounts: [], suggestions: [],
    };
  }
  const title = { overdue: "Overdue maintenance", claimed: "Completion claimed, not verified", open: "Open maintenance", all: "Maintenance tasks" }[f] ?? "Tasks";
  return {
    reply: combine({ template: title, slots: [] }, say` · ${tasks.length}.`),
    data: { filter: f, count: tasks.length, tasks: tasks.slice(0, 15).map((t: any) => ({ subject: t.subject, property: t.property_name, status: t.status,
      due: t.due_date, days_overdue: t.is_overdue ? t.days : null, priority: t.priority })),
      note: "Due dates are not confirmed contractor appointments." },
    blocks: [{ type: "list", title: `${title} · ${tasks.length}`, items: tasks.slice(0, 15).map((t: any) => ({
      title: t.subject, subtitle: [t.property_name, t.priority ? t.priority.toLowerCase() + " priority" : null].filter(Boolean).join(" · "),
      trailing: t.is_overdue && t.days != null ? `${t.days}d overdue` : t.due_date ? "Due " + t.due_date.slice(5).replace("-", "/") : undefined,
      tone: t.is_overdue ? "er" as Tone : t.claimed ? "wa" as Tone : "na" as Tone, route: "/tasks/" + t.task_id })) }],
    sources: [reportSource(ctx, s, "tasks", "DoorLoop maintenance tasks", "Tasks")], amounts: [],
    suggestions: f === "claimed" ? ["Show overdue maintenance"] : ["Which completions need verification?"],
  };
}

function teamHours(ctx: Ctx, args: TimeArgs): ToolResult {
  const s = section(ctx, "time_doctor");
  if (!s) return { ...unavailable("Time Doctor activity"), reply: say`Time Doctor hours are unavailable in the latest report.` };
  const users: any[] = s.payload?.users ?? [];
  const missing: any[] = s.payload?.scope?.missing ?? [];
  const workDate = s.payload?.work_date ?? "the report’s work date";
  const h = (sec: number) => (sec / 3600).toFixed(1) + " h";
  const sources = [reportSource(ctx, s, "time", "Time Doctor daily activity", "Team")];
  if (args.user?.trim()) {
    const query = args.user;
    const staff = [...users, ...missing].filter((u) => typeof u.name === "string" && staffMatches(u.name, query));
    if (staff.length !== 1) {
      return { reply: staff.length ? say`Several staff match. Which full name should I look up?`
        : say`I couldn’t find that staff member in this report’s Time Doctor scope for ${workDate}.`,
      data: {}, blocks: [], sources, amounts: [], suggestions: ["Show team hours"] };
    }
    const user = staff[0];
    const metrics = [
      { title: "Tracked", seconds: user.tracked_sec },
      { title: "Active", seconds: user.active_sec },
      { title: "Idle", seconds: user.idle_sec },
    ];
    const metric = args.metric === "idle" || args.metric === "active" ? args.metric : "tracked";
    const seconds = user[metric + "_sec"];
    const reply = metric === "idle" ? say`Time Doctor recorded ${typeof seconds === "number" ? duration(seconds) : ""} with no keyboard or mouse input for ${user.name} on ${workDate}.`
      : metric === "active" ? say`Time Doctor recorded ${typeof seconds === "number" ? duration(seconds) : ""} of active computer time for ${user.name} on ${workDate}.`
      : seconds === 0 ? say`Time Doctor recorded no activity for ${user.name} on ${workDate}.`
      : say`${user.name} tracked ${typeof seconds === "number" ? h(seconds) : ""} on ${workDate}.`;
    return {
      reply: typeof seconds === "number" ? reply : metric === "idle" ? say`Time Doctor didn’t return idle time for ${user.name} on ${workDate}.`
        : metric === "active" ? say`Time Doctor didn’t return active time for ${user.name} on ${workDate}.`
        : say`Time Doctor didn’t return tracked hours for ${user.name} on ${workDate}.`,
      data: { tracked_seconds: seconds, partial: s.status !== "complete" },
      blocks: [{ type: "list", title: `${user.name} · ${workDate}`, items: metrics.map((m) => ({
        title: m.title, trailing: typeof m.seconds === "number" ? h(m.seconds) : "Not returned",
      })) }],
      sources, amounts: [], suggestions: ["Show team hours"],
    };
  }
  const reported = users.filter((u) => typeof u.tracked_sec === "number");
  const team = s.payload?.team_total?.tracked_sec;
  const total = typeof team === "number" ? team :
    (reported.length > 0 && reported.length === users.length ? reported.reduce((a, u) => a + u.tracked_sec, 0) : null);
  const noActivity = s.payload?.activity_status === "no_activity";
  const configured = s.payload?.scope?.intended?.length || users.length + missing.length;
  const coverage = reported.length < configured ? say` The report includes hours for ${reported.length} of ${configured} team members.` : say``;
  const reply = noActivity ? say`Time Doctor recorded no tracked time on ${workDate}.`
    : total == null ? say`Time Doctor did not return a team total for ${workDate}.`
    : say`Time Doctor recorded ${(total / 3600).toFixed(1)} hours for the team on ${workDate}.`;
  return {
    reply: combine(reply, coverage),
    data: { tracked_seconds: noActivity ? 0 : total, partial: s.status !== "complete" || reported.length < configured, work_date: s.payload?.work_date, total_tracked: total == null ? null : h(total), activity_status: noActivity ? "no_activity" : undefined, users: users.map((u) => ({ name: u.name, tracked: u.tracked_sec == null ? null : h(u.tracked_sec),
      active: u.active_sec == null ? null : h(u.active_sec), idle: u.idle_sec == null ? null : h(u.idle_sec) })),
      missing: missing.map((m) => m.name + " (" + m.reason + ")"), note: "Untracked gaps are not evidence of non-work." },
    blocks: [
      { type: "metric", label: "Tracked hours · " + (s.payload?.work_date ?? "previous day"), value: noActivity ? "No recorded activity" : total == null ? "Not returned" : h(total),
        caption: `${reported.length} of ${configured} users covered`,
        chip: s.status !== "complete" || reported.length < configured
          ? { text: "Partial", tone: "wa" } : { text: "Complete", tone: "ok" } },
      ...(reported.length > 1 ? [{ type: "bars" as const, title: "Hours by team member", bars: reported.map((u) => ({ label: String(u.name),
        value: u.tracked_sec, display: h(u.tracked_sec) })) }] : []),
    ],
    sources, amounts: [],
    suggestions: [],
  };
}

function historicalHours(ctx: Ctx, args: TimeWindow & TimeArgs): ToolResult {
  const dates = datesIn(args);
  const empty = (reply: Reply): ToolResult => ({ reply, data: {}, blocks: [], sources: [], amounts: [], suggestions: [] });
  if (!dates.length) return empty(say`Which dates should I check? Please give one date or a range of up to 31 days.`);
  if (!ctx.timeHistory) return empty(say`I couldn’t check the saved Time Doctor reports for the requested date. Please try again.`);
  const matched = dates.flatMap(date => {
    const record = ctx.timeHistory?.[date];
    if (!record) return [];
    const result = teamHours({
      ...ctx,
      report: ctx.report ? { ...ctx.report, id: record.reportId } : ctx.report,
      sections: { time_doctor: record.section },
    }, args);
    const data = result.data as { tracked_seconds?: number | null; partial?: boolean };
    return [{ date, result, seconds: data.tracked_seconds, partial: data.partial }];
  });
  if (dates.length === 1) {
    return matched[0]?.result ?? empty(say`There is no saved Time Doctor report available for ${args.date}.`);
  }
  const end = dates[dates.length - 1];
  const usable = matched.filter(day => typeof day.seconds === "number");
  if (!usable.length) {
    return empty(args.user
      ? say`There are no saved Time Doctor hours available for ${args.user} from ${args.date} through ${end}.`
      : say`There are no saved Time Doctor hours available from ${args.date} through ${end}.`);
  }
  const hours = (usable.reduce((sum, day) => sum + (day.seconds ?? 0), 0) / 3600).toFixed(1);
  const tracked = args.user
    ? args.metric === "idle" ? say`Time Doctor recorded ${hours} hours with no keyboard or mouse input for ${args.user} from ${args.date} through ${end}.`
      : args.metric === "active" ? say`Time Doctor recorded ${hours} active hours for ${args.user} from ${args.date} through ${end}.`
      : say`Time Doctor recorded ${hours} hours for ${args.user} from ${args.date} through ${end}.`
    : say`Time Doctor recorded ${hours} team hours from ${args.date} through ${end}.`;
  const coverage = usable.length < dates.length
    ? say` This includes ${usable.length} of ${dates.length} days with saved hours. The other days have no available totals.`
    : say``;
  return {
    reply: combine(combine(tracked, coverage), usable.some(day => day.partial)
      ? say` Some of the saved totals are partial.` : say``),
    data: {}, amounts: [], suggestions: [],
    blocks: [{
      type: "list", title: "Time Doctor hours by day",
      items: dates.map(date => {
        const day = usable.find(item => item.date === date);
        return { title: date, trailing: day ? ((day.seconds ?? 0) / 3600).toFixed(1) + " h" : "Unavailable" };
      }),
    }],
    sources: matched.flatMap(day => day.result.sources.map(source => ({ ...source, title: source.title + " · " + day.date }))),
  };
}

const PAY_LABEL: Record<string, string> = { submitted: "Submitted", under_review: "Under review", approved: "Approved · not posted",
  rejected: "Rejected", posting: "Posting", posted: "Posted in DoorLoop", failed: "Posting failed" };
function outsidePayments(ctx: Ctx, args: { status?: string }): ToolResult {
  const needs = (p: any) => ["submitted", "under_review", "approved", "failed"].includes(p.status);
  const rows = ctx.payments.filter((p) => args.status === "all" ? true : needs(p));
  return {
    reply: say`Outside payments · ${rows.length}.`,
    data: { count: rows.length, scope: args.status === "all" ? "all visible" : "needing action",
      payments: rows.slice(0, 15).map((p) => ({ amount: money(p.amount_minor), method: p.method_detail ?? p.method, status: PAY_LABEL[p.status] ?? p.status,
        where: [p.property_name, p.unit].filter(Boolean).join(" · "), paid_on: p.payment_date })),
      note: "Approval never posts to DoorLoop; posting is disabled until verified." },
    blocks: [{ type: "list", title: `Outside payments · ${rows.length}`, items: rows.slice(0, 15).map((p) => ({
      title: money(p.amount_minor) + " · " + (p.method_detail ?? p.method), subtitle: [p.property_name, p.unit, p.tenant_name].filter(Boolean).join(" · "),
      trailing: PAY_LABEL[p.status] ?? p.status, tone: p.status === "under_review" ? "wa" as Tone : p.status === "rejected" ? "na" as Tone : "ac" as Tone,
      route: "/payments/" + p.id })) }],
    sources: [{ kind: "payments", title: "Outside payment requests", subtitle: "App records", route: "/payments" }],
    amounts: rows.map((p) => money(p.amount_minor)), suggestions: ["Who is behind on rent?"],
  };
}

function reportStatus(ctx: Ctx): ToolResult {
  if (!ctx.report) return { data: { report: null }, blocks: [], sources: [], amounts: [], suggestions: [] };
  const names: Record<string, string> = { ai_summary: "AI summary", fub_deals: "Follow Up Boss", email_evidence: "Gmail evidence",
    doorloop_rent: "DoorLoop rent", doorloop_tasks: "DoorLoop tasks", time_doctor: "Time Doctor" };
  const secs = Object.values(ctx.sections);
  return {
    reply: say`Here is the status of the data sources in the latest report.`,
    data: { business_date: ctx.report.business_date, generated_at: ctx.report.generated_at, status: ctx.report.status, data_mode: ctx.report.data_mode,
      sources: secs.map((s) => ({ source: names[s.source] ?? s.source, status: s.status, collected: s.collected_at, warnings: (s.warnings ?? []).map((w: any) => w.message).slice(0, 2) })) },
    blocks: [{ type: "list", title: "Data sources · latest report", items: secs.map((s) => ({
      title: names[s.source] ?? s.source, subtitle: "Collected " + when(s.collected_at, ctx.timezone),
      trailing: s.status, tone: s.status === "complete" ? "ok" as Tone : s.status === "unavailable" ? "er" as Tone : "wa" as Tone })) }],
    sources: [{ kind: "report", title: "Daily report " + ctx.report.business_date, subtitle: "Generated " + when(ctx.report.generated_at, ctx.timezone), route: "/reports/" + ctx.report.id }],
    amounts: [], suggestions: [],
  };
}

// ───────── registry ─────────
export const TOOL_SPECS = [
  { name: "get_overdue_rent", description: "Leases with an overdue balance (DoorLoop lease fields) and the total. Use for late rent, arrears, who owes money.",
    parameters: { type: "object", properties: { property: { type: "string", description: "Optional property name filter" } }, additionalProperties: false } },
  { name: "get_lease", description: "One lease: balance, DoorLoop payments this month, outside payment requests. Use for a tenant, unit or lease's payment history.",
    parameters: { type: "object", properties: { query: { type: "string", description: "Tenant name, unit, property or lease reference" } }, required: ["query"], additionalProperties: false } },
  { name: "draft_rent_reminder", description: "Builds a polite reminder draft for a tenant with an overdue balance. It is never sent.",
    parameters: { type: "object", properties: { query: { type: "string", description: "Tenant name, unit or property" } }, required: ["query"], additionalProperties: false } },
  { name: "list_deals", description: "Follow Up Boss (FUB) deals by filter. Use cancelled for cancellation leads, cancelled deals, or deals in a cancellation stage.",
    parameters: { type: "object", properties: { filter: { type: "string", enum: ["open", "needs_review", "closing_soon", "past_due", "cancelled", "all"] }, query: { type: "string" },
      stage: { type: "string" }, assignee: { type: "string" }, pipeline: { type: "string" } }, additionalProperties: false } },
  { name: "get_deal", description: "One deal with its stage, dates, flags and Harry's attorney email evidence.",
    parameters: { type: "object", properties: { query: { type: "string", description: "Property address or name" } }, required: ["query"], additionalProperties: false } },
  { name: "list_tasks", description: "DoorLoop maintenance tasks by status, property or priority. For the details of a named task, supply its subject or ID as query; omit filter to search all statuses.",
    parameters: { type: "object", properties: { filter: { type: "string", enum: ["overdue", "open", "claimed", "all"] }, property: { type: "string" }, query: { type: "string" }, priority: { type: "string" } }, additionalProperties: false } },
  { name: "get_team_hours", description: "Time Doctor tracked, active and idle totals, plus website and app usage (including DoorLoop). Use idle_by_app for sites or apps with idle time. Use app_usage for website and app time, setting app for a named app like DoorLoop. Never infer physical location or exact idle moments. For an explicit day or period, pass resolved dates. Supply a staff name for individual or app details.",
    parameters: { type: "object", properties: {
      user: { type: "string", description: "Staff name from the question or the active follow-up" },
      metric: { type: "string", enum: ["tracked", "active", "idle", "idle_by_app", "app_usage"] },
      app: { type: "string", description: "Exact requested website or app, e.g. DoorLoop; omit for an overall app breakdown" },
      date: { type: "string", description: "Requested work date or first day of the requested period in YYYY-MM-DD" },
      through: { type: "string", description: "Last inclusive work date in YYYY-MM-DD, for a period only" },
    }, additionalProperties: false } },
  { name: "get_email_evidence", description: "Harry's Gmail attorney correspondence, excerpts and verified replies in the latest saved report. Give a sender name, subject or keyword as query for message details. Use get_deal for correspondence about a named property.",
    parameters: { type: "object", properties: { query: { type: "string" } }, additionalProperties: false } },
  { name: "list_outside_payments", description: "Outside payment requests submitted in the app (Zelle, check, cash…).",
    parameters: { type: "object", properties: { status: { type: "string", enum: ["needs_action", "all"] } }, additionalProperties: false } },
  { name: "get_report_status", description: "Which data sources are in the latest report, when they were collected and any gaps.",
    parameters: { type: "object", properties: {}, additionalProperties: false } },
];

export function runTool(name: string, args: any, ctx: Ctx): ToolResult {
  switch (name) {
    case "get_overdue_rent": return overdueRent(ctx, args ?? {});
    case "get_lease": return leaseDetails(ctx, args ?? {});
    case "draft_rent_reminder": return draftReminder(ctx, args ?? {});
    case "list_deals": return listDeals(ctx, args ?? {});
    case "get_deal": return dealDetails(ctx, args ?? {});
    case "list_tasks": return listTasks(ctx, args ?? {});
    case "get_team_hours":
      if (args?.app || args?.metric === "app_usage" || args?.metric === "idle_by_app") return appActivity(ctx, args);
      return args?.date ? historicalHours(ctx, args) : teamHours(ctx, args ?? {});
    case "get_email_evidence": return emailEvidence(ctx, args ?? {});
    case "list_outside_payments": return outsidePayments(ctx, args ?? {});
    case "get_report_status": return reportStatus(ctx);
    default: return { data: { error: "unknown tool " + name }, blocks: [], sources: [], amounts: [], suggestions: [] };
  }
}

/// Every dollar figure in the model's sentence must come from a tool result.
export function amountsAreGrounded(text: string, allowed: Set<string>): boolean {
  const found = text.match(/\$\s?\d[\d,]*(?:\.\d+)?k?/g) ?? [];
  return found.every((a) => allowed.has(a.replace(/\s/g, "")));
}
