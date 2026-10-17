-- Access-control regression test for the audit backend.
-- Run as postgres (SQL editor / MCP execute_sql). Read-only: every probe runs
-- under SET LOCAL ROLE and reports ALLOWED/DENIED; nothing is written.
-- For owner rows to be visible, link a test customer first:
--   update public.audit_customers set auth_user_id = '<test auth user id>' where email_normalized = '<test email>';
-- Expected (2026-10-17 run, 1 linked test customer with 1 request + 1 deliverable):
--   anon: every table and RPC                      DENIED (42501)
--   owner: audit_requests / customers / deliverables ALLOWED rows=own only
--   owner: payments, stripe_events, audit_events, UPDATE, RPCs  DENIED (42501)
--   other authenticated user: all three readable tables  ALLOWED rows=0

do $$
declare
  res text[] := '{}';
  n bigint;
  owner_claims text := '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
  other_claims text := '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';
  t record;
begin
  for t in select * from (values
    ('anon: select audit_requests',          'anon',          null,         'select count(*) from public.audit_requests'),
    ('anon: select audit_customers',         'anon',          null,         'select count(*) from public.audit_customers'),
    ('anon: insert audit_requests',          'anon',          null,         'insert into public.audit_requests(customer_id) values (gen_random_uuid()) returning 1'),
    ('anon: rpc audit_submit_intake',        'anon',          null,         'select count(*) from public.audit_submit_intake(''{"email":"x@y.zz"}'')'),
    ('anon: rpc audit_handle_stripe_event',  'anon',          null,         'select 1 from (select public.audit_handle_stripe_event(''{}'')) s'),
    ('owner: select own audit_requests',     'authenticated', owner_claims, 'select count(*) from public.audit_requests'),
    ('owner: select own audit_customers',    'authenticated', owner_claims, 'select count(*) from public.audit_customers'),
    ('owner: select own audit_deliverables', 'authenticated', owner_claims, 'select count(*) from public.audit_deliverables'),
    ('owner: select audit_payments',         'authenticated', owner_claims, 'select count(*) from public.audit_payments'),
    ('owner: select stripe_events',          'authenticated', owner_claims, 'select count(*) from public.stripe_events'),
    ('owner: select audit_events',           'authenticated', owner_claims, 'select count(*) from public.audit_events'),
    ('owner: update own request status',     'authenticated', owner_claims, 'with u as (update public.audit_requests set status=''paid'' returning 1) select count(*) from u'),
    ('owner: rpc audit_transition',          'authenticated', owner_claims, 'select 1 from (select public.audit_transition(gen_random_uuid(),''delivered'',''x'',''https://a.b'',null)) s'),
    ('other user: select audit_requests',    'authenticated', other_claims, 'select count(*) from public.audit_requests'),
    ('other user: select audit_customers',   'authenticated', other_claims, 'select count(*) from public.audit_customers'),
    ('other user: select audit_deliverables','authenticated', other_claims, 'select count(*) from public.audit_deliverables'),
    ('service_role: select audit_requests',  'service_role',  null,         'select count(*) from public.audit_requests')
  ) v(name, r, claims, q)
  loop
    begin
      perform set_config('request.jwt.claims', coalesce(t.claims, ''), true);
      execute format('set local role %I', t.r);
      execute t.q into n;
      res := res || format('%-42s ALLOWED rows=%s', t.name, n);
      execute 'reset role';
    exception when others then
      res := res || format('%-42s DENIED  (%s)', t.name, sqlstate);
    end;
  end loop;
  execute 'reset role';
  perform set_config('cf.rls_results', array_to_string(res, E'\n'), false);
end $$;
select current_setting('cf.rls_results') as results;
