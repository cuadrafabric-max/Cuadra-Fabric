// POST /functions/v1/audit-intake
// Public intake endpoint for the $297 Ecommerce & Business Audit.
// Validates input, stores customer + request (idempotent), then returns the primary
// Stripe Payment Link with client_reference_id=<request id> (or, in checkout_session
// mode, an API-created Checkout Session tied to the request).
//
// Request JSON:
//   { email*, store_url*, full_name, company, phone, platform, monthly_revenue_band,
//     goals, intake: {...}, idempotency_key, website (honeypot: must be empty) }
// Response 200:
//   { request_id, reference, status, checkout_url | null, created }
//
// verify_jwt = false (anonymous buyers). Abuse controls: CORS allowlist, honeypot,
// size cap, strict validation. No data is readable back through this endpoint.

import { adminClient } from "../_shared/admin-client.ts";
import { corsHeaders, errorJson, json, readTextCapped } from "../_shared/http.ts";

const MAX_BODY_BYTES = 32 * 1024;
const PLATFORMS = new Set(["shopify", "woocommerce", "bigcommerce", "wix", "squarespace", "other"]);
const PRICE_CENTS = 29700;
const PRODUCT_NAME = "Cuadra Fabric 48-Hour E-Commerce Revenue & Automation Audit"; // checkout_session mode only

type Intake = {
  email: string;
  store_url: string;
  full_name?: string;
  company?: string;
  phone?: string;
  platform?: string;
  monthly_revenue_band?: string;
  goals?: string;
  intake?: Record<string, unknown>;
  idempotency_key?: string;
};

function str(v: unknown, max: number): string | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string") throw new Error("expected string");
  const s = v.trim();
  if (s.length > max) throw new Error(`exceeds ${max} characters`);
  return s.length ? s : undefined;
}

