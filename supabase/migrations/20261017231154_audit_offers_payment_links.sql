-- Audit offers = the Stripe Payment Links that sell the $297 audit.
-- Decisions (2026-10-17): primary link is the 48-Hour E-Commerce Revenue & Automation Audit;
-- delivery deadline is 48 hours after payment. Older $297 audit links stay accepted.
--
-- Changes
--   * new table audit_offers (service_role only), seeded with the 4 live audit links
--   * audit_requests.stripe_payment_link_id, audit_payments subtotal/tax columns
--   * status guard: due_at = paid_at + offer turnaround (48h) instead of 5 business days
--   * intake: stamps the primary offer on new requests
--   * Stripe handler: ignores non-payment-mode sessions and checkouts from non-audit links,
--     checks the PRE-TAX subtotal against the price (automatic tax is enabled on the links)

create table public.audit_offers (
  stripe_payment_link_id text primary key check (stripe_payment_link_id ~ '^plink_'),
  payment_link_url       text not null check (payment_link_url ~ '^https://buy\.stripe\.com/'),
  name                   text not null check (length(name) <= 200),
  stripe_price_id        text check (stripe_price_id ~ '^price_'),
  price_cents            integer not null check (price_cents > 0),
  currency               text not null default 'usd' check (currency ~ '^[a-z]{3}$'),
  turnaround             interval not null default interval '48 hours' check (turnaround > interval '0'),
  is_primary             boolean not null default false,
  active                 boolean not null default true,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint audit_offers_primary_is_active check (not is_primary or active)
);
create unique index audit_offers_single_primary on public.audit_offers (is_primary) where is_primary;
create trigger audit_offers_updated_at before update on public.audit_offers
  for each row execute function public.set_updated_at();

insert into public.audit_offers
  (stripe_payment_link_id, payment_link_url, name, stripe_price_id, price_cents, is_primary)
values
  ('plink_1URgevDLGXdSpZNAGJcC2tvd', 'https://buy.stripe.com/14A14n07Q8mr9Owaf4bAs05',
   '48-Hour E-Commerce Revenue & Automation Audit', 'price_1UJtnIDLGXdSpZNApWOFV7Ac', 29700, true),
  ('plink_1URgdvDLGXdSpZNAfZHiKvLF', 'https://buy.stripe.com/7sY5kD2fYdGLf8Q3QGbAs04',
   '$297 Storefront Audit', 'price_1UJtogDLGXdSpZNAX69zApqs', 29700, false),
  ('plink_1UKcrXDLGXdSpZNAPHjtXfQK', 'https://buy.stripe.com/fZu9ATf2KgSX4uc5YObAs01',
   '$297 Storefront Audit (legacy link)', 'price_1UKcrXDLGXdSpZNAAzlU1EN1', 29700, false),
  ('plink_1UJtokDLGXdSpZNAzlc6vAbp', 'https://buy.stripe.com/4gM8wPdYG46b7Go0EubAs00',
   '$297 Storefront Audit (legacy link)', 'price_1UJtogDLGXdSpZNAX69zApqs', 29700, false);

alter table public.audit_requests
  add column stripe_payment_link_id text references public.audit_offers (stripe_payment_link_id) on update cascade;
create index audit_requests_payment_link_idx on public.audit_requests (stripe_payment_link_id);

alter table public.audit_payments
  add column amount_subtotal_cents integer check (amount_subtotal_cents >= 0),
  add column amount_tax_cents      integer check (amount_tax_cents >= 0);

revoke all on table public.audit_offers from public, anon, authenticated;
grant select, insert, update, delete on table public.audit_offers to service_role;
alter table public.audit_offers enable row level security;  -- no policies: service_role only

-- Deadline helper: offer turnaround (default 48h) from payment time.
create function public.audit_due_at(p_paid_at timestamptz, p_payment_link_id text)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select p_paid_at + coalesce(
    (select o.turnaround from public.audit_offers o where o.stripe_payment_link_id = p_payment_link_id),
    (select o.turnaround from public.audit_offers o where o.is_primary),
    interval '48 hours');
