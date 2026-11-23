// Read-only tools for the "Ask your portfolio" assistant.
//
// Every figure the user sees is computed here from the stored report (contract
// v1.0) with integer cents. The language model only chooses tools and writes a
// short sentence; the UI cards (metrics, bars, lists, drafts) and sources are
// built here, so they never contain model-made numbers. Nothing here writes,
// sends or posts anything.

// deno-lint-ignore-file no-explicit-any
export type Tone = "ac" | "ok" | "wa" | "er" | "na";
export type Block =
  | { type: "metric"; label: string; value: string; caption?: string; chip?: { text: string; tone: Tone } }
  | { type: "bars"; title?: string; bars: { label: string; value: number; display: string; highlight?: boolean }[] }
  | { type: "list"; title: string; items: { title: string; subtitle?: string; trailing?: string; tone?: Tone; route?: string }[] }
  | { type: "draft"; title: string; body: string; note: string };
export type Source = { kind: "ledger" | "lease" | "deal" | "email" | "tasks" | "time" | "payments" | "report"; title: string; subtitle: string; route?: string };
export type ToolResult = { data: unknown; blocks: Block[]; sources: Source[]; amounts: string[]; suggestions: string[] };

export type Section = { source: string; status: string; collected_at: string | null; cutoff: any; warnings: any[]; payload: any };
export type Ctx = {
  report: { id: string; business_date: string; generated_at: string; data_mode: string; status: string } | null;
  sections: Record<string, Section>;
  payments: any[];
  taskReviews: Record<string, string>;
  evidenceReviewed: Set<number>;
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
  const top = late.slice(0, 6);
  const max = top.length ? top[0].api_balance.overdue_minor! : 0;
  const amounts = [money(total), ...late.map((l) => money(l.api_balance.overdue_minor!)), ...top.map((l) => compact(l.api_balance.overdue_minor!))];
  const blocks: Block[] = [
    { type: "metric", label: missing ? "Known overdue rent" : "Overdue rent snapshot", value: money(total),
      caption: `Across ${late.length} of ${scope.length} leases · DoorLoop balance fields${missing ? ` · ${missing} not returned` : ""}` },
  ];
  if (top.length > 1) {
    blocks.push({ type: "bars", bars: top.map((l) => ({
      label: l.unit ? `${l.unit} · ${l.property_name.split(" ").slice(0, 2).join(" ")}` : l.property_name.split(" ").slice(0, 3).join(" "),
      value: l.api_balance.overdue_minor!, display: compact(l.api_balance.overdue_minor!), highlight: l.api_balance.overdue_minor === max })) });
  }
  if (late.length) {
    blocks.push({ type: "list", title: "Leases with an overdue balance", items: late.slice(0, 12).map((l) => ({
      title: tenantName(l), subtitle: leaseLabel(l) + (l.status !== "ACTIVE" ? " · " + l.status.toLowerCase() : ""),
      trailing: money(l.api_balance.overdue_minor!), tone: l.status === "ACTIVE" ? "er" as Tone : "na" as Tone,
      route: "/payments/balance/" + l.lease_id })) });
  }
  return {
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
  const ev = section(ctx, "email_evidence")?.payload;
  const status = new Map<number, any>((ev?.deal_status ?? []).map((s: any) => [s.deal_id, s]));
  const items: any[] = ev?.items ?? [];
  return { fub, deals: (fub.payload?.deals ?? []).map((d: any) => {
    const s = status.get(d.deal_id);
    const ambiguous = s?.status === "CORRESPONDENCE_VISIBLE_REVIEW" ||
      items.some((m) => (m.deal_id === d.deal_id || m.message_id === s?.latest_message_id) && m.mapping !== "UNIQUE_PROPERTY_DEAL");
    return { ...d, evidence: s?.status ?? null, needsReview: ambiguous && !ctx.evidenceReviewed.has(d.deal_id) };
  }) };
}

function listDeals(ctx: Ctx, args: { filter?: string; query?: string }): ToolResult {
  const v = dealViews(ctx);
  if (!v) return unavailable("Follow Up Boss deals");
  const f = args.filter ?? "open";
  let deals = v.deals.filter((d: any) => args.query ? matches([d.property, d.pipeline, d.stage], args.query) : true);
  deals = deals.filter((d: any) => f === "all" ? true
    : f === "needs_review" ? d.needsReview
    : f === "closing_soon" ? d.classification === "open" && d.days_to_projected_close != null && d.days_to_projected_close >= 0 && d.days_to_projected_close <= 14
    : f === "past_due" ? d.classification === "open" && (d.days_to_projected_close ?? 0) < 0
    : d.classification === "open");
  const title = { needs_review: "Deals needing evidence review", closing_soon: "Closing in the next 14 days", past_due: "Projected close date passed", all: "All deals", open: "Open deals" }[f] ?? "Deals";
  return {
    data: { filter: f, count: deals.length, deals: deals.slice(0, 15).map((d: any) => ({ property: d.property, pipeline: d.pipeline, stage: d.stage,
      projected_close: d.projected_close_date, days_to_close: d.days_to_projected_close, flags: d.flags, needs_review: d.needsReview })) },
    blocks: [{ type: "list", title: `${title} · ${deals.length}`, items: deals.slice(0, 15).map((d: any) => ({
      title: d.property, subtitle: `${d.pipeline} · ${d.stage}`,
      trailing: d.projected_close_date ? "Close " + d.projected_close_date.slice(5).replace("-", "/") : undefined,
      tone: d.needsReview ? "wa" as Tone : d.classification === "open" ? "ac" as Tone : d.classification === "closed_by_system_flag" ? "ok" as Tone : "na" as Tone,
      route: "/more/deals/" + d.deal_id })) }],
    sources: [reportSource(ctx, v.fub, "deal", "Follow Up Boss deals", "CRM")],
    amounts: [], suggestions: f === "needs_review" ? ["Which deals close in the next two weeks?"] : ["Which deals need evidence review?"],
  };
}

function dealDetails(ctx: Ctx, args: { query: string }): ToolResult {
  const v = dealViews(ctx);
  if (!v) return unavailable("Follow Up Boss deals");
  const d = v.deals.find((x: any) => matches([x.property, x.pipeline], args.query ?? ""));
  if (!d) return { data: { matches: 0, query: args.query }, blocks: [], sources: [], amounts: [], suggestions: ["Show open deals"] };
  const ev = section(ctx, "email_evidence");
  const st = (ev?.payload?.deal_status ?? []).find((s: any) => s.deal_id === d.deal_id);
  const ids = new Set([st?.latest_message_id, st?.verified_reply_message_id].filter(Boolean));
  const emails = (ev?.payload?.items ?? []).filter((m: any) => m.deal_id === d.deal_id || ids.has(m.message_id));
  const blocks: Block[] = [{ type: "list", title: d.property, items: [
    { title: "Stage · Follow Up Boss", trailing: d.stage, tone: "ac" },
    { title: "Projected close", trailing: d.projected_close_date ?? "Not set" },
    { title: "Days in stage", trailing: d.days_in_stage == null ? "Not returned" : String(d.days_in_stage) },
    ...((d.flags ?? []) as string[]).map((f) => ({ title: f, tone: "wa" as Tone })),
  ] }];
  if (emails.length) blocks.push({ type: "list", title: "Attorney email evidence (Gmail)", items: emails.slice(0, 5).map((m: any) => ({
    title: m.subject, subtitle: (m.from ?? "") + " · " + (m.date ?? "").slice(0, 10),
    tone: m.mapping === "UNIQUE_PROPERTY_DEAL" ? "na" as Tone : "wa" as Tone })) });
  return {
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

// ───────── tasks, team, payments, status ─────────
function listTasks(ctx: Ctx, args: { filter?: string; property?: string }): ToolResult {
  const s = section(ctx, "doorloop_tasks");
  if (!s) return unavailable("DoorLoop maintenance tasks");
  const f = args.filter ?? "overdue";
  const tasks = (s.payload?.tasks ?? []).map((t: any) => {
    const review = ctx.taskReviews[t.task_id];
    const claimed = !!t.completion_claim?.claimed && review !== "verified_complete" && review !== "disputed";
    return { ...t, claimed, verified: review === "verified_complete", days: t.due_date ? daysBetween(t.due_date, ctx.today) : null };
  }).filter((t: any) => args.property ? matches([t.property_name], args.property) : true)
    .filter((t: any) => f === "all" ? true : f === "overdue" ? t.is_overdue : f === "claimed" ? t.claimed : !t.completion_claim?.claimed)
    .sort((a: any, b: any) => (b.days ?? -999) - (a.days ?? -999));
  const title = { overdue: "Overdue maintenance", claimed: "Completion claimed, not verified", open: "Open maintenance", all: "Maintenance tasks" }[f] ?? "Tasks";
  return {
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

function teamHours(ctx: Ctx): ToolResult {
  const s = section(ctx, "time_doctor");
  if (!s) return unavailable("Time Doctor activity");
  const users: any[] = s.payload?.users ?? [];
  const missing: any[] = s.payload?.scope?.missing ?? [];
  const reported = users.filter((u) => typeof u.tracked_sec === "number");
  const team = s.payload?.team_total?.tracked_sec;
  const total = typeof team === "number" ? team :
    (reported.length > 0 && reported.length === users.length ? reported.reduce((a, u) => a + u.tracked_sec, 0) : null);
  const noActivity = s.payload?.activity_status === "no_activity";
  const configured = s.payload?.scope?.intended?.length || users.length + missing.length;
  const h = (sec: number) => (sec / 3600).toFixed(1) + " h";
  return {
    data: { work_date: s.payload?.work_date, total_tracked: total == null ? null : h(total), activity_status: noActivity ? "no_activity" : undefined, users: users.map((u) => ({ name: u.name, tracked: u.tracked_sec == null ? null : h(u.tracked_sec),
      active: u.active_sec == null ? null : h(u.active_sec), idle: u.idle_sec == null ? null : h(u.idle_sec) })),
      missing: missing.map((m) => m.name + " (" + m.reason + ")"), note: "Untracked gaps are not evidence of non-work." },
    blocks: [
      { type: "metric", label: "Tracked hours · " + (s.payload?.work_date ?? "previous day"), value: noActivity ? "No recorded activity" : total == null ? "Not returned" : h(total),
        caption: `${reported.length} of ${configured} users covered`,
        chip: s.status !== "complete" || reported.length < configured
          ? { text: "Partial", tone: "wa" } : { text: "Complete", tone: "ok" } },
      ...(reported.length > 1 ? [{ type: "bars" as const, bars: reported.map((u) => ({ label: String(u.name).split(" ").slice(-2).join(" "),
        value: u.tracked_sec, display: h(u.tracked_sec) })) }] : []),
    ],
    sources: [reportSource(ctx, s, "time", "Time Doctor daily activity", "Team")], amounts: [],
    suggestions: [],
  };
}

const PAY_LABEL: Record<string, string> = { submitted: "Submitted", under_review: "Under review", approved: "Approved · not posted",
  rejected: "Rejected", posting: "Posting", posted: "Posted in DoorLoop", failed: "Posting failed" };
function outsidePayments(ctx: Ctx, args: { status?: string }): ToolResult {
  const needs = (p: any) => ["submitted", "under_review", "approved", "failed"].includes(p.status);
  const rows = ctx.payments.filter((p) => args.status === "all" ? true : needs(p));
  return {
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
  { name: "list_deals", description: "Follow Up Boss deals by filter.",
    parameters: { type: "object", properties: { filter: { type: "string", enum: ["open", "needs_review", "closing_soon", "past_due", "all"] }, query: { type: "string" } }, additionalProperties: false } },
  { name: "get_deal", description: "One deal with its stage, dates, flags and Harry's attorney email evidence.",
    parameters: { type: "object", properties: { query: { type: "string", description: "Property address or name" } }, required: ["query"], additionalProperties: false } },
  { name: "list_tasks", description: "DoorLoop maintenance tasks by filter.",
    parameters: { type: "object", properties: { filter: { type: "string", enum: ["overdue", "open", "claimed", "all"] }, property: { type: "string" } }, additionalProperties: false } },
  { name: "get_team_hours", description: "Time Doctor tracked, active and idle hours for the previous workday.",
    parameters: { type: "object", properties: {}, additionalProperties: false } },
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
    case "get_team_hours": return teamHours(ctx);
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
