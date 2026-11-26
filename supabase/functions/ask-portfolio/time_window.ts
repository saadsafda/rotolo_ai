export type TimeWindow = { date: string; through?: string };

export function validDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(value + "T00:00:00Z");
  return !isNaN(+parsed) && parsed.toISOString().slice(0, 10) === value;
}

function shift(date: string, days: number): string {
  const value = new Date(date + "T00:00:00Z");
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

export function datesIn(window: TimeWindow): string[] {
  const end = window.through ?? window.date;
  if (!validDate(window.date) || !validDate(end) || window.date > end || end > shift(window.date, 30)) return [];
  const dates: string[] = [];
  for (let date = window.date; date <= end; date = shift(date, 1)) dates.push(date);
  return dates;
}

const monthNames = "january february march april may june july august september october november december".split(" ");
const monthPattern = monthNames.map(name => `${name.slice(0, 3)}(?:${name.slice(3)})?`).join("|");
const englishDate = new RegExp(`\\b(?:(${monthPattern})\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?[,]?\\s+(\\d{4})|(\\d{1,2})(?:st|nd|rd|th)?\\s+(${monthPattern})\\.?[,]?\\s+(\\d{4}))\\b`, "gi");

export function requestedWindow(text: string, today: string): TimeWindow | undefined {
  const offsets: Record<string, number> = { today: 0, yesterday: -1, tomorrow: 1, "day before yesterday": -2 };
  // A comparison or a range may mention more than one day. Leave its meaning to the router.
  const relative = [...text.matchAll(/\b(day before yesterday|today|yesterday|tomorrow)\b/gi)];
  const iso = text.match(/\b\d{4}-\d{2}-\d{2}\b/g) ?? [];
  const written = [...text.matchAll(englishDate)];
  if (relative.length + iso.length + written.length === 1 &&
    !/\b(?:since|until|before|after|between|starting|through)\b/i.test(text.replace(/day before yesterday/gi, ""))) {
    if (iso[0]) return { date: iso[0] };
    if (relative.length) return { date: shift(today, offsets[relative[0][0].toLowerCase()]) };
    const [, month, day, year, otherDay, otherMonth, otherYear] = written[0];
    const index = monthNames.findIndex(name => name.startsWith((month ?? otherMonth).toLowerCase()));
    return { date: `${year ?? otherYear}-${String(index + 1).padStart(2, "0")}-${(day ?? otherDay).padStart(2, "0")}` };
  }
  const week = text.match(/\b(last|this) week\b/i)?.[1]?.toLowerCase();
  if (week && !relative.length && !iso.length && !written.length) {
    const dayOfWeek = new Date(today + "T00:00:00Z").getUTCDay();
    const monday = shift(today, -((dayOfWeek + 6) % 7));
    return week === "last" ? { date: shift(monday, -7), through: shift(monday, -1) } : { date: monday, through: today };
  }
}

export function ambiguousDate(text: string): boolean {
  for (const [, first, second] of text.matchAll(/\b(\d{1,2})[/.](\d{1,2})(?:[/.]\d{2,4})?\b/g)) {
    if (+first >= 1 && +first <= 12 && +second >= 1 && +second <= 12 && first !== second) return true;
  }
  return false;
}

export const mentionsDate = new RegExp(
  `\\b(?:today|yesterday|tomorrow|(?:last|this|next) (?:week|month|year)|last \\d+ days?|monday|tuesday|wednesday|thursday|friday|saturday|sunday|\\d{4}-\\d{2}-\\d{2}|\\d{1,2}[/.-]\\d{1,2}(?:[/.-]\\d{2,4})?)\\b|\\b(?:${monthPattern})\\.? +\\d{1,2}\\b|\\b\\d{1,2}(?:st|nd|rd|th)? +(?:${monthPattern})\\b`,
  "i",
);

export const localizedDate = /\b(?:ayer|anteayer|hoy|mañana|la semana pasada|este mes|hier|avant-hier|aujourd'hui|demain|semaine dernière|ce mois|\d{1,2} (?:de )?(?:enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre|janvier|février|mars|avril|mai|juin|juillet|août|septembre|octobre|novembre|décembre))\b|(?:گزشتہ|آج|کل|تاریخ|تھا|پچھلے ہفتے)/iu;
