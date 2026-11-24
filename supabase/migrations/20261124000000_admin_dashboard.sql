-- ════════════════════════════════════════════════════════════════════
--  AthenianKeys · Admin Dashboard · Σχήμα βάσης (Supabase / PostgreSQL)
--
--  Τρέχει στο Supabase: SQL Editor → New query → επικόλληση → Run.
--  Είναι ασφαλές να τρέξει ξανά (idempotent): δεν διαγράφει δεδομένα,
--  μόνο δημιουργεί ό,τι λείπει και ανανεώνει functions/policies.
--
--  Ασφάλεια: κάθε πίνακας έχει Row Level Security. Οι επισκέπτες του
--  site ΔΕΝ μπορούν να διαβάσουν τίποτα προσωπικό· μπορούν μόνο να
--  στείλουν αίτημα και να καταγράψουν προβολή σελίδας μέσω ελεγμένων
--  functions. Όλα τα admin δεδομένα ελέγχονται με public.is_admin()
--  στον server (στη βάση), όχι μόνο στο front end.
-- ════════════════════════════════════════════════════════════════════

-- ─── 1. Admins ──────────────────────────────────────────────────────
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

drop policy if exists admins_read_self on public.admins;
create policy admins_read_self on public.admins
  for select to authenticated using (user_id = auth.uid());

create or replace function public._require_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not_admin' using errcode = '42501';
  end if;
end $$;
revoke all on function public._require_admin() from public;

-- Ψευδωνυμοποιημένο αποτύπωμα πελάτη (hash IP + browser). Ποτέ δεν
-- αποθηκεύεται η IP. Το salt κάνει το hash μη αναστρέψιμο.
create or replace function public._client_hash(p_salt text) returns text
language sql stable as $$
  select encode(sha256(convert_to(
           p_salt || '|' ||
           coalesce(h->>'cf-connecting-ip', nullif(split_part(h->>'x-forwarded-for', ',', 1), ''), h->>'x-real-ip', '') || '|' ||
           coalesce(h->>'user-agent', ''), 'UTF8')), 'hex')
  from (select coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json as h) x;
$$;
revoke all on function public._client_hash(text) from public;

create or replace function public._user_agent() returns text
language sql stable as $$
  select coalesce(coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json->>'user-agent', '');
$$;
revoke all on function public._user_agent() from public;

-- ─── 2. Πελάτες (δημιουργούνται αυτόματα από τα αιτήματα) ───────────
create table if not exists public.customers (
  id              uuid primary key default gen_random_uuid(),
  contact_key     text not null unique,          -- κανονικοποιημένο τηλέφωνο
  full_name       text,
  phone           text,
  email           text,
  first_seen_at   timestamptz not null default now(),   -- «ημερομηνία εγγραφής»
  last_request_at timestamptz,
  request_count   integer not null default 0
);
alter table public.customers enable row level security;
drop policy if exists customers_admin_read on public.customers;
create policy customers_admin_read on public.customers
  for select to authenticated using (public.is_admin());
drop policy if exists customers_admin_update on public.customers;
create policy customers_admin_update on public.customers
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ─── 3. Αιτήματα ─────────────────────────────────────────────────────
create table if not exists public.requests (
  id                uuid primary key default gen_random_uuid(),
  ref               text not null unique,               -- π.χ. AK-7Q2M9X4C
  created_at        timestamptz not null default now(),
  customer_id       uuid references public.customers(id) on delete set null,
  services          text[] not null,
  region            text,
  travel_date       date,
  guests            integer,
  full_name         text not null,
  phone             text not null,
  email             text,
  notes             text,
  lang              text,
  channel           text,                               -- whatsapp | email
  status            text not null default 'new'
                    check (status in ('new','confirmed','completed','cancelled')),
  amount            numeric(12,2) check (amount is null or amount >= 0),
  admin_notes       text,
  seen_at           timestamptz,                        -- null = δεν το έχει δει ο admin
  status_changed_at timestamptz,
  updated_at        timestamptz not null default now()
);
create index if not exists requests_created_idx  on public.requests (created_at desc);
create index if not exists requests_customer_idx on public.requests (customer_id, created_at desc);
create index if not exists requests_status_idx   on public.requests (status);
alter table public.requests enable row level security;
drop policy if exists requests_admin_read on public.requests;
create policy requests_admin_read on public.requests
  for select to authenticated using (public.is_admin());
