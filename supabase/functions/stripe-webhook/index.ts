// POST /functions/v1/stripe-webhook
// Receives Stripe events, verifies the Stripe-Signature header, then hands the
// event to public.audit_handle_stripe_event (atomic + idempotent per event id).
//
// Responses (Stripe retries any non-2xx):
//   200 processed | ignored | duplicate
//   400 bad / missing signature, malformed JSON        (do not retry — not ours)
//   413 payload too large
//   500 processing failed (event stored as failed; Stripe retry re-runs it)
//   503 STRIPE_WEBHOOK_SECRET not configured
// verify_jwt = false: Stripe sends no Supabase credentials; the signature is the auth.

import { verifyStripeSignature } from "../_shared/stripe-signature.ts";
import { adminClient } from "../_shared/admin-client.ts";
import { errorJson, json, readTextCapped } from "../_shared/http.ts";

const MAX_BODY_BYTES = 512 * 1024;

Deno.serve(async (req) => {
  if (req.method !== "POST") return errorJson("method_not_allowed", "POST only", 405, { Allow: "POST" });

  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) {
    console.error("stripe-webhook: STRIPE_WEBHOOK_SECRET is not set");
    return errorJson("not_configured", "Webhook secret not configured", 503);
  }

  const raw = await readTextCapped(req, MAX_BODY_BYTES);
  if (raw === null) return errorJson("payload_too_large", "Payload too large", 413);

  // Verify against the exact raw bytes before parsing anything.
  const check = await verifyStripeSignature(raw, req.headers.get("stripe-signature"), secret);
  if (!check.ok) {
    console.warn(`stripe-webhook: signature rejected (${check.reason})`);
    return errorJson("invalid_signature", "Signature verification failed", 400);
  }

  let event: { id?: string; type?: string; livemode?: boolean };
  try {
    event = JSON.parse(raw);
  } catch {
    return errorJson("invalid_json", "Body is not valid JSON", 400);
  }
  if (typeof event?.id !== "string" || !event.id.startsWith("evt_") || typeof event.type !== "string") {
    return errorJson("invalid_event", "Not a Stripe event", 400);
  }

  // Optional guard: reject test-mode events on a live deployment.
  if (Deno.env.get("STRIPE_REQUIRE_LIVEMODE") === "true" && event.livemode !== true) {
    console.warn(`stripe-webhook: test-mode event ${event.id} rejected (STRIPE_REQUIRE_LIVEMODE)`);
    return json({ received: true, result: "ignored", reason: "test_mode" });
  }

  try {
    const { data, error } = await adminClient().rpc("audit_handle_stripe_event", { p_event: JSON.parse(raw) });
    if (error) {
      console.error(`stripe-webhook: rpc error for ${event.id} (${event.type}): ${error.code} ${error.message}`);
      return errorJson("processing_error", "Event could not be processed", 500);
    }
    const result = (data as { result?: string })?.result;
    console.log(`stripe-webhook: ${event.id} ${event.type} -> ${result}`);
    if (result === "failed") return errorJson("processing_failed", "Event stored; processing failed", 500);
    return json({ received: true, result });
  } catch (e) {
    console.error(`stripe-webhook: unexpected error for ${event.id}: ${(e as Error).message}`);
    return errorJson("internal_error", "Internal error", 500);
  }
});
