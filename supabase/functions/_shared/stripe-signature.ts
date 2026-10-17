// Stripe webhook signature verification (no SDK dependency).
// Spec: https://docs.stripe.com/webhooks#verify-manually
//   header  Stripe-Signature: t=<unix>,v1=<hex hmac>[,v1=...][,v0=...]
//   signed  `${t}.${rawBody}` with HMAC-SHA256 using the endpoint secret (whsec_...)

export type SignatureResult =
  | { ok: true; timestamp: number }
  | { ok: false; reason: "missing_header" | "malformed_header" | "timestamp_out_of_tolerance" | "no_matching_signature" };

const encoder = new TextEncoder();

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}

// Constant-time comparison of equal-length hex strings.
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function computeStripeSignature(secret: string, timestamp: number, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${payload}`));
  return toHex(sig);
}

export async function verifyStripeSignature(
  payload: string,
  header: string | null,
  secret: string,
  toleranceSeconds = 300,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): Promise<SignatureResult> {
  if (!header) return { ok: false, reason: "missing_header" };

  let timestamp: number | null = null;
  const v1: string[] = [];
  for (const part of header.split(",")) {
    const idx = part.indexOf("=");
    if (idx <= 0) continue;
    const k = part.slice(0, idx).trim();
    const v = part.slice(idx + 1).trim();
    if (k === "t" && /^\d{1,12}$/.test(v)) timestamp = Number(v);
    else if (k === "v1" && /^[0-9a-f]{64}$/i.test(v)) v1.push(v.toLowerCase());
  }
  if (timestamp === null || v1.length === 0) return { ok: false, reason: "malformed_header" };
  if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) {
    return { ok: false, reason: "timestamp_out_of_tolerance" };
  }

  const expected = await computeStripeSignature(secret, timestamp, payload);
  // Check every v1 (Stripe sends several during secret rotation) without early exit.
  let matched = false;
  for (const candidate of v1) matched = timingSafeEqual(candidate, expected) || matched;
  return matched ? { ok: true, timestamp } : { ok: false, reason: "no_matching_signature" };
}
