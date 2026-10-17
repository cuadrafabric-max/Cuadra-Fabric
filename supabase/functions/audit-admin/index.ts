// POST /functions/v1/audit-admin
// Fulfillment operations for Cuadra Fabric staff.
// Auth: Authorization: Bearer <Supabase Auth user access token>. The user must have
// app_metadata.role = "admin" (app_metadata is server-controlled; user_metadata is not trusted).
//
// Actions:
//   { action: "list", status?: "paid" | "in_progress" | ..., limit?: 1-100 }
//   { action: "get", request_id }
//   { action: "transition", request_id, to_status, report_url?, note? }
//       to_status: in_progress | delivered | cancelled | refunded  (rules enforced in the DB)
//       "refunded" here only records state: issue the refund in Stripe; the
//       charge.refunded webhook also records it.

import { adminClient } from "../_shared/admin-client.ts";
import { corsHeaders, errorJson, json, readTextCapped } from "../_shared/http.ts";

const STATUSES = new Set(["awaiting_payment", "paid", "in_progress", "delivered", "cancelled", "refunded"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  const cors = corsHeaders(req);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return errorJson("method_not_allowed", "POST only", 405, cors);

  const token = req.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return errorJson("unauthorized", "Missing bearer token", 401, cors);

  const db = adminClient();
  const { data: userData, error: userErr } = await db.auth.getUser(token);
  if (userErr || !userData?.user) return errorJson("unauthorized", "Invalid or expired session", 401, cors);
  const user = userData.user;
  if (user.app_metadata?.role !== "admin") return errorJson("forbidden", "Admin role required", 403, cors);

  const raw = await readTextCapped(req, 16 * 1024);
  if (raw === null) return errorJson("payload_too_large", "Payload too large", 413, cors);
  let body: Record<string, unknown>;
  try {
    body = JSON.parse(raw);
  } catch {
    return errorJson("invalid_json", "Body must be JSON", 400, cors);
  }

  const action = body.action;

  if (action === "list") {
    const status = typeof body.status === "string" ? body.status : undefined;
    if (status && !STATUSES.has(status)) return errorJson("validation_error", "Unknown status", 422, cors);
    const limit = Math.min(Math.max(Number(body.limit ?? 50) || 50, 1), 100);
    let q = db.from("audit_requests")
      .select("id, reference, status, store_url, platform, paid_at, due_at, started_at, delivered_at, report_url, created_at, customer:audit_customers(email, full_name, company)")
      .order("due_at", { ascending: true, nullsFirst: false })
      .order("created_at", { ascending: false })
      .limit(limit);
    if (status) q = q.eq("status", status);
    const { data, error } = await q;
    if (error) return errorJson("internal_error", error.message, 500, cors);
    return json({ requests: data }, 200, cors);
  }

  const requestId = body.request_id;
  if (typeof requestId !== "string" || !UUID.test(requestId)) {
    return errorJson("validation_error", "request_id (uuid) is required", 422, cors);
  }

  if (action === "get") {
    const { data, error } = await db.from("audit_requests")
      .select("*, customer:audit_customers(*), payments:audit_payments(*), deliverables:audit_deliverables(*), events:audit_events(event_type, from_status, to_status, actor, detail, created_at)")
      .eq("id", requestId)
      .maybeSingle();
    if (error) return errorJson("internal_error", error.message, 500, cors);
    if (!data) return errorJson("not_found", "Audit request not found", 404, cors);
    return json({ request: data }, 200, cors);
  }

  if (action === "transition") {
    const to = body.to_status;
    if (typeof to !== "string" || !["in_progress", "delivered", "cancelled", "refunded"].includes(to)) {
      return errorJson("validation_error", "to_status must be in_progress, delivered, cancelled or refunded", 422, cors);
    }
    const reportUrl = typeof body.report_url === "string" ? body.report_url.trim() : null;
    if (to === "delivered" && (!reportUrl || !/^https:\/\//i.test(reportUrl))) {
      return errorJson("validation_error", "report_url (https) is required to deliver", 422, cors);
    }
    const note = typeof body.note === "string" ? body.note.slice(0, 5000) : null;

    const { data, error } = await db.rpc("audit_transition", {
      p_request_id: requestId,
      p_to_status: to,
      p_actor: `admin:${user.id}`,
      p_report_url: reportUrl,
      p_note: note,
    });
    if (error) {
      const status = error.code === "23514" ? 409 : error.code === "P0002" ? 404 : 500;
      return errorJson(status === 409 ? "invalid_transition" : status === 404 ? "not_found" : "internal_error",
        error.message, status, cors);
    }
    return json({ request: data }, 200, cors);
  }

  return errorJson("validation_error", "Unknown action", 422, cors);
});