drop policy if exists requests_admin_update on public.requests;
create policy requests_admin_update on public.requests
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
-- Καμία πολιτική insert/delete: νέα αιτήματα μπαίνουν μόνο από submit_request().

-- Ιστορικό αλλαγών κατάστασης
create table if not exists public.request_events (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references public.requests(id) on delete cascade,
  at          timestamptz not null default now(),
  from_status text,
  to_status   text,
  by_user     uuid
);
create index if not exists request_events_req_idx on public.request_events (request_id, at);
alter table public.request_events enable row level security;
drop policy if exists request_events_admin_read on public.request_events;
create policy request_events_admin_read on public.request_events
  for select to authenticated using (public.is_admin());

create or replace function public._requests_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Ο admin αλλάζει μόνο κατάσταση, ποσό, σημειώσεις και «το είδα».
  new.id := old.id; new.ref := old.ref; new.created_at := old.created_at;
  new.customer_id := old.customer_id; new.services := old.services; new.region := old.region;
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
drop trigger if exists requests_before_update on public.requests;
create trigger requests_before_update before update on public.requests
  for each row execute function public._requests_before_update();

-- Όριο αποστολών ανά επισκέπτη (anti-spam). Κρατιέται μόνο 1 ημέρα.
create table if not exists public.submit_log (
  client_hash text not null,
  at          timestamptz not null default now()
);
create index if not exists submit_log_idx on public.submit_log (client_hash, at);
alter table public.submit_log enable row level security;

-- Κανονικοποίηση τηλεφώνου για να αναγνωρίζεται ο ίδιος πελάτης
create or replace function public._phone_key(p text) returns text
language sql immutable as $$
  select case
    when d ~ '^00' then substr(d, 3)
    when length(d) = 10 and d ~ '^(69|2)' then '30' || d
    else d end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x;
$$;

