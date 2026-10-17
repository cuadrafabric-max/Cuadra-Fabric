import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.57.4";

// Server-side client. Prefers the new secret key (SUPABASE_SECRET_KEYS.default)
// and falls back to the legacy service_role key. Never sent to browsers.
export function adminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  let key: string | undefined;
  const secretKeys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (secretKeys) {
    try {
      key = JSON.parse(secretKeys)?.default;
    } catch {
      key = undefined;
    }
  }
  key ??= Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Supabase server credentials are not available");
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
