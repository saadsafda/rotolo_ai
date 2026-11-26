export type Reply = { template: string; slots: string[] };

// Keep report values and record labels out of the translation request.
export function say(parts: TemplateStringsArray, ...values: (string | number)[]): Reply {
  const slots = values.map(String);
  return { template: parts.map((part, i) => i ? `{{slot_${i - 1}}}${part}` : part).join(""), slots };
}

const slotPattern = /\{\{slot_(\d+)\}\}/g;
export function render(reply: Reply, template = reply.template): string {
  return template.replace(slotPattern, (_, index) => reply.slots[Number(index)] ?? "");
}

export function combine(first: Reply, second: Reply): Reply {
  return {
    template: first.template + second.template.replace(slotPattern, (_, index) => `{{slot_${first.slots.length + Number(index)}}}`),
    slots: [...first.slots, ...second.slots],
  };
}

export function languageCode(value: unknown): string | undefined {
  return typeof value === "string" && /^[a-z]{2,3}(?:-[A-Z]{2})?$/.test(value) ? value : undefined;
}

export function languageHint(text: string): string | undefined {
  const requested = text.match(/\b(?:answer|reply|respond|speak)(?: to me)? in (English|Spanish|French|Urdu|Hindi|Arabic|German|Portuguese)\b/i)?.[1]?.toLowerCase();
  const languages: Record<string, string> = {
    english: "en", spanish: "es", french: "fr", urdu: "ur", hindi: "hi", arabic: "ar", german: "de", portuguese: "pt",
  };
  if (requested) return languages[requested];
  if (/[ٹڈڑںےھگپچژککی]/u.test(text)) return "ur";
  if (/\p{Script=Arabic}/u.test(text)) return "ar";
  if (/\p{Script=Devanagari}/u.test(text)) return "hi";
  if (/[¿¡]|\b(solo el total|cu[aá]ntos?|negocios cancelados|en espa[nñ]ol)\b/i.test(text)) return "es";
  if (/\b(combien|en retard|en fran[cç]ais)\b/i.test(text)) return "fr";
  return undefined;
}

function matchesTemplate(original: string, translated: unknown): translated is string {
  if (typeof translated !== "string" || !translated.trim() || translated.length > 1200) return false;
  const protectedParts = (value: string) => (value.match(/\{\{slot_\d+\}\}|\p{N}+/gu) ?? []).sort().join("|");
  return protectedParts(original) === protectedParts(translated);
}

export async function renderReplies(
  replies: Reply[], language: string | undefined, http: typeof fetch, key: string, model: string,
): Promise<string> {
  const english = () => replies.map((reply) => render(reply)).join(" ");
  if (!language || language.startsWith("en") || !replies.length) return english();
  try {
    const response = await http("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { authorization: "Bearer " + key, "content-type": "application/json" },
      body: JSON.stringify({
        model, reasoning_effort: "low", max_completion_tokens: 1500,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: "Translate each message template into the requested language. Use clear everyday language. Keep all placeholders exactly intact, including double braces, and keep product names, meaning, numbers and order of the templates. Do not add details or extra numbers. Return JSON with a translations array of translated strings." },
          { role: "user", content: JSON.stringify({ language, templates: replies.map((reply) => reply.template) }) },
        ],
      }),
      signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) return english();
    const translations = JSON.parse((await response.json()).choices?.[0]?.message?.content ?? "{}").translations;
    if (!Array.isArray(translations) || translations.length !== replies.length) return english();
    return replies.map((reply, i) =>
      render(reply, matchesTemplate(reply.template, translations[i]) ? translations[i] : reply.template)
    ).join(" ");
  } catch {
    return english();
  }
}
