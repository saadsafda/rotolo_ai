import { gmailMessage, handle } from "./index.ts";

const sender = "owner@example.com";
const approved = { to: "client@example.com", subject: "Friday’s update", body: "Hi,\nThe report is ready." };
const userId = "e5bb1a30-57a1-4e21-9d77-546189b362a5";
const id = "64239d76-3c6c-4397-b934-470d7d519cb8";
const env = new Map(Object.entries({
  SUPABASE_URL: "https://db.test",
  SUPABASE_ANON_KEY: "public",
  SUPABASE_SERVICE_ROLE_KEY: "secret",
  ROTOLO_EMAIL_FROM: sender,
  ROTOLO_EMAIL_GOOGLE_CLIENT_ID: "google",
  ROTOLO_EMAIL_GOOGLE_CLIENT_SECRET: "secret",
  ROTOLO_EMAIL_GOOGLE_REFRESH_TOKEN: "refresh",
}));

function assert(ok: unknown, description: string): asserts ok {
  if (!ok) throw new Error(description);
}
const request = (fields: Record<string, unknown> = {}) => new Request("https://app.test/send", {
  method: "POST",
  headers: { authorization: "Bearer owner-jwt" },
  body: JSON.stringify({ request_id: id, ...approved, ...fields }),
});
const fromBase64 = (raw: string) => new TextDecoder().decode(Uint8Array.from(atob(raw.replace(/-/g, "+").replace(/_/g, "/")), (char) => char.charCodeAt(0)));

function fixture(role = "owner", email = sender, gmailStatus = 200) {
  let mail = 0;
  let record: { status: string; fingerprint: string } | undefined;
  const http: typeof fetch = async (input, init) => {
    const url = String(input);
    const headers = new Headers(init?.headers);
    if (url.endsWith("/auth/v1/user")) return Response.json({ id: userId, email, email_confirmed_at: "2026-11-25" });
    if (url.includes("/profiles?")) {
      assert(headers.get("authorization") === "Bearer owner-jwt", "role checked with caller JWT");
      return Response.json([{ role }]);
    }
    if (url.includes("/assistant_email_attempts?")) {
      if (init?.method === "POST") {
        if (record) return Response.json([]);
        const saved = JSON.parse(String(init.body));
        assert(!JSON.stringify(saved).includes(approved.subject) && !("to" in saved) && !("body" in saved), "only the fingerprint is stored");
        record = { fingerprint: saved.fingerprint, status: "sending" };
      }
      if (record && init?.method === "PATCH") record.status = JSON.parse(String(init.body)).status;
      return Response.json(record ? [record] : []);
    }
    if (url === "https://oauth2.googleapis.com/token") return Response.json({ access_token: "fresh-token" });
    if (url === "https://gmail.googleapis.com/gmail/v1/users/owner%40example.com/messages/send") {
      mail++;
      assert(headers.get("authorization") === "Bearer fresh-token", "Gmail request authenticated");
      const raw = JSON.parse(String(init?.body)).raw;
      const [head, body] = fromBase64(raw).split("\r\n\r\n");
      assert(head.includes("To: " + approved.to), "message only goes to approved recipient");
      assert(fromBase64(body.replaceAll("\r\n", "")) === "Hi,\r\nThe report is ready.", "message body matches the review");
      return Response.json(gmailStatus === 200 ? { id: "gmail-id" } : {}, { status: gmailStatus });
    }
    throw new Error("Unexpected endpoint");
  };
  return { http, deliveries: () => mail };
}

Deno.test("MIME encoding preserves Unicode and keeps subject headers folded", () => {
  const mime = fromBase64(gmailMessage(sender, { ...approved, subject: "📬".repeat(30) }));
  const words = [...mime.matchAll(/=\?UTF-8\?B\?([A-Za-z0-9+/=]+)\?=/g)];
  assert(words.map((word) => fromBase64(word[1])).join("") === "📬".repeat(30), "subject round trip");
});

Deno.test("duplicate and concurrent requests deliver only once", async () => {
  const f = fixture();
  const results = await Promise.all([handle(request(), env, f.http), handle(request(), env, f.http)]);
  assert(results.some((result) => result.status === 200), "one successful send");
  const retry = await handle(request(), env, f.http);
  assert(retry.status === 200 && f.deliveries() === 1, "retry returns the stored outcome");
  assert((await handle(request({ subject: "Changed" }), env, f.http)).status === 409, "request ID bound to approved content");
});

Deno.test("staff, other mailboxes, and injected recipients cannot send", async () => {
  for (const f of [fixture("staff"), fixture("admin", "other@example.com")]) {
    assert((await handle(request(), env, f.http)).status === 403 && f.deliveries() === 0, "owner or admin with sender email only");
  }
  const f = fixture();
  assert((await handle(request({ to: "client@example.com\r\nBcc: someone@example.com" }), env, f.http)).status === 400, "one plain recipient");
  assert(f.deliveries() === 0, "invalid content never reaches Gmail");
});

Deno.test("an uncertain Gmail outcome is never retried automatically", async () => {
  const f = fixture("owner", sender, 503);
  const first = await handle(request(), env, f.http);
  const second = await handle(request(), env, f.http);
  assert(first.status === 409 && second.status === 409 && f.deliveries() === 1, "duplicate suppressed after an uncertain send");
});
