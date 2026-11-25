const address = /^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+$/;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => Response.json(body, { status, headers: cors });
const error = (code: string, status: number) => json({ error: code }, status);
type Env = { get(name: string): string | undefined };
type Email = { to: string; subject: string; body: string };
const utf8 = new TextEncoder();
const base64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));

export function gmailMessage(from: string, email: Email): string {
  const subjectWords: string[] = [];
  const letters = [...email.subject];
  for (let start = 0; start < letters.length; start += 10) {
    subjectWords.push(`=?UTF-8?B?${base64(utf8.encode(letters.slice(start, start + 10).join("")))}?=`);
  }
  const body = base64(utf8.encode(email.body.replace(/\r\n?|\n/g, "\r\n"))).match(/.{1,76}/g) ?? [];
  const message = [
    `From: ${from}`,
    `To: ${email.to}`,
    `Subject: ${subjectWords.join("\r\n ")}`,
    "MIME-Version: 1.0",
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: base64",
    "",
    ...body,
    "",
  ].join("\r\n");
  return base64(utf8.encode(message)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function handle(req: Request, env: Env = Deno.env, fetcher: typeof fetch = fetch): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return error("method_not_allowed", 405);
  const authorization = req.headers.get("authorization") ?? "";
  if (!/^Bearer \S+$/.test(authorization)) return error("sign_in_required", 401);
  const url = env.get("SUPABASE_URL");
  const anon = env.get("SUPABASE_ANON_KEY");
  const service = env.get("SUPABASE_SERVICE_ROLE_KEY");
  const sender = env.get("ROTOLO_EMAIL_FROM")?.toLowerCase();
  const clientId = env.get("ROTOLO_EMAIL_GOOGLE_CLIENT_ID");
  const clientSecret = env.get("ROTOLO_EMAIL_GOOGLE_CLIENT_SECRET");
  const refreshToken = env.get("ROTOLO_EMAIL_GOOGLE_REFRESH_TOKEN");
  if (!url || !anon || !service || !sender || !address.test(sender) || !clientId || !clientSecret || !refreshToken) {
    return error("mail_not_connected", 503);
  }

  const userHeaders = { authorization, apikey: anon };
  const serviceHeaders = { authorization: "Bearer " + service, apikey: service, "content-type": "application/json" };
  const http = (endpoint: string, init?: RequestInit) => fetcher(endpoint, { ...init, signal: AbortSignal.timeout(15_000) });
  const table = url + "/rest/v1/assistant_email_attempts";
  const signedIn = await http(url + "/auth/v1/user", { headers: userHeaders }).catch(() => null);
  if (!signedIn?.ok) return error("sign_in_required", 401);
  const user = await signedIn.json();
  if (user.email?.toLowerCase() !== sender || !user.email_confirmed_at || !uuid.test(user.id)) return error("forbidden", 403);
  const profile = await http(url + `/rest/v1/profiles?select=role&id=eq.${user.id}&active=eq.true`, { headers: userHeaders }).catch(() => null);
  if (!profile?.ok || !["owner", "admin"].includes((await profile.json())[0]?.role)) return error("forbidden", 403);

  const input = await req.json().catch(() => null);
  const requestId = input?.request_id;
  const to = typeof input?.to === "string" ? input.to.trim() : "";
  const subject = typeof input?.subject === "string" ? input.subject.trim() : "";
  const body = typeof input?.body === "string" ? input.body.trim() : "";
  if (typeof requestId !== "string" || !uuid.test(requestId) || to.length > 254 || !address.test(to) ||
      !subject || subject.length > 120 || /[\r\n]/.test(subject) || !body || body.length > 10000) {
    return error("invalid_email", 400);
  }
  const email: Email = { to, subject, body };
  // Include the server secret in the fingerprint so it cannot be used to guess email text from a database export.
  const key = await crypto.subtle.importKey("raw", utf8.encode(service), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, utf8.encode(JSON.stringify(email)));
  const fingerprint = base64(new Uint8Array(signature));
  const selector = `user_id=eq.${user.id}&request_id=eq.${requestId}`;
  const sent = () => json({ status: "sent" });
  const previousAttempt = async () => {
    const response = await http(`${table}?select=fingerprint,status&${selector}`, { headers: serviceHeaders });
    if (!response.ok) throw Error("Could not read attempt");
    const row = (await response.json())[0];
    if (!row) return null;
    if (row.fingerprint !== fingerprint) return error("request_changed", 409);
    if (row.status === "sent") return sent();
    if (row.status === "rejected") return error("mail_rejected", 502);
    return error("send_unconfirmed", 409);
  };
  try {
    const previous = await previousAttempt();
    if (previous) return previous;
    const token = await http("https://oauth2.googleapis.com/token", {
      method: "POST",
      body: new URLSearchParams({
        grant_type: "refresh_token", client_id: clientId, client_secret: clientSecret, refresh_token: refreshToken,
      }),
    }).catch(() => null);
    const accessToken = token?.ok ? (await token.json()).access_token : null;
    if (typeof accessToken !== "string" || !accessToken) return error("mail_not_connected", 503);
    const claim = await http(table + "?on_conflict=user_id,request_id", {
      method: "POST",
      headers: { ...serviceHeaders, prefer: "resolution=ignore-duplicates,return=representation" },
      body: JSON.stringify({ user_id: user.id, request_id: requestId, fingerprint }),
    });
    if (!claim.ok) return error("mail_unavailable", 503);
    if (!(await claim.json()).length) return (await previousAttempt()) ?? error("send_unconfirmed", 409);

    const gmail = await http(`https://gmail.googleapis.com/gmail/v1/users/${encodeURIComponent(sender)}/messages/send`, {
      method: "POST",
      headers: { authorization: "Bearer " + accessToken, "content-type": "application/json" },
      body: JSON.stringify({ raw: gmailMessage(sender, email) }),
    }).catch(() => null);
    const gmailId = gmail?.ok ? (await gmail.json().catch(() => null))?.id : null;
    const rejected = gmail && gmail.status >= 400 && gmail.status < 500;
    const status = gmailId ? "sent" : rejected ? "rejected" : "unknown";
    // Retain the claim if this update fails. Never call Gmail again for the same request.
    await http(`${table}?${selector}`, {
      method: "PATCH",
      headers: serviceHeaders,
      body: JSON.stringify({ status }),
    }).catch(() => null);
    if (gmailId) return sent();
    return rejected ? error("mail_rejected", 502) : error("send_unconfirmed", 409);
  } catch {
    return error("send_unconfirmed", 409);
  }
}

if (import.meta.main) Deno.serve((req) => handle(req));
