import type { Block, Ctx, Section, Source, ToolResult } from "./tools.ts";
import { combine, type Reply, say } from "./reply.ts";
import { datesIn, type TimeWindow } from "./time_window.ts";

export type TimeArgs = Partial<TimeWindow> & {
  user?: string;
  metric?: "tracked" | "active" | "idle" | "idle_by_app" | "app_usage";
  app?: string;
};
type Staff = { user_id: string; name: string; tracked_sec?: number; active_sec?: number; idle_sec?: number };
type Activity = { name: string; tracked_sec: number; active_sec: number | null; idle_sec: number | null; idle_minutes: number | null };
type StaffUsage = { user_id: string; status: string; rows: Activity[] };

const clean = (text: string) => text.toLowerCase().normalize("NFKD").replace(/\p{M}/gu, "").replace(/[^\p{L}\p{N}]+/gu, " ").trim();
export function staffMatches(name: string, input: string): boolean {
  const words = clean(input).replace(/\bmarry\b/g, "mary").split(" ").filter(Boolean);
  return words.length > 0 && words.every(word => clean(name).split(" ").includes(word));
}
const appKey = (name: string) => clean(name).replaceAll(" ", "");
function matchesApp(name: string, query: string): boolean {
  if (appKey(query) !== "doorloop") return appKey(name) === appKey(query);
  return /^door\s?loop$/i.test(name) || /^(?:[a-z\d-]+\.)*doorloop\.com$/i.test(name);
}
export function duration(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor(seconds / 60) % 60;
  const s = seconds % 60;
  return [h && h + " h", m && m + " min", (s || (!h && !m)) ? s + " s" : ""].filter(Boolean).join(" ");
}

function result(reply: Reply, blocks: Block[] = [], sources: Source[] = []): ToolResult {
  return { reply, data: {}, blocks, sources, amounts: [], suggestions: [] };
}

