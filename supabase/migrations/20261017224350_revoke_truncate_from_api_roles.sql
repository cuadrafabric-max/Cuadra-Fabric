-- TRUNCATE bypasses Row Level Security. API roles never need it, REFERENCES, or TRIGGER.
-- Pre-existing grants found on public.variant_cogs_snapshots during the 2026-10-17 inspection.
-- No data or policy changes; existing select/insert/update/delete grants are left as they were.
revoke truncate, references, trigger on table public.variant_cogs_snapshots from anon, authenticated;
