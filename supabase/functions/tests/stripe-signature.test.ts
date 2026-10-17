// Run: node --experimental-strip-types --test supabase/functions/tests/stripe-signature.test.ts  (Node 22+)
//  or: deno test supabase/functions/tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import { computeStripeSignature, verifyStripeSignature } from "../_shared/stripe-signature.ts";

const SECRET = "whsec_test_secret_for_unit_tests_only";
const BODY = JSON.stringify({ id: "evt_test_1", type: "checkout.session.completed" });
const NOW = 1_760_000_000;

async function header(ts: number, body = BODY, secret = SECRET) {
  return `t=${ts},v1=${await computeStripeSignature(secret, ts, body)}`;
}

test("accepts a valid signature", async () => {
  const r = await verifyStripeSignature(BODY, await header(NOW), SECRET, 300, NOW);
  assert.deepEqual(r, { ok: true, timestamp: NOW });
});

test("matches Stripe's documented HMAC construction (independent node:crypto)", async () => {
  const { createHmac } = await import("node:crypto");
  const expected = createHmac("sha256", SECRET).update(`${NOW}.${BODY}`).digest("hex");
  assert.equal(await computeStripeSignature(SECRET, NOW, BODY), expected);
});

test("rejects a missing header", async () => {
  assert.equal((await verifyStripeSignature(BODY, null, SECRET, 300, NOW)).ok, false);
});

test("rejects a malformed header", async () => {
  const r = await verifyStripeSignature(BODY, "garbage", SECRET, 300, NOW);
  assert.deepEqual(r, { ok: false, reason: "malformed_header" });
});

test("rejects a signature made with the wrong secret", async () => {
  const r = await verifyStripeSignature(BODY, await header(NOW, BODY, "whsec_other"), SECRET, 300, NOW);
  assert.deepEqual(r, { ok: false, reason: "no_matching_signature" });
});

test("rejects a tampered body", async () => {
  const r = await verifyStripeSignature(BODY.replace("evt_test_1", "evt_test_2"), await header(NOW), SECRET, 300, NOW);
  assert.deepEqual(r, { ok: false, reason: "no_matching_signature" });
});

test("rejects a replayed (stale) timestamp", async () => {
  const r = await verifyStripeSignature(BODY, await header(NOW - 301), SECRET, 300, NOW);
  assert.deepEqual(r, { ok: false, reason: "timestamp_out_of_tolerance" });
});

test("accepts when any of several v1 signatures matches (secret rotation)", async () => {
  const good = await computeStripeSignature(SECRET, NOW, BODY);
  const bad = "0".repeat(64);
  const r = await verifyStripeSignature(BODY, `t=${NOW},v1=${bad},v1=${good}`, SECRET, 300, NOW);
  assert.equal(r.ok, true);
});

test("ignores v0 (test-mode legacy) signatures", async () => {
  const good = await computeStripeSignature(SECRET, NOW, BODY);
  const r = await verifyStripeSignature(BODY, `t=${NOW},v0=${good}`, SECRET, 300, NOW);
  assert.deepEqual(r, { ok: false, reason: "malformed_header" });
});
