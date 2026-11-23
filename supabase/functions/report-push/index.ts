const scope = "https://www.googleapis.com/auth/firebase.messaging";
const tokenEndpoint = "https://oauth2.googleapis.com/token";
const firebaseProject = "rotolo-operations";

function encode(value: string | Uint8Array): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function accessToken(serviceAccount: string): Promise<string> {
  const account = JSON.parse(serviceAccount);
  if (account.project_id !== firebaseProject) throw new Error("Unexpected Firebase project");
  const privateKey = Uint8Array.from(
    atob(account.private_key.replace(/-----[^-]+-----|\s/g, "")),
    (value) => value.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8", privateKey, {name: "RSASSA-PKCS1-v1_5", hash: "SHA-256"}, false, ["sign"],
  );
  const now = Math.floor(Date.now() / 1000);
  const assertion = [
    encode(JSON.stringify({alg: "RS256", typ: "JWT"})),
    encode(JSON.stringify({iss: account.client_email, scope, aud: tokenEndpoint, iat: now, exp: now + 600})),
  ].join(".");
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(assertion));
  const response = await fetch(tokenEndpoint, {
    method: "POST",
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: assertion + "." + encode(new Uint8Array(signature)),
    }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("Firebase authorization failed");
  return (await response.json()).access_token;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, {status: 405});
  const secret = request.headers.get("x-ingest-secret");
  if (!secret || secret.length < 32) return new Response(null, {status: 401});

  try {
    const {report_id} = await request.json();
    if (typeof report_id !== "string" || !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(report_id)) {
      return new Response(null, {status: 400});
    }
    const account = Deno.env.get("ROTOLO_FCM_SERVICE_ACCOUNT");
    const url = Deno.env.get("SUPABASE_URL");
    const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!account || !url || !serviceRole) return new Response(null, {status: 503});

    // The database checks the shared worker secret and claims only eligible
    // live reports. Generic notification text contains no report contents.
    const response = await fetch(url + "/rest/v1/rpc/n8n_claim_report_push", {
      method: "POST",
      headers: {"content-type": "application/json", apikey: serviceRole, authorization: "Bearer " + serviceRole, "x-ingest-secret": secret},
      body: JSON.stringify({p_report_id: report_id}),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) return new Response(null, {status: response.status === 401 || response.status === 403 ? 401 : 502});
    const recipients: {token: string}[] = await response.json();
    if (!recipients.length) return Response.json({accepted: 0, rejected: 0});

    const authorization = "Bearer " + await accessToken(account);
    let accepted = 0;
    let rejected = 0;
    const failureCodes: Record<string, number> = {};
    for (let start = 0; start < recipients.length; start += 16) {
      const batch = await Promise.allSettled(recipients.slice(start, start + 16).map(({token}) =>
        fetch("https://fcm.googleapis.com/v1/projects/" + firebaseProject + "/messages:send", {
          method: "POST",
          headers: {authorization, "content-type": "application/json"},
          body: JSON.stringify({message: {
            token,
            notification: {title: "Daily operations report ready", body: "Tap to open Rotolo."},
            data: {type: "report_ready", report_id},
          }}),
          signal: AbortSignal.timeout(10_000),
        })));
      for (const result of batch) {
        if (result.status === "fulfilled" && result.value.ok) {
          accepted++;
          await result.value.body?.cancel();
          continue;
        }
        rejected++;
        let code = "TRANSPORT_ERROR";
        if (result.status === "fulfilled") {
          const error = (await result.value.json().catch(() => null))?.error;
          const firebaseCode = error?.details?.find((detail: Record<string, unknown>) =>
            detail["@type"] === "type.googleapis.com/google.firebase.fcm.v1.FcmError"
          )?.errorCode ?? error?.status;
          code = typeof firebaseCode === "string" && /^[A-Z_0-9]{1,48}$/.test(firebaseCode)
            ? firebaseCode
            : "HTTP_" + result.value.status;
        }
        failureCodes[code] = (failureCodes[code] ?? 0) + 1;
      }
    }
    console.info("Rotolo push delivery", JSON.stringify({accepted, rejected, failureCodes}));
    return Response.json({accepted, rejected, failureCodes});
  } catch (_) {
    return new Response("Report notification delivery failed", {status: 502});
  }
});