function validate(body: Record<string, unknown>): { ok: true; value: Intake } | { ok: false; field: string; message: string } {
  const fail = (field: string, message: string) => ({ ok: false as const, field, message });
  try {
    const email = str(body.email, 320);
    if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return fail("email", "A valid email is required");

    let store = str(body.store_url, 2048);
    if (!store) return fail("store_url", "Store URL is required");
    if (!/^https?:\/\//i.test(store)) store = `https://${store}`;
    let parsed: URL;
    try {
      parsed = new URL(store);
    } catch {
      return fail("store_url", "Store URL is not a valid URL");
    }
    if (!["http:", "https:"].includes(parsed.protocol) || !parsed.hostname.includes(".")) {
      return fail("store_url", "Store URL is not a valid URL");
    }

    const platform = str(body.platform, 30)?.toLowerCase();
    if (platform && !PLATFORMS.has(platform)) return fail("platform", `platform must be one of ${[...PLATFORMS].join(", ")}`);

    const key = str(body.idempotency_key, 128);
    if (key && (key.length < 8 || !/^[A-Za-z0-9_\-:.]+$/.test(key))) {
      return fail("idempotency_key", "idempotency_key must be 8-128 chars [A-Za-z0-9_-:.]");
    }

    const extra = body.intake;
    if (extra !== undefined && (typeof extra !== "object" || extra === null || Array.isArray(extra))) {
      return fail("intake", "intake must be an object");
    }

    return {
      ok: true,
      value: {
        email,
        store_url: parsed.toString(),
        full_name: str(body.full_name, 200),
        company: str(body.company, 200),
        phone: str(body.phone, 50),
        platform,
        monthly_revenue_band: str(body.monthly_revenue_band, 50),
        goals: str(body.goals, 5000),
        intake: (extra as Record<string, unknown>) ?? {},
        idempotency_key: key,
      },
    };
  } catch (e) {
    return fail("body", (e as Error).message);
  }
}

async function createCheckoutSession(requestId: string, reference: string, email: string): Promise<{ id: string; url: string }> {
  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY")!;
  const successUrl = Deno.env.get("AUDIT_SUCCESS_URL") ??
    "https://cuadra-audit-flow.base44.app/?checkout=success&ref={CHECKOUT_SESSION_ID}";
  const cancelUrl = Deno.env.get("AUDIT_CANCEL_URL") ?? "https://cuadra-audit-flow.base44.app/?checkout=cancelled";
  const priceId = Deno.env.get("STRIPE_AUDIT_PRICE_ID");

  const form = new URLSearchParams();
  form.set("mode", "payment");
  form.set("success_url", successUrl);
  form.set("cancel_url", cancelUrl);
  form.set("client_reference_id", requestId);
  form.set("customer_email", email);
  form.set("customer_creation", "always");
  form.set("metadata[audit_request_id]", requestId);
  form.set("metadata[audit_reference]", reference);
  form.set("payment_intent_data[metadata][audit_request_id]", requestId);
  form.set("payment_intent_data[description]", `${PRODUCT_NAME} ${reference}`);
  form.set("line_items[0][quantity]", "1");
  if (priceId) {
    form.set("line_items[0][price]", priceId);
  } else {
    form.set("line_items[0][price_data][currency]", "usd");
    form.set("line_items[0][price_data][unit_amount]", String(PRICE_CENTS));
    form.set("line_items[0][price_data][product_data][name]", PRODUCT_NAME);
  }

  const res = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${stripeKey}`,
      "Content-Type": "application/x-www-form-urlencoded",
      // Same request => same session for 24h, even if the client retries.
      "Idempotency-Key": `cf-audit-checkout-${requestId}`,
    },
    body: form,
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || typeof body?.id !== "string" || typeof body?.url !== "string") {
    throw new Error(`Stripe checkout error ${res.status}: ${body?.error?.type ?? "unknown"} ${body?.error?.code ?? ""}`.trim());
  }
  return { id: body.id, url: body.url };
}

Deno.serve(async (req) => {
  const cors = corsHeaders(req);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return errorJson("method_not_allowed", "POST only", 405, { ...cors, Allow: "POST, OPTIONS" });

  // Browsers from unknown origins are refused; server-to-server calls (no Origin) are allowed.
  const origin = req.headers.get("origin");
  if (origin && !cors["Access-Control-Allow-Origin"]) return errorJson("origin_not_allowed", "Origin not allowed", 403);

  const raw = await readTextCapped(req, MAX_BODY_BYTES);
  if (raw === null) return errorJson("payload_too_large", "Payload too large", 413, cors);

  let body: Record<string, unknown>;
  try {
    body = JSON.parse(raw);
    if (typeof body !== "object" || body === null || Array.isArray(body)) throw new Error();
  } catch {
    return errorJson("invalid_json", "Body must be a JSON object", 400, cors);
  }

  // Honeypot: real users never fill this hidden field. Pretend success, store nothing.
  if (typeof body.website === "string" && body.website.trim() !== "") {
    return json({ request_id: null, reference: null, status: "awaiting_payment", checkout_url: null, created: false }, 200, cors);
  }

  const v = validate(body);
  if (!v.ok) return json({ error: { code: "validation_error", field: v.field, message: v.message } }, 422, cors);

  const db = adminClient();
  const { data, error } = await db.rpc("audit_submit_intake", { p_intake: v.value });
  if (error) {
    if (error.code === "23505") {
      return errorJson("idempotency_conflict", "idempotency_key already used by another submission", 409, cors);
    }
    if (error.code === "23514") return errorJson("validation_error", "Submission failed validation", 422, cors);
    console.error(`audit-intake: rpc error ${error.code} ${error.message}`);
    return errorJson("internal_error", "Could not save your request", 500, cors);
  }

  const row = Array.isArray(data) ? data[0] : data;
  const result = {
    request_id: row.request_id as string,
    reference: row.reference as string,
    status: row.status as string,
    created: row.created as boolean,
    checkout_url: null as string | null,
  };

  if (result.status !== "awaiting_payment") return json(result, 200, cors); // already paid / closed

  // Default: the primary Stripe Payment Link (public/audit_offers). client_reference_id ties the
  // payment to this request; prefilled_email saves the buyer retyping it. No Stripe key needed.
  // Set AUDIT_CHECKOUT_MODE=checkout_session (+ STRIPE_SECRET_KEY) to create API Checkout Sessions instead.
  if (Deno.env.get("AUDIT_CHECKOUT_MODE") !== "checkout_session") {
    const { data: offer, error: offerErr } = await db.from("audit_offers")
      .select("payment_link_url").eq("is_primary", true).eq("active", true).maybeSingle();
    if (offerErr || !offer?.payment_link_url) {
      console.error(`audit-intake: no active primary audit offer (${offerErr?.code ?? "none"})`);
      return json({ ...result, error: { code: "payment_unavailable", message: "Checkout is not configured yet" } }, 503, cors);
    }
    const link = new URL(offer.payment_link_url);
    link.searchParams.set("client_reference_id", result.request_id);
    link.searchParams.set("prefilled_email", v.value.email);
    return json({ ...result, checkout_url: link.toString() }, 200, cors);
  }

  if (!Deno.env.get("STRIPE_SECRET_KEY")) {
    console.error("audit-intake: STRIPE_SECRET_KEY is not set; request stored without checkout");
    return json({ ...result, error: { code: "payment_unavailable", message: "Checkout is not configured yet" } }, 503, cors);
  }

  try {
    const session = await createCheckoutSession(result.request_id, result.reference, v.value.email);
    const { error: attachErr } = await db.rpc("audit_attach_checkout_session", {
      p_request_id: result.request_id,
      p_session_id: session.id,
    });
    if (attachErr) console.error(`audit-intake: attach session failed ${attachErr.code}`); // webhook still matches by client_reference_id
    return json({ ...result, checkout_url: session.url }, 200, cors);
  } catch (e) {
    console.error(`audit-intake: ${(e as Error).message}`);
    return json({ ...result, error: { code: "checkout_failed", message: "Could not start checkout" } }, 502, cors);
  }
});
