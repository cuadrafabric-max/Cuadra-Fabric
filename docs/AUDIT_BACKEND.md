# Cuadra Fabric — $297 Audit Backend (Supabase)

**Production project:** `nwegjwhcjucnizhpziyu` (org "Cuadra Fabric", us-east-1, Postgres 17), confirmed 2026-10-17.
The `API` file in this repo references a different project (`byrezpasytccfzvexmxc`); it is **not** the audit backend.

## Flow

```
Base44 intake form ──POST──▶ audit-intake ──▶ audit_submit_intake()  → request: awaiting_payment
                                   └──▶ Stripe Checkout Session (client_reference_id = request id)
Buyer pays on Stripe ──webhook──▶ stripe-webhook (verifies Stripe-Signature)
                                   └──▶ audit_handle_stripe_event()  → paid, due_at = +5 business days (PT)
Staff ──POST (admin JWT)──▶ audit-admin ──▶ audit_transition()  → in_progress → delivered (report URL)
Stripe refund ──webhook──▶ charge.refunded → refunded
```

State machine (enforced by trigger on every UPDATE, including direct SQL):

| From | Allowed to |
|---|---|
| awaiting_payment | paid, cancelled |
| paid | in_progress, cancelled, refunded |
| in_progress | delivered (requires https report URL), refunded |
| delivered | in_progress (revision), refunded |
| cancelled, refunded | — (terminal) |

## Database objects (migration `20261017224348_audit_service_schema`)

| Table | Purpose | Who can read |
|---|---|---|
| `audit_customers` | buyer contact (PII) | service_role; owner via `auth_user_id` |
| `audit_requests` | one row per audit, status + deadlines | service_role; owner |
| `audit_payments` | Stripe session / payment intent / refunds | service_role only |
| `audit_deliverables` | versioned report links | service_role; owner |
| `stripe_events` | every Stripe event, PK = event id (idempotency) | service_role only |
| `audit_events` | append-only log of every transition and flag | service_role only |

RPCs (EXECUTE granted to `service_role` only; all `SECURITY INVOKER`):
`audit_submit_intake`, `audit_attach_checkout_session`, `audit_handle_stripe_event`, `audit_transition`.

Flags written to `audit_events` that need a human: `intake_missing` (paid via Payment Link with no form),
`payment_amount_mismatch` (request not marked paid), `payment_on_closed_request`, `payment_disputed`.
Failed Stripe events: `select * from stripe_events where status = 'failed'` — Stripe retries re-run them.

Migration `20261017224350_revoke_truncate_from_api_roles` removes TRUNCATE/REFERENCES/TRIGGER from
`anon`/`authenticated` on the pre-existing `variant_cogs_snapshots` (TRUNCATE bypasses RLS).

## Edge Functions (all `verify_jwt = false`; each authenticates in code)

| Function | URL | Auth |
|---|---|---|
| `audit-intake` | `https://nwegjwhcjucnizhpziyu.supabase.co/functions/v1/audit-intake` | public; CORS allowlist, honeypot `website`, 32 KB cap, validation |
| `stripe-webhook` | `https://nwegjwhcjucnizhpziyu.supabase.co/functions/v1/stripe-webhook` | Stripe-Signature HMAC, 5-min tolerance |
| `audit-admin` | `https://nwegjwhcjucnizhpziyu.supabase.co/functions/v1/audit-admin` | Supabase Auth user with `app_metadata.role = "admin"` |

### Intake request (from Base44)
```json
POST /functions/v1/audit-intake
{ "email": "owner@store.com", "store_url": "store.com", "full_name": "...", "company": "...",
  "platform": "shopify", "monthly_revenue_band": "$50k-$100k", "goals": "...",
  "intake": { "any": "extra answers" }, "idempotency_key": "<uuid generated once per form>", "website": "" }
→ 200 { request_id, reference: "CF-XXXXXXXX", status, checkout_url, created }  → redirect to checkout_url
```
Errors: 422 validation (`field` says which), 409 idempotency conflict, 403 origin, 503 checkout not configured.

### Admin
```json
{ "action": "list", "status": "paid" }
{ "action": "get", "request_id": "<uuid>" }
{ "action": "transition", "request_id": "<uuid>", "to_status": "in_progress" }
{ "action": "transition", "request_id": "<uuid>", "to_status": "delivered", "report_url": "https://...", "note": "v1" }
```
Grant admin (SQL editor): `update auth.users set raw_app_meta_data = raw_app_meta_data || '{"role":"admin"}' where email = '<staff email>';`

## Configuration still required

| Secret (Edge Functions → Secrets) | Value | Needed by |
|---|---|---|
| `STRIPE_SECRET_KEY` | `sk_live_...` (or `sk_test_...` first) | audit-intake |
| `STRIPE_WEBHOOK_SECRET` | `whsec_...` from the Stripe webhook endpoint | stripe-webhook |
| `STRIPE_AUDIT_PRICE_ID` *(optional)* | `price_...` for the $297 product; otherwise inline $297 USD | audit-intake |
| `AUDIT_SUCCESS_URL` / `AUDIT_CANCEL_URL` *(optional)* | Base44 pages; default `https://cuadra-audit-flow.base44.app/?checkout=...` | audit-intake |
| `ALLOWED_ORIGINS` *(optional)* | comma list; default Base44 app + cuadrafabric.com | intake, admin |
| `STRIPE_REQUIRE_LIVEMODE` *(optional)* | `true` once live, to ignore test events | stripe-webhook |

Stripe Dashboard → Developers → Webhooks → add endpoint `…/functions/v1/stripe-webhook` with events:
`checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`,
`checkout.session.expired`, `charge.refunded`, `charge.dispute.created`.

## Tests

* `node --experimental-strip-types --test supabase/functions/tests/stripe-signature.test.ts` — 9 signature tests.
* `supabase/tests/audit_rls_access.sql` — 17 role/RLS probes (read-only).

## Not built (deliberately)

* No Shopify webhooks: the audit is sold through Stripe, not Shopify checkout. The existing Shopify sync tables are untouched.
* No customer emails: sending customer communications needs an email provider and explicit approval.
* No customer login UI: RLS supports it (`audit_customers.auth_user_id`), linking is manual for now.
* No per-IP rate limiting on intake beyond CORS + honeypot.