-- Δημόσια function: το site στέλνει εδώ κάθε αίτημα
create or replace function public.submit_request(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ref      text := upper(trim(coalesce(p->>'ref', '')));
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
    return v_ref;                      -- ίδιο αίτημα στάλθηκε 2η φορά (WhatsApp + email)
  end if;

  select coalesce(array_agg(distinct s), '{}') into v_services
  from jsonb_array_elements_text(case when jsonb_typeof(p->'services') = 'array' then p->'services' else '[]'::jsonb end) s
  where s ~ '^[a-z0-9-]{1,40}$';
  if cardinality(v_services) = 0 or cardinality(v_services) > 20 then raise exception 'invalid_services'; end if;
  if length(v_name) < 2 then raise exception 'invalid_name'; end if;
  if length(public._phone_key(v_phone)) < 6 then raise exception 'invalid_phone'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email := null; end if;
  if v_region !~ '^[a-z0-9-]{1,40}$' then v_region := null; end if;
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

  insert into public.requests (ref, customer_id, services, region, travel_date, guests,
                               full_name, phone, email, notes, lang, channel)
  values (v_ref, v_cust, v_services, v_region, v_date, v_guests,
          v_name, v_phone, v_email, v_notes, v_lang, v_channel);
  return v_ref;
end $$;
revoke all on function public.submit_request(jsonb) from public;
grant execute on function public.submit_request(jsonb) to anon, authenticated;

-- ─── 4. Επισκεψιμότητα (χωρίς cookies) ───────────────────────────────
-- Μοναδικός επισκέπτης = hash(ημερήσιο salt + IP + browser). Το salt
-- αλλάζει κάθε μέρα και διαγράφεται, άρα δεν γίνεται παρακολούθηση
-- ατόμων ανάμεσα σε ημέρες (ίδια μέθοδος με το Plausible).
create table if not exists public.analytics_salts (
  day  date primary key,
  salt text not null
);
alter table public.analytics_salts enable row level security;

create table if not exists public.page_views (
  id      bigint generated always as identity primary key,
  ts      timestamptz not null default now(),
  path    text not null,
  visitor text not null,
  source  text not null default 'direct',
  device  text not null default 'other',
  lang    text
);
create index if not exists page_views_ts_idx on public.page_views (ts);
alter table public.page_views enable row level security;
drop policy if exists page_views_admin_read on public.page_views;
create policy page_views_admin_read on public.page_views
  for select to authenticated using (public.is_admin());

create or replace function public.track_view(p_path text, p_referrer text default null,
                                             p_device text default null, p_lang text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_salt text;
  v_host text;
  v_src  text;
begin
  if p_path is null or length(p_path) > 120 or p_path !~ '^/[A-Za-z0-9/#_.-]*$' then return; end if;
  if public._user_agent() ~* '(bot|crawl|spider|slurp|headless|lighthouse|preview|monitor)' then return; end if;

  delete from public.analytics_salts where day < current_date - 1;
  insert into public.analytics_salts (day, salt) values (current_date, gen_random_uuid()::text)
  on conflict (day) do nothing;
  select salt into v_salt from public.analytics_salts where day = current_date;

  v_host := lower(substring(coalesce(p_referrer, '') from '^https?://([^/:?#]+)'));
  v_src := case
    when v_host is null or v_host = ''              then 'direct'
    when v_host ~ '(^|\.)google\.'                  then 'Google'
    when v_host ~ '(^|\.)bing\.'                    then 'Bing'
    when v_host ~ '(^|\.)duckduckgo\.'              then 'DuckDuckGo'
    when v_host ~ '(^|\.)(facebook|fb)\.'           then 'Facebook'
    when v_host ~ '(^|\.)instagram\.'               then 'Instagram'
    when v_host ~ '(^|\.)(t\.co|twitter\.com|x\.com)$' then 'X / Twitter'
    when v_host ~ '(^|\.)tiktok\.'                  then 'TikTok'
    when v_host ~ '(whatsapp|wa\.me)'               then 'WhatsApp'
    when v_host ~ '(^|\.)linkedin\.'                then 'LinkedIn'
    else left(regexp_replace(v_host, '^www\.', ''), 60) end;

  insert into public.page_views (path, visitor, source, device, lang)
  values (p_path,
          left(public._client_hash(v_salt), 32),
          v_src,
          case when p_device in ('mobile', 'tablet', 'desktop') then p_device else 'other' end,
          case when p_lang in ('el', 'en') then p_lang end);
end $$;
revoke all on function public.track_view(text, text, text, text) from public;
grant execute on function public.track_view(text, text, text, text) to anon, authenticated;

-- ─── 5. Περιεχόμενο site (CMS) με ιστορικό εκδόσεων ─────────────────
create table if not exists public.site_content (
  id         integer primary key default 1 check (id = 1),
  data       jsonb not null default '{}'::jsonb,
  version_id bigint,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.site_content enable row level security;
drop policy if exists site_content_public_read on public.site_content;
create policy site_content_public_read on public.site_content
  for select to anon, authenticated using (true);   -- δημόσια κείμενα, χωρίς προσωπικά δεδομένα

create table if not exists public.content_versions (
  id         bigint generated always as identity primary key,
  data       jsonb not null,
  note       text,
  created_at timestamptz not null default now(),
  created_by uuid
);
alter table public.content_versions enable row level security;
drop policy if exists content_versions_admin_read on public.content_versions;
create policy content_versions_admin_read on public.content_versions
  for select to authenticated using (public.is_admin());

create or replace function public.publish_content(p_data jsonb, p_note text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  perform public._require_admin();
  if jsonb_typeof(p_data) <> 'object' then raise exception 'invalid_content'; end if;
  if octet_length(p_data::text) > 600000 then raise exception 'content_too_large'; end if;
  insert into public.content_versions (data, note, created_by)
  values (p_data, left(nullif(trim(p_note), ''), 200), auth.uid())
  returning id into v_id;
  insert into public.site_content (id, data, version_id, updated_at, updated_by)
  values (1, p_data, v_id, now(), auth.uid())
  on conflict (id) do update
    set data = excluded.data, version_id = excluded.version_id,
        updated_at = excluded.updated_at, updated_by = excluded.updated_by;
  return v_id;
end $$;
revoke all on function public.publish_content(jsonb, text) from public;
grant execute on function public.publish_content(jsonb, text) to authenticated;

-- ─── 6. Σύνδεση admin: όριο αποτυχημένων προσπαθειών ────────────────
create table if not exists public.admin_login_attempts (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  email_hash  text not null,
  client_hash text not null,
  success     boolean not null
);
create index if not exists admin_login_attempts_idx on public.admin_login_attempts (email_hash, at);
alter table public.admin_login_attempts enable row level security;

-- Δευτερόλεπτα που απομένουν στο κλείδωμα (0 = επιτρέπεται σύνδεση).
-- Κλείδωμα 15΄ μετά από 5 αποτυχίες μέσα σε 15΄ (ανά email + συσκευή).
create or replace function public.admin_login_status(p_email text) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_e text := encode(sha256(convert_to(lower(trim(coalesce(p_email, ''))), 'UTF8')), 'hex');
  v_c text := public._client_hash('login');
  v_fails integer; v_last timestamptz;
begin
  select count(*), max(at) into v_fails, v_last
  from public.admin_login_attempts
  where email_hash = v_e and client_hash = v_c and not success
    and at > now() - interval '15 minutes'
    and at > coalesce((select max(at) from public.admin_login_attempts
                       where email_hash = v_e and client_hash = v_c and success), '-infinity');
  if v_fails >= 5 then
    return greatest(0, ceil(extract(epoch from (v_last + interval '15 minutes' - now())))::integer);
  end if;
  return 0;
end $$;
revoke all on function public.admin_login_status(text) from public;
grant execute on function public.admin_login_status(text) to anon, authenticated;

create or replace function public.admin_log_login(p_email text, p_success boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  -- Επιτυχία καταγράφεται μόνο αν ο χρήστης είναι πράγματι συνδεδεμένος admin
  if p_success and not public.is_admin() then return; end if;
  delete from public.admin_login_attempts where at < now() - interval '90 days';
  insert into public.admin_login_attempts (email_hash, client_hash, success)
  values (encode(sha256(convert_to(lower(trim(coalesce(p_email, ''))), 'UTF8')), 'hex'),
          public._client_hash('login'), coalesce(p_success, false));
end $$;
revoke all on function public.admin_log_login(text, boolean) from public;
grant execute on function public.admin_log_login(text, boolean) to anon, authenticated;

-- Προαιρετικό (πλάνα Supabase που υποστηρίζουν «Password Verification
-- Hook»): το ίδιο όριο επιβάλλεται από τον auth server, χωρίς να
-- μπορεί να παρακαμφθεί. Ενεργοποίηση: Authentication → Hooks.
create table if not exists public.auth_failures (
  user_id uuid not null,
  at      timestamptz not null default now()
);
create index if not exists auth_failures_idx on public.auth_failures (user_id, at);
alter table public.auth_failures enable row level security;

create or replace function public.hook_password_verification_attempt(event jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_user  uuid := (event->>'user_id')::uuid;
  v_fails integer;
begin
  select count(*) into v_fails from public.auth_failures
  where user_id = v_user and at > now() - interval '15 minutes';
  if v_fails >= 5 then
    return jsonb_build_object('decision', 'reject',
      'message', 'Too many failed attempts. Try again in 15 minutes.', 'should_logout_user', false);
  end if;
  if (event->>'valid')::boolean then
    delete from public.auth_failures where user_id = v_user;
  else
    insert into public.auth_failures (user_id) values (v_user);
  end if;
  return jsonb_build_object('decision', 'continue');
end $$;
revoke all on function public.hook_password_verification_attempt(jsonb) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    execute 'grant execute on function public.hook_password_verification_attempt(jsonb) to supabase_auth_admin';
    execute 'grant all on table public.auth_failures to supabase_auth_admin';
  end if;
end $$;

-- ─── 7. Στατιστικά για το dashboard (μόνο admin) ────────────────────
create or replace function public.admin_traffic_stats(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  perform public._require_admin();
  with v as (
    select pv.*, (pv.ts at time zone 'Europe/Athens')::date as d,
           lag(pv.ts) over (partition by pv.visitor order by pv.ts) as prev
    from public.page_views pv
    where pv.ts >= (p_from::timestamp at time zone 'Europe/Athens')
      and pv.ts <  ((p_to + 1)::timestamp at time zone 'Europe/Athens')
  ), starts as (
    select * from v where prev is null or ts - prev > interval '30 minutes'
  ), days as (
    select g::date as d from generate_series(p_from, p_to, interval '1 day') g
  )
  select jsonb_build_object(
    'pageviews', (select count(*) from v),
    'visits',    (select count(*) from starts),
    'visitors',  (select count(*) from (select distinct d, visitor from v) x),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object(
                 'd', days.d,
                 'pageviews', (select count(*) from v where v.d = days.d),
                 'visits',    (select count(*) from starts s where s.d = days.d),
                 'visitors',  (select count(distinct visitor) from v where v.d = days.d)) order by days.d), '[]')
              from days),
    'pages',   (select coalesce(jsonb_agg(jsonb_build_object('k', path, 'n', n) order by n desc), '[]')
                from (select path, count(*) n from v group by path order by n desc limit 15) x),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('k', source, 'n', n) order by n desc), '[]')
                from (select source, count(*) n from starts group by source order by n desc limit 15) x),
    'devices', (select coalesce(jsonb_agg(jsonb_build_object('k', device, 'n', n) order by n desc), '[]')
                from (select device, count(*) n from (select distinct d, visitor, device from v) y group by device) x)
  ) into r;
  return r;
end $$;
revoke all on function public.admin_traffic_stats(date, date) from public;
grant execute on function public.admin_traffic_stats(date, date) to authenticated;

create or replace function public.admin_business_stats(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  perform public._require_admin();
  with q as (
    select rq.*, (rq.created_at at time zone 'Europe/Athens')::date as d
    from public.requests rq
    where rq.created_at >= (p_from::timestamp at time zone 'Europe/Athens')
      and rq.created_at <  ((p_to + 1)::timestamp at time zone 'Europe/Athens')
  ), c as (
    select (first_seen_at at time zone 'Europe/Athens')::date as d
    from public.customers
    where first_seen_at >= (p_from::timestamp at time zone 'Europe/Athens')
      and first_seen_at <  ((p_to + 1)::timestamp at time zone 'Europe/Athens')
  ), days as (
    select g::date as d from generate_series(p_from, p_to, interval '1 day') g
  )
  select jsonb_build_object(
    'requests',      (select count(*) from q),
    'revenue',       (select coalesce(sum(amount), 0) from q where status in ('confirmed', 'completed')),
    'new_customers', (select count(*) from c),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object(
                 'd', days.d,
                 'requests', (select count(*) from q where q.d = days.d),
                 'revenue',  (select coalesce(sum(amount), 0) from q where q.d = days.d and status in ('confirmed', 'completed')),
                 'new_customers', (select count(*) from c where c.d = days.d)) order by days.d), '[]')
              from days),
    'by_status',  (select coalesce(jsonb_agg(jsonb_build_object('k', status, 'n', n)), '[]')
                   from (select status, count(*) n from q group by status) x),
    'by_service', (select coalesce(jsonb_agg(jsonb_build_object('k', s, 'n', n) order by n desc), '[]')
                   from (select unnest(services) s, count(*) n from q group by 1) x),
    'by_region',  (select coalesce(jsonb_agg(jsonb_build_object('k', coalesce(region, '-'), 'n', n) order by n desc), '[]')
                   from (select region, count(*) n from q group by region) x)
  ) into r;
  return r;
