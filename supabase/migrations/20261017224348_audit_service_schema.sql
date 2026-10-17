-- Cuadra Fabric — $297 Ecommerce & Business Audit backend
-- Additive only: creates new objects, touches no existing table.
--
-- Access model
--   service_role  : Edge Functions (intake, stripe-webhook, audit-admin). Full access.
--   authenticated : a customer whose auth user is linked to audit_customers.auth_user_id
--                   may SELECT their own customer row, requests and deliverables. Nothing else.
--   anon          : no access to any table or function in this migration.

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type public.audit_status as enum (
  'awaiting_payment',  -- intake received, not paid
  'paid',              -- payment confirmed by a verified Stripe webhook
  'in_progress',       -- analyst working
  'delivered',         -- report delivered
  'cancelled',         -- abandoned / cancelled before work
  'refunded'           -- fully refunded
);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- N business days (Mon–Fri) after a timestamp, evaluated in Pacific time.
create function public.audit_add_business_days(p_start timestamptz, p_days integer)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  v_local timestamp := p_start at time zone 'America/Los_Angeles';
  v_added integer := 0;
begin
  if p_days < 0 then
    raise exception 'p_days must be >= 0';
  end if;
  while v_added < p_days loop
    v_local := v_local + interval '1 day';
    if extract(isodow from v_local) < 6 then
      v_added := v_added + 1;
    end if;
  end loop;
  return v_local at time zone 'America/Los_Angeles';
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.audit_customers (
  id                   uuid primary key default gen_random_uuid(),
  email                text not null
                         check (length(email) <= 320 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  email_normalized     text generated always as (lower(btrim(email))) stored,
  full_name            text check (length(full_name) <= 200),
  company              text check (length(company) <= 200),
  phone                text check (length(phone) <= 50),
  auth_user_id         uuid references auth.users (id) on delete set null,
  stripe_customer_id   text check (stripe_customer_id ~ '^cus_'),
  shopify_customer_gid text check (length(shopify_customer_gid) <= 200),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint audit_customers_email_normalized_key unique (email_normalized),
  constraint audit_customers_auth_user_id_key     unique (auth_user_id),
  constraint audit_customers_stripe_customer_key  unique (stripe_customer_id)
);
comment on table public.audit_customers is 'Buyers of the $297 audit. Contains PII: service_role only, plus owner read via auth_user_id.';

create table public.audit_requests (
  id                          uuid primary key default gen_random_uuid(),
  reference                   text not null
                                default 'CF-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  customer_id                 uuid not null references public.audit_customers (id) on delete restrict,
  status                      public.audit_status not null default 'awaiting_payment',
  store_url                   text check (length(store_url) <= 2048 and store_url ~* '^https?://[^\s/$.?#][^\s]*$'),
  platform                    text check (platform in ('shopify','woocommerce','bigcommerce','wix','squarespace','other')),
  monthly_revenue_band        text check (length(monthly_revenue_band) <= 50),
  goals                       text check (length(goals) <= 5000),
  intake                      jsonb not null default '{}'::jsonb
                                check (jsonb_typeof(intake) = 'object' and pg_column_size(intake) <= 32768),
  source                      text not null default 'web'
                                check (source in ('web','stripe_payment_link','admin')),
  idempotency_key             text check (length(idempotency_key) between 8 and 128),
  price_cents                 integer not null default 29700 check (price_cents > 0),
  currency                    text not null default 'usd' check (currency ~ '^[a-z]{3}$'),
  stripe_checkout_session_id  text check (stripe_checkout_session_id ~ '^cs_'),
  paid_at                     timestamptz,
  due_at                      timestamptz,
  started_at                  timestamptz,
  delivered_at                timestamptz,
  cancelled_at                timestamptz,
  refunded_at                 timestamptz,
  report_url                  text check (report_url ~* '^https://'),
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  constraint audit_requests_reference_key        unique (reference),
  constraint audit_requests_idempotency_key_key  unique (idempotency_key),
  constraint audit_requests_checkout_session_key unique (stripe_checkout_session_id),
  constraint audit_requests_paid_has_paid_at
    check (status not in ('paid','in_progress','delivered') or paid_at is not null),
  constraint audit_requests_work_needs_store
    check (status not in ('in_progress','delivered') or store_url is not null),
  constraint audit_requests_delivered_has_report
    check (status <> 'delivered' or (delivered_at is not null and report_url is not null))
);
create index audit_requests_customer_id_idx on public.audit_requests (customer_id);
-- Ops queue: open work ordered by deadline.
create index audit_requests_open_due_idx on public.audit_requests (due_at)
  where status in ('paid','in_progress');
create index audit_requests_created_at_idx on public.audit_requests (created_at desc);

create table public.audit_payments (
  id                          uuid primary key default gen_random_uuid(),
  audit_request_id            uuid not null references public.audit_requests (id) on delete restrict,
  stripe_checkout_session_id  text check (stripe_checkout_session_id ~ '^cs_'),
  stripe_payment_intent_id    text check (stripe_payment_intent_id ~ '^pi_'),
  amount_cents                integer not null check (amount_cents >= 0),
  amount_refunded_cents       integer not null default 0 check (amount_refunded_cents >= 0),
  currency                    text not null check (currency ~ '^[a-z]{3}$'),
  status                      text not null
                                check (status in ('pending','succeeded','failed','partially_refunded','refunded','disputed')),
  livemode                    boolean not null,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  constraint audit_payments_session_key        unique (stripe_checkout_session_id),
  constraint audit_payments_payment_intent_key unique (stripe_payment_intent_id),
  constraint audit_payments_refund_le_amount   check (amount_refunded_cents <= amount_cents)
);
create index audit_payments_audit_request_id_idx on public.audit_payments (audit_request_id);

create table public.audit_deliverables (
  id                uuid primary key default gen_random_uuid(),
  audit_request_id  uuid not null references public.audit_requests (id) on delete cascade,
  kind              text not null default 'report' check (kind in ('report','action_plan','video','other')),
  version           integer not null default 1 check (version > 0),
  url               text not null check (url ~* '^https://' and length(url) <= 2048),
  notes             text check (length(notes) <= 5000),
  delivered_by      uuid references auth.users (id) on delete set null,
  created_at        timestamptz not null default now(),
  constraint audit_deliverables_request_kind_version_key unique (audit_request_id, kind, version)
);
create index audit_deliverables_delivered_by_idx on public.audit_deliverables (delivered_by);

-- One row per Stripe event id: the primary key is the idempotency guard.
create table public.stripe_events (
  id                 text primary key check (id ~ '^evt_'),
  type               text not null,
  livemode           boolean not null,
  api_version        text,
  stripe_created_at  timestamptz,
  status             text not null default 'processing'
                       check (status in ('processing','processed','ignored','failed')),
  attempts           integer not null default 1 check (attempts > 0),
  error              text,
  audit_request_id   uuid references public.audit_requests (id) on delete set null,
  payload            jsonb not null,
  received_at        timestamptz not null default now(),
  processed_at       timestamptz,
  updated_at         timestamptz not null default now()
);
create index stripe_events_audit_request_id_idx on public.stripe_events (audit_request_id);
create index stripe_events_failed_idx on public.stripe_events (received_at) where status = 'failed';

-- Append-only operational log for every request.
create table public.audit_events (
  id                bigint generated always as identity primary key,
  audit_request_id  uuid not null references public.audit_requests (id) on delete cascade,
  event_type        text not null check (length(event_type) <= 100),
  from_status       public.audit_status,
  to_status         public.audit_status,
  actor             text not null check (length(actor) <= 100),
  detail            jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now()
);
create index audit_events_request_created_idx on public.audit_events (audit_request_id, created_at);

-- ---------------------------------------------------------------------------
-- updated_at triggers (reuse existing public.set_updated_at)
-- ---------------------------------------------------------------------------
create trigger audit_customers_updated_at before update on public.audit_customers
  for each row execute function public.set_updated_at();
create trigger audit_requests_updated_at before update on public.audit_requests
  for each row execute function public.set_updated_at();
create trigger audit_payments_updated_at before update on public.audit_payments
  for each row execute function public.set_updated_at();
create trigger stripe_events_updated_at before update on public.stripe_events
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- State machine: every status change is validated, timestamped and logged.
-- ---------------------------------------------------------------------------
create function public.audit_request_status_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_allowed public.audit_status[];
  v_actor text := coalesce(nullif(current_setting('cuadra.actor', true), ''), 'system');
begin
  if tg_op = 'INSERT' then
    if new.status not in ('awaiting_payment', 'paid') then
      raise exception 'audit_requests must be created as awaiting_payment or paid, got %', new.status
        using errcode = 'check_violation';
    end if;
    if new.status = 'paid' then
      new.paid_at := coalesce(new.paid_at, now());
      new.due_at  := coalesce(new.due_at, public.audit_add_business_days(new.paid_at, 5));
    end if;
    return new;
  end if;

  if new.status is not distinct from old.status then
    return new;
  end if;

  v_allowed := case old.status
    when 'awaiting_payment' then array['paid','cancelled']::public.audit_status[]
    when 'paid'             then array['in_progress','cancelled','refunded']::public.audit_status[]
    when 'in_progress'      then array['delivered','refunded']::public.audit_status[]
    when 'delivered'        then array['in_progress','refunded']::public.audit_status[]  -- in_progress = revision
    else array[]::public.audit_status[]                                                  -- cancelled, refunded are terminal
  end;

  if not (new.status = any (v_allowed)) then
    raise exception 'invalid audit status transition % -> %', old.status, new.status
      using errcode = 'check_violation';
  end if;

  case new.status
    when 'paid' then
      new.paid_at := coalesce(new.paid_at, now());
      new.due_at  := coalesce(new.due_at, public.audit_add_business_days(new.paid_at, 5));
    when 'in_progress' then new.started_at   := coalesce(new.started_at, now());
    when 'delivered'   then new.delivered_at := now();
    when 'cancelled'   then new.cancelled_at := now();
    when 'refunded'    then new.refunded_at  := now();
    else null;
  end case;

  insert into public.audit_events (audit_request_id, event_type, from_status, to_status, actor)
  values (new.id, 'status_changed', old.status, new.status, v_actor);

  return new;
end;
$$;

create function public.audit_request_created_log()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into public.audit_events (audit_request_id, event_type, to_status, actor, detail)
  values (new.id, 'created', new.status,
          coalesce(nullif(current_setting('cuadra.actor', true), ''), 'system'),
          jsonb_build_object('source', new.source));
  return null;
end;
$$;

create trigger audit_requests_status_guard
  before insert or update of status on public.audit_requests
  for each row execute function public.audit_request_status_guard();
create trigger audit_requests_created_log
  after insert on public.audit_requests
  for each row execute function public.audit_request_created_log();

-- ---------------------------------------------------------------------------
-- RPC: intake (called by the audit-intake Edge Function with the secret key)
-- ---------------------------------------------------------------------------
create function public.audit_submit_intake(p_intake jsonb)
returns table (request_id uuid, reference text, status public.audit_status, created boolean)
language plpgsql
set search_path = ''
as $$
declare
  v_email     text := btrim(p_intake ->> 'email');
  v_key       text := nullif(btrim(p_intake ->> 'idempotency_key'), '');
  v_customer  uuid;
  v_existing  record;
begin
  if v_email is null or v_email = '' then
    raise exception 'email is required' using errcode = 'check_violation';
  end if;

  perform set_config('cuadra.actor', 'customer', true);

  -- Idempotent replay: same key returns the same request (only for the same email).
  if v_key is not null then
    select r.id, r.reference, r.status, c.email_normalized
      into v_existing
      from public.audit_requests r
      join public.audit_customers c on c.id = r.customer_id
     where r.idempotency_key = v_key;
    if found then
      if v_existing.email_normalized <> lower(v_email) then
        raise exception 'idempotency_key already used' using errcode = 'unique_violation';
      end if;
      return query select v_existing.id, v_existing.reference, v_existing.status, false;
      return;
    end if;
  end if;

  -- Upsert customer. Anonymous intake may only fill blank fields, never overwrite.
  insert into public.audit_customers as c (email, full_name, company, phone)
  values (v_email,
          nullif(btrim(p_intake ->> 'full_name'), ''),
          nullif(btrim(p_intake ->> 'company'), ''),
          nullif(btrim(p_intake ->> 'phone'), ''))
  on conflict (email_normalized) do update
     set full_name = coalesce(c.full_name, excluded.full_name),
         company   = coalesce(c.company,   excluded.company),
         phone     = coalesce(c.phone,     excluded.phone)
  returning c.id into v_customer;

  return query
  insert into public.audit_requests as r
    (customer_id, store_url, platform, monthly_revenue_band, goals, intake, idempotency_key, source)
  values (v_customer,
          nullif(btrim(p_intake ->> 'store_url'), ''),
          nullif(lower(btrim(p_intake ->> 'platform')), ''),
          nullif(btrim(p_intake ->> 'monthly_revenue_band'), ''),
          nullif(btrim(p_intake ->> 'goals'), ''),
          coalesce(p_intake -> 'intake', '{}'::jsonb),
          v_key,
          'web')
  returning r.id, r.reference, r.status, true;
end;
$$;

create function public.audit_attach_checkout_session(p_request_id uuid, p_session_id text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update public.audit_requests
     set stripe_checkout_session_id = p_session_id
   where id = p_request_id
     and status = 'awaiting_payment'
     and (stripe_checkout_session_id is null or stripe_checkout_session_id = p_session_id);

  insert into public.audit_events (audit_request_id, event_type, actor, detail)
  values (p_request_id, 'checkout_session_created', 'system', jsonb_build_object('session_id', p_session_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: Stripe event processing. Called only after the Edge Function has
-- verified the Stripe-Signature header. Atomic and idempotent per event id.
-- Returns {result: processed|ignored|duplicate|failed, ...}
-- ---------------------------------------------------------------------------
create function public.audit_handle_stripe_event(p_event jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id        text := p_event ->> 'id';
  v_type      text := p_event ->> 'type';
  v_obj       jsonb := p_event -> 'data' -> 'object';
  v_live      boolean := coalesce((p_event ->> 'livemode')::boolean, false);
  v_prior     record;
  v_req       public.audit_requests%rowtype;
  v_req_id    uuid;
  v_customer  uuid;
  v_email     text;
  v_ref       text;
  v_amount    integer;
  v_currency  text;
  v_pi        text;
  v_note      text;
  v_result    text := 'processed';
begin
  if v_id is null or v_id !~ '^evt_' or v_type is null or v_obj is null then
    raise exception 'malformed Stripe event' using errcode = 'check_violation';
  end if;

  perform set_config('cuadra.actor', 'stripe', true);

  -- Idempotency gate. A concurrent duplicate blocks here until the first commits.
  insert into public.stripe_events (id, type, livemode, api_version, stripe_created_at, payload)
  values (v_id, v_type, v_live, p_event ->> 'api_version',
          to_timestamp((p_event ->> 'created')::bigint), p_event)
  on conflict (id) do nothing;

  if not found then
    select se.status, se.audit_request_id into v_prior
      from public.stripe_events se where se.id = v_id for update;
    if v_prior.status in ('processed', 'ignored') then
      return jsonb_build_object('result', 'duplicate', 'event_id', v_id,
                                'audit_request_id', v_prior.audit_request_id);
    end if;
    update public.stripe_events
       set attempts = attempts + 1, status = 'processing', error = null
     where id = v_id;
  end if;

  begin
    if v_type in ('checkout.session.completed', 'checkout.session.async_payment_succeeded',
                  'checkout.session.async_payment_failed', 'checkout.session.expired') then

      v_email    := lower(btrim(coalesce(v_obj -> 'customer_details' ->> 'email', v_obj ->> 'customer_email')));
      v_ref      := coalesce(v_obj ->> 'client_reference_id', v_obj -> 'metadata' ->> 'audit_request_id');
      v_amount   := (v_obj ->> 'amount_total')::integer;
      v_currency := lower(v_obj ->> 'currency');
      v_pi       := v_obj ->> 'payment_intent';

      -- 1) explicit reference set by audit-intake  2) known session  3) open intake by email
      if v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        select * into v_req from public.audit_requests where id = v_ref::uuid for update;
      end if;
      if v_req.id is null then
        select * into v_req from public.audit_requests
         where stripe_checkout_session_id = v_obj ->> 'id' for update;
      end if;
      if v_req.id is null and v_email is not null then
        select r.* into v_req
          from public.audit_requests r
          join public.audit_customers c on c.id = r.customer_id
         where c.email_normalized = v_email and r.status = 'awaiting_payment'
         order by r.created_at desc limit 1
         for update of r;
      end if;

      if v_type = 'checkout.session.expired' then
        if v_req.id is not null then
          insert into public.audit_events (audit_request_id, event_type, actor, detail)
          values (v_req.id, 'checkout_expired', 'stripe', jsonb_build_object('session_id', v_obj ->> 'id'));
        else
          v_result := 'ignored';
        end if;

      elsif v_type = 'checkout.session.async_payment_failed' then
        if v_req.id is not null then
          insert into public.audit_payments as p
            (audit_request_id, stripe_checkout_session_id, stripe_payment_intent_id,
             amount_cents, currency, status, livemode)
          values (v_req.id, v_obj ->> 'id', v_pi, coalesce(v_amount, 0), coalesce(v_currency, 'usd'), 'failed', v_live)
          on conflict (stripe_checkout_session_id) do update set status = 'failed';
          insert into public.audit_events (audit_request_id, event_type, actor, detail)
          values (v_req.id, 'payment_failed', 'stripe', jsonb_build_object('session_id', v_obj ->> 'id'));
        else
          v_result := 'ignored';
        end if;

      else  -- completed / async_payment_succeeded
        if v_obj ->> 'payment_status' is distinct from 'paid' then
          -- Delayed payment methods complete as 'unpaid'; wait for async_payment_succeeded.
          if v_req.id is not null then
            insert into public.audit_events (audit_request_id, event_type, actor, detail)
            values (v_req.id, 'payment_pending', 'stripe',
                    jsonb_build_object('session_id', v_obj ->> 'id', 'payment_status', v_obj ->> 'payment_status'));
          else
            v_result := 'ignored';
          end if;
        else
          if v_email is null then
            raise exception 'paid checkout session % has no customer email', v_obj ->> 'id';
          end if;

          -- Paid without prior intake (e.g. Stripe Payment Link): create the request.
          if v_req.id is null then
            insert into public.audit_customers as c (email, full_name)
            values (v_email, nullif(v_obj -> 'customer_details' ->> 'name', ''))
            on conflict (email_normalized) do update set full_name = coalesce(c.full_name, excluded.full_name)
            returning c.id into v_customer;

            insert into public.audit_requests (customer_id, source, price_cents, currency)
            values (v_customer, 'stripe_payment_link', coalesce(v_amount, 29700), coalesce(v_currency, 'usd'))
            returning * into v_req;

            insert into public.audit_events (audit_request_id, event_type, actor, detail)
            values (v_req.id, 'intake_missing', 'stripe',
                    jsonb_build_object('note', 'Paid without intake form; collect store URL and goals.'));
          end if;

          v_req_id := v_req.id;

          if v_obj ->> 'customer' ~ '^cus_' then
            update public.audit_customers
               set stripe_customer_id = coalesce(stripe_customer_id, v_obj ->> 'customer')
             where id = v_req.customer_id;
          end if;

          insert into public.audit_payments as p
            (audit_request_id, stripe_checkout_session_id, stripe_payment_intent_id,
             amount_cents, currency, status, livemode)
          values (v_req.id, v_obj ->> 'id', v_pi, coalesce(v_amount, 0), coalesce(v_currency, 'usd'),
                  'succeeded', v_live)
          on conflict (stripe_checkout_session_id) do update
             set status = 'succeeded',
                 stripe_payment_intent_id = coalesce(p.stripe_payment_intent_id, excluded.stripe_payment_intent_id),
                 amount_cents = excluded.amount_cents;

          if v_amount is distinct from v_req.price_cents or v_currency is distinct from v_req.currency then
            -- Never auto-start work on an unexpected amount; flag for review.
            insert into public.audit_events (audit_request_id, event_type, actor, detail)
            values (v_req.id, 'payment_amount_mismatch', 'stripe',
                    jsonb_build_object('expected_cents', v_req.price_cents, 'expected_currency', v_req.currency,
                                       'received_cents', v_amount, 'received_currency', v_currency));
            v_note := 'amount_mismatch';
          elsif v_req.status = 'awaiting_payment' then
            update public.audit_requests
               set status = 'paid',
                   paid_at = coalesce(to_timestamp((p_event ->> 'created')::bigint), now()),
                   stripe_checkout_session_id = coalesce(stripe_checkout_session_id, v_obj ->> 'id')
             where id = v_req.id;
          elsif v_req.status in ('cancelled', 'refunded') then
            insert into public.audit_events (audit_request_id, event_type, actor, detail)
            values (v_req.id, 'payment_on_closed_request', 'stripe',
                    jsonb_build_object('status', v_req.status, 'session_id', v_obj ->> 'id'));
            v_note := 'closed_request';
          end if;
        end if;
      end if;

    elsif v_type = 'charge.refunded' then
      v_pi := v_obj ->> 'payment_intent';
      select p.audit_request_id into v_req_id from public.audit_payments p
       where p.stripe_payment_intent_id = v_pi for update;
      if v_req_id is null then
        v_result := 'ignored';
      else
        v_req.id := v_req_id;
        update public.audit_payments
           set amount_refunded_cents = least((v_obj ->> 'amount_refunded')::integer, amount_cents),
               status = case when (v_obj ->> 'amount_refunded')::integer >= amount_cents
                             then 'refunded' else 'partially_refunded' end
         where stripe_payment_intent_id = v_pi;

        insert into public.audit_events (audit_request_id, event_type, actor, detail)
        values (v_req_id, 'refund_recorded', 'stripe',
                jsonb_build_object('amount_refunded', (v_obj ->> 'amount_refunded')::integer));

        if (v_obj ->> 'refunded')::boolean then
          update public.audit_requests
             set status = 'refunded'
           where id = v_req_id and status in ('paid', 'in_progress', 'delivered');
        end if;
      end if;

    elsif v_type = 'charge.dispute.created' then
      v_pi := v_obj ->> 'payment_intent';
      update public.audit_payments set status = 'disputed'
       where stripe_payment_intent_id = v_pi
      returning audit_request_id into v_req_id;
      if v_req_id is null then
        v_result := 'ignored';
      else
        v_req.id := v_req_id;
        insert into public.audit_events (audit_request_id, event_type, actor, detail)
        values (v_req_id, 'payment_disputed', 'stripe',
                jsonb_build_object('reason', v_obj ->> 'reason', 'amount', (v_obj ->> 'amount')::integer));
      end if;

    else
      v_result := 'ignored';
    end if;

    update public.stripe_events
       set status = case v_result when 'ignored' then 'ignored' else 'processed' end,
           processed_at = now(),
           audit_request_id = coalesce(v_req.id, v_req_id)
     where id = v_id;

  exception when others then
    -- Business logic rolled back to the savepoint; keep the event and the error for retry.
    update public.stripe_events
       set status = 'failed', error = left(sqlerrm, 1000)
     where id = v_id;
    return jsonb_build_object('result', 'failed', 'event_id', v_id, 'error', sqlerrm);
  end;

  return jsonb_build_object('result', v_result, 'event_id', v_id,
                            'audit_request_id', coalesce(v_req.id, v_req_id), 'note', v_note);
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: fulfillment transitions (called by audit-admin after an admin check)
-- ---------------------------------------------------------------------------
create function public.audit_transition(
  p_request_id uuid,
  p_to_status  public.audit_status,
  p_actor      text,
  p_report_url text default null,
  p_note       text default null
)
returns public.audit_requests
language plpgsql
set search_path = ''
as $$
declare
  v_row public.audit_requests;
  v_version integer;
begin
  perform set_config('cuadra.actor', left(coalesce(p_actor, 'admin'), 100), true);

  if p_to_status = 'delivered' then
    if p_report_url is null or p_report_url !~* '^https://' then
      raise exception 'report_url (https) is required to deliver' using errcode = 'check_violation';
    end if;
    select coalesce(max(version), 0) + 1 into v_version
      from public.audit_deliverables where audit_request_id = p_request_id and kind = 'report';
    insert into public.audit_deliverables (audit_request_id, kind, version, url, notes)
    values (p_request_id, 'report', v_version, p_report_url, p_note);
  end if;

  update public.audit_requests
     set status = p_to_status,
         report_url = coalesce(p_report_url, report_url)
   where id = p_request_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'audit request % not found', p_request_id using errcode = 'no_data_found';
  end if;

  if p_note is not null then
    insert into public.audit_events (audit_request_id, event_type, actor, detail)
    values (p_request_id, 'note', left(coalesce(p_actor, 'admin'), 100), jsonb_build_object('note', left(p_note, 5000)));
  end if;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges. Explicit grants (new tables are not auto-exposed from 2026-10-30).
-- ---------------------------------------------------------------------------
revoke all on table
  public.audit_customers, public.audit_requests, public.audit_payments,
  public.audit_deliverables, public.stripe_events, public.audit_events
  from public, anon, authenticated;

grant select, insert, update, delete on table
  public.audit_customers, public.audit_requests, public.audit_payments,
  public.audit_deliverables, public.stripe_events, public.audit_events
  to service_role;

-- Customers can only read; RLS limits rows to their own.
grant select on table public.audit_customers, public.audit_requests, public.audit_deliverables
  to authenticated;

revoke execute on function
  public.audit_add_business_days(timestamptz, integer),
  public.audit_request_status_guard(),
  public.audit_request_created_log(),
  public.audit_submit_intake(jsonb),
  public.audit_attach_checkout_session(uuid, text),
  public.audit_handle_stripe_event(jsonb),
  public.audit_transition(uuid, public.audit_status, text, text, text)
  from public, anon, authenticated;

grant execute on function
  public.audit_add_business_days(timestamptz, integer),
  public.audit_submit_intake(jsonb),
  public.audit_attach_checkout_session(uuid, text),
  public.audit_handle_stripe_event(jsonb),
  public.audit_transition(uuid, public.audit_status, text, text, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.audit_customers    enable row level security;
alter table public.audit_requests     enable row level security;
alter table public.audit_payments     enable row level security;
alter table public.audit_deliverables enable row level security;
alter table public.stripe_events      enable row level security;
alter table public.audit_events       enable row level security;

create policy audit_customers_owner_select on public.audit_customers
  for select to authenticated
  using (auth_user_id = (select auth.uid()));

create policy audit_requests_owner_select on public.audit_requests
  for select to authenticated
  using (customer_id in (select c.id from public.audit_customers c
                          where c.auth_user_id = (select auth.uid())));

create policy audit_deliverables_owner_select on public.audit_deliverables
  for select to authenticated
  using (audit_request_id in (select r.id from public.audit_requests r
                               join public.audit_customers c on c.id = r.customer_id
                              where c.auth_user_id = (select auth.uid())));

-- audit_payments, stripe_events, audit_events: no policies => service_role only.
