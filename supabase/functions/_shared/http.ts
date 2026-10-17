// Small HTTP helpers shared by the audit Edge Functions.

const DEFAULT_ORIGINS = [
  "https://cuadra-audit-flow.base44.app",
  "https://cuadrafabric.com",
  "https://www.cuadrafabric.com",
];

export function allowedOrigins(): string[] {
  const raw = Deno.env.get("ALLOWED_ORIGINS");
  if (!raw) return DEFAULT_ORIGINS;
  return raw.split(",").map((s) => s.trim()).filter(Boolean);
}

export function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin");
  const headers: Record<string, string> = {
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "600",
    "Vary": "Origin",
  };
  if (origin && allowedOrigins().includes(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

export function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...extra },
  });
}

export function errorJson(code: string, message: string, status: number, extra: Record<string, string> = {}) {
  return json({ error: { code, message } }, status, extra);
}

// Read a body with a hard size cap (protects against oversized payloads).
export async function readTextCapped(req: Request, maxBytes: number): Promise<string | null> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > maxBytes) return null;
  const buf = new Uint8Array(await req.arrayBuffer());
  if (buf.byteLength > maxBytes) return null;
  return new TextDecoder().decode(buf);
}
