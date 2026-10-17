-- Lets stripe-webhook read its signing secret from Supabase Vault when the
-- STRIPE_WEBHOOK_SECRET Edge Function secret is not set.
-- The secret itself is stored out-of-band (never in a migration):
--   select vault.create_secret('<whsec_...>', 'stripe_webhook_secret', '<description>');
--
-- SECURITY DEFINER is required because vault.decrypted_secrets is not readable by
-- service_role. Exposure is limited: returns exactly one named secret, fixed
-- search_path, EXECUTE revoked from PUBLIC/anon/authenticated, granted to service_role only.
create function public.audit_stripe_webhook_secret()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select ds.decrypted_secret
    from vault.decrypted_secrets ds
   where ds.name = 'stripe_webhook_secret'
   limit 1;
$$;

revoke execute on function public.audit_stripe_webhook_secret() from public, anon, authenticated;
grant execute on function public.audit_stripe_webhook_secret() to service_role;