$$;
revoke execute on function public.audit_due_at(timestamptz, text) from public, anon, authenticated;
grant execute on function public.audit_due_at(timestamptz, text) to service_role;

create or replace function public.audit_request_status_guard()
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
      new.due_at  := coalesce(new.due_at, public.audit_due_at(new.paid_at, new.stripe_payment_link_id));
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
    when 'delivered'        then array['in_progress','refunded']::public.audit_status[]
    else array[]::public.audit_status[]
  end;

  if not (new.status = any (v_allowed)) then
    raise exception 'invalid audit status transition % -> %', old.status, new.status
      using errcode = 'check_violation';
  end if;

  case new.status
    when 'paid' then
      new.paid_at := coalesce(new.paid_at, now());
      new.due_at  := coalesce(new.due_at, public.audit_due_at(new.paid_at, new.stripe_payment_link_id));
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

-- Intake: same as before, plus stamps the primary offer (link + price) on new requests.
create or replace function public.audit_submit_intake(p_intake jsonb)
returns table (request_id uuid, reference text, status public.audit_status, created boolean)
language plpgsql
set search_path = ''
as $$
declare
  v_email     text := btrim(p_intake ->> 'email');
  v_key       text := nullif(btrim(p_intake ->> 'idempotency_key'), '');
  v_customer  uuid;
  v_existing  record;
  v_offer     record;
begin
  if v_email is null or v_email = '' then
    raise exception 'email is required' using errcode = 'check_violation';
  end if;

  perform set_config('cuadra.actor', 'customer', true);

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

  select o.stripe_payment_link_id, o.price_cents, o.currency into v_offer
    from public.audit_offers o where o.is_primary and o.active;

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
    (customer_id, store_url, platform, monthly_revenue_band, goals, intake, idempotency_key, source,
     stripe_payment_link_id, price_cents, currency)
  values (v_customer,
          nullif(btrim(p_intake ->> 'store_url'), ''),
          nullif(lower(btrim(p_intake ->> 'platform')), ''),
          nullif(btrim(p_intake ->> 'monthly_revenue_band'), ''),
          nullif(btrim(p_intake ->> 'goals'), ''),
          coalesce(p_intake -> 'intake', '{}'::jsonb),
          v_key,
          'web',
          v_offer.stripe_payment_link_id,
          coalesce(v_offer.price_cents, 29700),
          coalesce(v_offer.currency, 'usd'))
  returning r.id, r.reference, r.status, true;
end;
$$;

-- Stripe handler v2.
create or replace function public.audit_handle_stripe_event(p_event jsonb)
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
  v_offer     public.audit_offers%rowtype;
  v_req_id    uuid;
  v_customer  uuid;
  v_email     text;
  v_ref       text;
  v_link      text;
  v_amount    integer;
  v_subtotal  integer;
  v_tax       integer;
  v_currency  text;
  v_pi        text;
  v_note      text;
  v_result    text := 'processed';