export function appActivity(ctx: Ctx, args: TimeArgs): ToolResult {
  const latest = ctx.sections.time_doctor;
  const day = args.date ?? latest?.payload?.work_date;
  if (!day) return result(say`There is no saved Time Doctor date to check. Which work date should I look up?`);
  const dates = datesIn({ date: day, through: args.through });
  if (!dates.length) return result(say`Which dates should I check? Please give one work date or a range of up to 31 days.`);
  const end = dates[dates.length - 1];
  const period = day === end ? say` on ${day}` : say` from ${day} through ${end}`;
  if (!args.user) return result(say`Whose Time Doctor website or app activity should I look up?`);
  const name = args.user;
  const snapshots: { day: string; section: Section; reportId?: string }[] = dates.flatMap(workDate => {
    const saved = ctx.timeHistory?.[workDate];
    const section = args.date ? saved?.section : latest;
    return section && section.status !== "unavailable" ? [{
      day: workDate, section, reportId: args.date ? saved?.reportId : ctx.report?.id,
    }] : [];
  });
  const periodReply = (reply: Reply) => combine(combine(reply, period), say`.`);
  const matches = new Map<string, Staff>();
  for (const snapshot of snapshots) {
    for (const user of (snapshot.section.payload?.users ?? []) as Staff[]) {
      if (user.user_id && staffMatches(user.name, name)) matches.set(user.user_id, user);
    }
  }
  if (matches.size > 1) return result(say`More than one staff member matches. Which full name should I use?`);
  if (!matches.size) {
    return result(periodReply(say`I couldn’t find a saved Time Doctor record for ${name}`));
  }
  const staff = [...matches.values()][0];
  const rows = new Map<string, Activity>();
  let completeDays = 0;
  let hasData = false;
  const sources: Source[] = [];
  for (const snapshot of snapshots) {
    const entry = (snapshot.section.payload?.web_app_usage as StaffUsage[] | undefined)
      ?.find(entry => entry.user_id === staff.user_id && ["complete", "partial"].includes(entry.status));
    if (!entry || !Array.isArray(entry.rows)) continue;
    hasData = true;
    if (entry.status === "complete") completeDays++;
    sources.push({ kind: "time", title: "Time Doctor web and app usage · " + snapshot.day, subtitle: snapshot.section.cutoff?.timezone ?? ctx.timezone,
      route: snapshot.reportId ? "/reports/" + snapshot.reportId : undefined });
    for (const row of entry.rows) {
      if (typeof row.name !== "string" || typeof row.tracked_sec !== "number") continue;
      const key = row.name.toLowerCase();
      const previous = rows.get(key);
      if (!previous) rows.set(key, { ...row });
      else {
        previous.tracked_sec += row.tracked_sec;
        for (const metric of ["active_sec", "idle_sec", "idle_minutes"] as const) {
          previous[metric] = previous[metric] == null || row[metric] == null ? null : previous[metric] + row[metric];
        }
      }
    }
  }
  if (!hasData) return result(periodReply(say`There is no saved Time Doctor website or app breakdown for ${staff.name}`));
  const partial = completeDays === dates.length ? say`` : say` Time Doctor returned a complete breakdown for ${completeDays} of ${dates.length} requested days.`;
  const selected = args.app;
  if (selected) {
    const found = [...rows.values()].filter(row => matchesApp(row.name, selected));
    const title = appKey(selected) === "doorloop" ? "DoorLoop" : selected;
    const tracked = found.reduce((total, row) => total + row.tracked_sec, 0);
    const totalFor = (metric: "active_sec" | "idle_sec") =>
      found.length && found.every(row => row[metric] != null) ? found.reduce((total, row) => total + (row[metric] ?? 0), 0) : null;
    const active = totalFor("active_sec");
    const idle = totalFor("idle_sec");
    const scope = say` This is Time Doctor's recorded app or website usage.`;
    let insight = found.length
      ? periodReply(say`Time Doctor tracked ${duration(tracked)} for ${staff.name} in ${title}`)
      : periodReply(say`Time Doctor returned no ${title} activity for ${staff.name}`);
    if (active != null) insight = combine(insight, say` It recorded ${duration(active)} of active time.`);
    if (idle != null) insight = combine(insight, say` It recorded ${duration(idle)} with no keyboard or mouse input.`);
    return result(combine(combine(insight, scope), partial), found.length ? [{
      type: "list", title: title + " · " + staff.name,
      items: found.map(row => ({ title: row.name, trailing: duration(row.tracked_sec) })),
    }] : [], sources);
  }
  const idle = args.metric === "idle_by_app";
  const matching = [...rows.values()].filter(row => idle ? (row.idle_sec ?? 0) > 0 : row.tracked_sec > 0);
  const metric = (row: Activity) => idle ? row.idle_sec ?? 0 : row.tracked_sec;
  matching.sort((a, b) => metric(b) - metric(a));
  const top = matching[0];
  let reply = top
    ? periodReply(idle ? say`${staff.name} had the most recorded idle time on ${top.name}, with ${duration(metric(top))}`
      : say`${staff.name} had the most tracked time on ${top.name}, with ${duration(metric(top))}`)
    : periodReply(idle ? say`The recorded website and app breakdown shows no idle time for ${staff.name}`
      : say`The recorded website and app breakdown shows no tracked usage for ${staff.name}`);
  if (idle) reply = combine(reply, say` These are totals by site or app. Time Doctor does not report exact idle timestamps or where the person was physically.`);
  if (idle && !top && rows.size && [...rows.values()].every(row => row.idle_sec == null)) {
    reply = periodReply(say`Time Doctor returned website and app usage but no idle breakdown for ${staff.name}`);
  } else if (idle && [...rows.values()].some(row => row.idle_sec == null)) {
    reply = combine(reply, say` Some sites or apps have no idle total available.`);
  }
  return result(combine(reply, partial), matching.length ? [{
    type: "list", title: idle ? "Idle time by site or app" : "Time tracked by site or app",
    items: matching.slice(0, 15).map(row => ({ title: row.name, trailing: duration(metric(row)) })),
  }] : [], sources);
}
