# Cuadra Fabric — $297 Audit Backend (Supabase)

**Production project:** `nwegjwhcjucnizhpziyu` (org "Cuadra Fabric", us-east-1, Postgres 17), confirmed 2026-10-17.
The `API` file in this repo references a different project (`byrezpasytccfzvexmxc`); it is **not** the audit backend.

## Flow

```
Base44 intake form ──POST──▶ audit-intake ──▶ audit_submit_intake()  → request: awaiting_payment
                                   └──▶ returns primary Payment Link
                                        https://buy.stripe.com/14A14n07Q8mr9Owaf4bAs05
                                        ?client_reference_id=<request id>&prefilled_email=<email>
Buyer pays on Stripe ──webhook──▶ stripe-webhook (verifies Stripe-Signature)
                                   └──▶ audit_handle_stripe_event()  → paid, due_at = paid_at + 48 hours
Staff ──POST (admin JWT)──▶ audit-admin ──▶ audit_transition()  → in_progress → delivered (report URL)
Stripe refund ──webhook──▶ charge.refunded → refunded
```

Decisions (2026-10-17): primary offer = **48-Hour E-Commerce Revenue & Automation Audit**, $297;
deadline = **48 hours after payment** (the Base44 page still says "5 business days" — update its copy).

## Audit offers (migration `20261017231154_audit_offers_payment_links`)

`audit_offers` lists the Stripe Payment Links that sell the audit. Only checkouts from these links (or
carrying one of our request ids) create or update audit records; subscription checkouts (Foundation/Growth/
Scale) and other products on the same Stripe account are recorded in `stripe_events` as `ignored`.

| Payment link | Name | Primary |
|---|---|---|
| `plink_1URgevDLGXdSpZNAGJcC2tvd` — buy.stripe.com/14A14n07Q8mr9Owaf4bAs05 | 48-Hour E-Commerce Revenue & Automation Audit | ✓ |
| `plink_1URgdvDLGXdSpZNAfZHiKvLF` — buy.stripe.com/7sY5kD2fYdGLf8Q3QGbAs04 | $297 Storefront Audit | |
| `plink_1UKcrXDLGXdSpZNAPHjtXfQK` — buy.stripe.com/fZu9ATf2KgSX4uc5YObAs01 | $297 Storefront Audit (legacy) | |
| `plink_1UJtokDLGXdSpZNAzlc6vAbp` — buy.stripe.com/4gM8wPdYG46b7Go0EubAs00 | $297 Storefront Audit (legacy) | |

Automatic tax is enabled on the links, so the handler compares the **pre-tax subtotal** to the price and
stores total, subtotal and tax separately on `audit_payments`.
To change the primary link or turnaround: `update audit_offers set is_primary = …, turnaround = interval '…'`.

Stripe webhook endpoint (live, created 2026-10-17): `we_1URgxDDLGXdSpZNAuNwoSb8H` → `…/functions/v1/stripe-webhook`.

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
| `STRIPE_WEBHOOK_SECRET` **(required, not set yet)** | signing secret of endpoint `we_1URgxDDLGXdSpZNAuNwoSb8H` (Stripe → Webhooks → endpoint → Reveal) | stripe-webhook |
| `STRIPE_REQUIRE_LIVEMODE` *(optional)* | `true` to ignore test-mode events | stripe-webhook |
| `ALLOWED_ORIGINS` *(optional)* | comma list; default Base44 app + cuadrafabric.com | intake, admin |
| `AUDIT_CHECKOUT_MODE` *(optional)* | `checkout_session` to use API Checkout Sessions instead of the Payment Link | audit-intake |
| `STRIPE_SECRET_KEY`, `STRIPE_AUDIT_PRICE_ID`, `AUDIT_SUCCESS_URL`, `AUDIT_CANCEL_URL` | only for `checkout_session` mode | audit-intake |

The webhook endpoint already exists in Stripe with the six events: `checkout.session.completed`,
`checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`,
`checkout.session.expired`, `charge.refunded`, `charge.dispute.created`.

## Tests

* `node --experimental-strip-types --test supabase/functions/tests/stripe-signature.test.ts` — 9 signature tests.
* `supabase/tests/audit_rls_access.sql` — 17 role/RLS probes (read-only).

## Not built (deliberately)

* No Shopify webhooks: the audit is sold through Stripe, not Shopify checkout. The existing Shopify sync tables are untouched.
* No customer emails: sending customer communications needs an email provider and explicit approval.
* No customer login UI: RLS supports it (`audit_customers.auth_user_id`), linking is manual for now.
* No per-IP rate limiting on intake beyond CORS + honeypot.