begin
  if v_id is null or v_id !~ '^evt_' or v_type is null or v_obj is null then
    raise exception 'malformed Stripe event' using errcode = 'check_violation';
  end if;

  perform set_config('cuadra.actor', 'stripe', true);

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
      v_link     := v_obj ->> 'payment_link';
      v_amount   := (v_obj ->> 'amount_total')::integer;
      v_subtotal := coalesce((v_obj ->> 'amount_subtotal')::integer, v_amount);
      v_tax      := coalesce((v_obj -> 'total_details' ->> 'amount_tax')::integer, 0);
      v_currency := lower(v_obj ->> 'currency');
      v_pi       := v_obj ->> 'payment_intent';

      if v_link is not null then
        select * into v_offer from public.audit_offers where stripe_payment_link_id = v_link;
      end if;

      -- 1) our client_reference_id  2) a session we created  3) open intake by email (audit links only)
      if v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        select * into v_req from public.audit_requests where id = v_ref::uuid for update;
      end if;
      if v_req.id is null then
        select * into v_req from public.audit_requests
         where stripe_checkout_session_id = v_obj ->> 'id' for update;
      end if;
      if v_req.id is null and v_offer.stripe_payment_link_id is not null and v_email is not null then
        select r.* into v_req
          from public.audit_requests r
          join public.audit_customers c on c.id = r.customer_id
         where c.email_normalized = v_email and r.status = 'awaiting_payment'
         order by r.created_at desc limit 1
         for update of r;
      end if;

      if v_req.id is null and (v_offer.stripe_payment_link_id is null
                               or coalesce(v_obj ->> 'mode', 'payment') <> 'payment') then
        -- Not an audit purchase (subscriptions, other products): leave it to other systems.
        v_result := 'ignored';

      elsif v_type = 'checkout.session.expired' then
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
             amount_cents, amount_subtotal_cents, amount_tax_cents, currency, status, livemode)
          values (v_req.id, v_obj ->> 'id', v_pi, coalesce(v_amount, 0), v_subtotal, v_tax,
                  coalesce(v_currency, 'usd'), 'failed', v_live)
          on conflict (stripe_checkout_session_id) do update set status = 'failed';
          insert into public.audit_events (audit_request_id, event_type, actor, detail)
          values (v_req.id, 'payment_failed', 'stripe', jsonb_build_object('session_id', v_obj ->> 'id'));
        else
          v_result := 'ignored';
        end if;

      else  -- completed / async_payment_succeeded
        if v_obj ->> 'payment_status' is distinct from 'paid' then
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

          -- Paid through an audit link without our intake form: create the request.
          if v_req.id is null then
            insert into public.audit_customers as c (email, full_name)
            values (v_email, nullif(v_obj -> 'customer_details' ->> 'name', ''))
            on conflict (email_normalized) do update set full_name = coalesce(c.full_name, excluded.full_name)
            returning c.id into v_customer;

            insert into public.audit_requests (customer_id, source, price_cents, currency, stripe_payment_link_id)
            values (v_customer, 'stripe_payment_link', v_offer.price_cents, v_offer.currency, v_offer.stripe_payment_link_id)
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
             amount_cents, amount_subtotal_cents, amount_tax_cents, currency, status, livemode)
          values (v_req.id, v_obj ->> 'id', v_pi, coalesce(v_amount, 0), v_subtotal, v_tax,
                  coalesce(v_currency, 'usd'), 'succeeded', v_live)
          on conflict (stripe_checkout_session_id) do update
             set status = 'succeeded',
                 stripe_payment_intent_id = coalesce(p.stripe_payment_intent_id, excluded.stripe_payment_intent_id),
                 amount_cents = excluded.amount_cents,
                 amount_subtotal_cents = excluded.amount_subtotal_cents,
                 amount_tax_cents = excluded.amount_tax_cents;

          -- Compare the pre-tax subtotal: automatic tax legitimately raises amount_total.
          if v_subtotal is distinct from v_req.price_cents or v_currency is distinct from v_req.currency then
            insert into public.audit_events (audit_request_id, event_type, actor, detail)
            values (v_req.id, 'payment_amount_mismatch', 'stripe',
                    jsonb_build_object('expected_cents', v_req.price_cents, 'expected_currency', v_req.currency,
                                       'received_subtotal_cents', v_subtotal, 'received_total_cents', v_amount,
                                       'received_currency', v_currency));
            v_note := 'amount_mismatch';
          elsif v_req.status = 'awaiting_payment' then
            update public.audit_requests
               set status = 'paid',
                   paid_at = coalesce(to_timestamp((p_event ->> 'created')::bigint), now()),
                   stripe_payment_link_id = coalesce(v_offer.stripe_payment_link_id, stripe_payment_link_id),
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
    update public.stripe_events
       set status = 'failed', error = left(sqlerrm, 1000)
     where id = v_id;
    return jsonb_build_object('result', 'failed', 'event_id', v_id, 'error', sqlerrm);
  end;

  return jsonb_build_object('result', v_result, 'event_id', v_id,
                            'audit_request_id', coalesce(v_req.id, v_req_id), 'note', v_note);
end;
$$;
