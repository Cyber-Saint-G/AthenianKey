-- ════════════════════════════════════════════════════════════════════
--  AthenianKeys · Πλάνο στο αίτημα (The Day / Weekend / Master Key)
--  Ασφαλές να τρέξει ξανά. Δεν αλλάζει υπάρχοντα δεδομένα: προσθέτει
--  μόνο τη στήλη «plan» και ανανεώνει τη submit_request ώστε να τη δέχεται.
--  Τρέχει ΜΕΤΑ το 20261124000000_admin_dashboard.sql.
-- ════════════════════════════════════════════════════════════════════

alter table public.requests add column if not exists plan text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'requests_plan_format') then
    alter table public.requests add constraint requests_plan_format
      check (plan is null or plan ~ '^[a-z0-9-]{1,40}$');
  end if;
end $$;

-- Ο trigger κρατά το πλάνο αμετάβλητο μετά την υποβολή (όπως τα άλλα στοιχεία του πελάτη)
create or replace function public._requests_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.id := old.id; new.ref := old.ref; new.created_at := old.created_at;
  new.customer_id := old.customer_id; new.plan := old.plan; new.services := old.services; new.region := old.region;
  new.travel_date := old.travel_date; new.guests := old.guests; new.full_name := old.full_name;
  new.phone := old.phone; new.email := old.email; new.notes := old.notes;
  new.lang := old.lang; new.channel := old.channel;
  new.updated_at := now();
  if new.status is distinct from old.status then
    new.status_changed_at := now();
    insert into public.request_events (request_id, from_status, to_status, by_user)
    values (old.id, old.status, new.status, auth.uid());
  end if;
  return new;
end $$;

create or replace function public.submit_request(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ref      text := upper(trim(coalesce(p->>'ref', '')));
  v_plan     text := nullif(left(trim(coalesce(p->>'plan', '')), 40), '');
  v_name     text := left(trim(coalesce(p->>'name', '')), 120);
  v_phone    text := left(trim(coalesce(p->>'phone', '')), 40);
  v_email    text := lower(left(trim(coalesce(p->>'email', '')), 160));
  v_notes    text := nullif(left(trim(coalesce(p->>'notes', '')), 3000), '');
  v_region   text := nullif(left(trim(coalesce(p->>'region', '')), 40), '');
  v_lang     text := case when p->>'lang' in ('el', 'en') then p->>'lang' end;
  v_channel  text := case when p->>'channel' in ('whatsapp', 'email') then p->>'channel' end;
  v_services text[];
  v_date     date;
  v_guests   integer;
  v_key      text;
  v_cust     uuid;
  v_hash     text;
begin
  if v_ref !~ '^AK-[A-Z0-9]{6,12}$' then
    v_ref := 'AK-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  end if;
  if exists (select 1 from public.requests where ref = v_ref) then
    return v_ref;
  end if;

  select coalesce(array_agg(distinct s), '{}') into v_services
  from jsonb_array_elements_text(case when jsonb_typeof(p->'services') = 'array' then p->'services' else '[]'::jsonb end) s
  where s ~ '^[a-z0-9-]{1,40}$';
  if cardinality(v_services) = 0 or cardinality(v_services) > 20 then raise exception 'invalid_services'; end if;
  if length(v_name) < 2 then raise exception 'invalid_name'; end if;
  if length(public._phone_key(v_phone)) < 6 then raise exception 'invalid_phone'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email := null; end if;
  if v_region !~ '^[a-z0-9-]{1,40}$' then v_region := null; end if;
  if v_plan !~ '^[a-z0-9-]{1,40}$' then v_plan := null; end if;
  begin v_date := (p->>'date')::date; exception when others then v_date := null; end;
  begin v_guests := least(greatest((p->>'guests')::integer, 1), 999); exception when others then v_guests := null; end;

  v_hash := public._client_hash('submit');
  delete from public.submit_log where at < now() - interval '1 day';
  if (select count(*) from public.submit_log where client_hash = v_hash and at > now() - interval '1 hour') >= 8 then
    raise exception 'rate_limited';
  end if;
  insert into public.submit_log (client_hash) values (v_hash);

  v_key := 'tel:' || public._phone_key(v_phone);
  insert into public.customers as c (contact_key, full_name, phone, email, last_request_at, request_count)
  values (v_key, v_name, v_phone, v_email, now(), 1)
  on conflict (contact_key) do update
    set full_name       = coalesce(c.full_name, excluded.full_name),
        email           = coalesce(c.email, excluded.email),
        last_request_at = now(),
        request_count   = c.request_count + 1
  returning id into v_cust;

  insert into public.requests (ref, customer_id, plan, services, region, travel_date, guests,
                               full_name, phone, email, notes, lang, channel)
  values (v_ref, v_cust, v_plan, v_services, v_region, v_date, v_guests,
          v_name, v_phone, v_email, v_notes, v_lang, v_channel);
  return v_ref;
end $$;
revoke all on function public.submit_request(jsonb) from public;
grant execute on function public.submit_request(jsonb) to anon, authenticated;

-- Στατιστικά: αιτήματα ανά πλάνο
create or replace function public.admin_plan_stats(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object('k', coalesce(plan, '-'), 'n', n) order by n desc), '[]')
          from (select plan, count(*) n from public.requests
                where created_at >= (p_from::timestamp at time zone 'Europe/Athens')
                  and created_at <  ((p_to + 1)::timestamp at time zone 'Europe/Athens')
                group by plan) x);
end $$;
revoke all on function public.admin_plan_stats(date, date) from public;
grant execute on function public.admin_plan_stats(date, date) to authenticated;