end $$;
revoke all on function public.admin_business_stats(date, date) from public;
grant execute on function public.admin_business_stats(date, date) to authenticated;

-- Πίνακας πελατών με στοιχεία τελευταίου αιτήματος
create or replace function public.admin_customers()
returns table (
  id uuid, full_name text, email text, phone text,
  first_seen_at timestamptz, last_request_at timestamptz, request_count integer,
  last_ref text, last_region text, last_services text[], last_travel_date date,
  last_guests integer, last_status text, last_notes text, last_amount numeric
) language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return query
  select c.id, c.full_name, c.email, c.phone, c.first_seen_at, c.last_request_at, c.request_count,
         l.ref, l.region, l.services, l.travel_date, l.guests, l.status, l.notes, l.amount
  from public.customers c
  left join lateral (
    select r.ref, r.region, r.services, r.travel_date, r.guests, r.status, r.notes, r.amount
    from public.requests r where r.customer_id = c.id
    order by r.created_at desc limit 1
  ) l on true
  order by c.last_request_at desc nulls last;
end $$;
revoke all on function public.admin_customers() from public;
grant execute on function public.admin_customers() to authenticated;

-- ─── 8. Αποθήκευση φωτογραφιών (Supabase Storage) ───────────────────
-- Bucket δημόσιας ανάγνωσης· ανέβασμα/διαγραφή μόνο από admin.
-- Ο server απορρίπτει αρχεία > 5 MB ή τύπους εκτός JPEG/PNG/WebP.
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('site-images', 'site-images', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
    on conflict (id) do update
      set public = true, file_size_limit = excluded.file_size_limit,
          allowed_mime_types = excluded.allowed_mime_types;

    execute 'drop policy if exists site_images_admin_select on storage.objects';
    execute 'create policy site_images_admin_select on storage.objects for select to authenticated
             using (bucket_id = ''site-images'' and public.is_admin())';
    execute 'drop policy if exists site_images_admin_insert on storage.objects';
    execute 'create policy site_images_admin_insert on storage.objects for insert to authenticated
             with check (bucket_id = ''site-images'' and public.is_admin())';
    execute 'drop policy if exists site_images_admin_update on storage.objects';
    execute 'create policy site_images_admin_update on storage.objects for update to authenticated
             using (bucket_id = ''site-images'' and public.is_admin())';
    execute 'drop policy if exists site_images_admin_delete on storage.objects';
    execute 'create policy site_images_admin_delete on storage.objects for delete to authenticated
             using (bucket_id = ''site-images'' and public.is_admin())';
  end if;
end $$;

-- ─── 9. Δικαιώματα: οι επισκέπτες δεν αγγίζουν απευθείας πίνακες ────
revoke all on public.admins, public.customers, public.requests, public.request_events,
              public.submit_log, public.analytics_salts, public.page_views,
              public.content_versions, public.admin_login_attempts, public.auth_failures
       from anon;
revoke insert, update, delete on public.site_content from anon, authenticated;
grant select on public.site_content to anon, authenticated;
revoke insert, update, delete on public.requests, public.customers from authenticated;
revoke insert, update, delete on public.page_views, public.content_versions, public.request_events,
              public.admins, public.submit_log, public.analytics_salts,
              public.admin_login_attempts, public.auth_failures
       from authenticated;
grant select on public.admins, public.customers, public.requests, public.request_events,
              public.page_views, public.content_versions to authenticated;
grant update (status, amount, admin_notes, seen_at) on public.requests to authenticated;
grant update (full_name, email) on public.customers to authenticated;

-- ════════════════════════════════════════════════════════════════════
--  ΤΕΛΕΥΤΑΙΟ ΒΗΜΑ (μία φορά, αφού δημιουργήσετε τον admin χρήστη στο
--  Authentication → Users). Αλλάξτε το email και τρέξτε:
--
--  insert into public.admins (user_id, email)
--  select id, email from auth.users where email = 'YOUR-EMAIL@example.com'
--  on conflict (user_id) do nothing;
-- ════════════════════════════════════════════════════════════════════
