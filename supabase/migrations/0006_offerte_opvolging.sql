-- Offerte-opvolging via een dagelijkse n8n-workflow (project 3: n8n).
--
-- n8n krijgt een eigen login-rol, n8n_opvolging, die precies drie functies mag uitvoeren:
--   offertes_voor_herinnering(p_limiet)  offertes die een herinnering aan de klant nodig hebben
--   registreer_opvolging(p_offerte_id)   zet laatste_opvolging_op op vandaag (idempotent per dag)
--   offertes_voor_werfleider()           offertes voor de verzamelmail aan de werfleider
-- De rol heeft geen rechten op tabellen. De functies draaien als security definer.
--
-- Het wachtwoord staat NIET in deze migratie. Zet het buiten de repo, in de SQL-editor:
--   alter role n8n_opvolging password '...';
-- n8n verbindt daarna via de Supavisor-pooler als gebruiker "n8n_opvolging.<project-ref>" en roept aan:
--   select * from public.offertes_voor_herinnering($1);
--   select public.registreer_opvolging($1);
--   select * from public.offertes_voor_werfleider();
-- Gebruik query-parameters in n8n, geen stringconcatenatie.
-- Aanbevolen volgorde: eerst de mail versturen, dan registreren. Mislukt het registreren, dan komt de offerte de
-- volgende run terug. Een herhaalde registratie op dezelfde dag verandert niets.
--
-- MAILADRESSEN: alle data is fictief. De adressen in klanten en medewerkers staan op gereserveerde domeinen
-- (example.com en subdomeinen daarvan, .test). De n8n-workflow mailt NOOIT naar de adressen die deze functies
-- teruggeven, maar altijd naar een vaste testinbox. De kolommen email en werfleider_email zijn enkel informatief,
-- bv. om in de testmail te tonen voor wie ze bedoeld was.
--
-- "Vandaag" is hier de echte datum (Europe/Brussels), niet peildatum(). peildatum() staat stil: een herinnering van
-- "vandaag" zou nooit 7 dagen oud worden. Zie opvolging_vandaag(). Elke geregistreerde herinnering laat
-- nooit_opgevolgd in v_offerte_opvolging dalen; dat is bewust.
--
-- Let op (zie ook 0004 en 0005): Supabase geeft anon, authenticated en service_role standaard expliciet execute op
-- elke nieuwe functie in public. Daarom wordt hieronder van al die rollen ingetrokken.
--
-- Test: scripts/test_0006_opvolging.sql (schrijft in een transactie met rollback).

-- ─────────────────────────────────────────────
-- 1. Rol voor n8n
-- ─────────────────────────────────────────────

do $$
begin
  if not exists (select from pg_catalog.pg_roles where rolname = 'n8n_opvolging') then
    create role n8n_opvolging login nosuperuser nocreatedb nocreaterole noinherit nobypassrls connection limit 5;
  end if;
end $$;

comment on role n8n_opvolging is
  'Login voor de n8n-offerteopvolging. Mag enkel offertes_voor_herinnering, registreer_opvolging en '
  'offertes_voor_werfleider uitvoeren.';

-- usage op het schema is nodig om de functies te kunnen benoemen; het geeft geen rechten op tabellen.
grant usage on schema public to n8n_opvolging;
-- Geen tabel- of sequencerechten. Expliciet ingetrokken, zodat de bedoeling in de code staat.
revoke all on all tables    in schema public from n8n_opvolging;
revoke all on all sequences in schema public from n8n_opvolging;

-- ─────────────────────────────────────────────
-- 2. opvolging_vandaag (intern)
-- ─────────────────────────────────────────────

-- De echte datum in België. De sessietijdzone op Supabase is UTC: zonder omzetting telt een run tussen 00:00 en
-- 02:00 nog als de vorige dag. greatest(...): wordt de seed opnieuw gegenereerd met een latere peildatum, dan rekent
-- de opvolging nooit vóór de data. Geen datumparameter, zodat een aanroeper niets kan terugdateren.
create or replace function opvolging_vandaag()
returns date
language sql
stable
set search_path = ''
as $$
  select greatest(public.peildatum(), (pg_catalog.now() at time zone 'Europe/Brussels')::date)
$$;

comment on function opvolging_vandaag() is
  'De "vandaag" van de offerte-opvolging: de echte datum in Europe/Brussels, nooit vroeger dan peildatum().';

revoke execute on function opvolging_vandaag() from public, anon, authenticated, service_role;

-- ─────────────────────────────────────────────
-- 3. offertes_voor_herinnering
-- ─────────────────────────────────────────────

create or replace function offertes_voor_herinnering(p_limiet int default 20)
returns table (
  offerte_id    bigint,
  offertenummer text,
  voornaam      text,
  email         text,
  onderwerp     text,
  verstuurd_op  date
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_vandaag date := public.opvolging_vandaag();
begin
  -- Rem: nooit meer dan 50 mails per run, ook niet bij een fout in de workflow.
  if p_limiet is null or p_limiet < 1 or p_limiet > 50 then
    raise exception 'p_limiet moet tussen 1 en 50 liggen' using errcode = '22023';
  end if;

  return query
  select o.id,
         o.nummer,
         coalesce(nullif(btrim(k.voornaam), ''), k.bedrijfsnaam),
         btrim(k.email),
         a.onderwerp,
         o.verstuurd_op
  from public.offertes o
  join public.klanten k        on k.id = o.klant_id
  left join public.aanvragen a on a.id = o.aanvraag_id
  where o.status = 'verstuurd'
    and o.verstuurd_op <= v_vandaag - 7
    and o.laatste_opvolging_op is null
    and nullif(btrim(k.email), '') is not null
  order by o.verstuurd_op, o.id
  limit p_limiet;
end
$$;

comment on function offertes_voor_herinnering(int) is
  'Offertes die een herinnering nodig hebben: status verstuurd, 7 of meer dagen geleden verstuurd, nooit opgevolgd, '
  'klant met e-mailadres. Oudste eerst, hoogstens p_limiet (1 tot 50) rijen. De e-mailadressen zijn fictief en enkel '
  'informatief: de workflow mailt altijd naar een testinbox.';

revoke execute on function offertes_voor_herinnering(int) from public, anon, authenticated, service_role;
grant  execute on function offertes_voor_herinnering(int) to n8n_opvolging;

-- ─────────────────────────────────────────────
-- 4. registreer_opvolging
-- ─────────────────────────────────────────────

create or replace function registreer_opvolging(p_offerte_id bigint)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_vandaag      date := public.opvolging_vandaag();
  v_status       text;
  v_verstuurd_op date;
begin
  select o.status, o.verstuurd_op into v_status, v_verstuurd_op
  from public.offertes o
  where o.id = p_offerte_id
  for update;

  if not found then
    raise exception 'offerte % bestaat niet', p_offerte_id using errcode = 'P0002';
  end if;
  if v_status <> 'verstuurd' or v_verstuurd_op is null then
    raise exception 'offerte % staat niet op verstuurd (%)', p_offerte_id, v_status using errcode = '22023';
  end if;

  update public.offertes o
  set laatste_opvolging_op = v_vandaag
  where o.id = p_offerte_id
    and o.laatste_opvolging_op is distinct from v_vandaag;

  return found;
end
$$;

comment on function registreer_opvolging(bigint) is
  'Registreert een opvolging: laatste_opvolging_op = vandaag (echte datum, Europe/Brussels). Geeft true als er iets '
  'veranderde, false bij een tweede aanroep op dezelfde dag. Enkel voor offertes op verstuurd.';

revoke execute on function registreer_opvolging(bigint) from public, anon, authenticated, service_role;
grant  execute on function registreer_opvolging(bigint) to n8n_opvolging;

-- ─────────────────────────────────────────────
-- 5. offertes_voor_werfleider
-- ─────────────────────────────────────────────

create or replace function offertes_voor_werfleider()
returns table (
  werfleider_id        bigint,
  werfleider_voornaam  text,
  werfleider_email     text,
  offerte_id           bigint,
  offertenummer        text,
  klant_naam           text,
  onderwerp            text,
  verstuurd_op         date,
  laatste_opvolging_op date,
  dagen_open           int
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_vandaag date := public.opvolging_vandaag();
begin
  return query
  select m.id,
         m.voornaam,
         btrim(m.email),
         o.id,
         o.nummer,
         coalesce(nullif(btrim(k.bedrijfsnaam), ''), concat_ws(' ', k.voornaam, k.achternaam)),
         a.onderwerp,
         o.verstuurd_op,
         o.laatste_opvolging_op,
         v_vandaag - o.verstuurd_op
  from public.offertes o
  join public.medewerkers m    on m.id = o.werfleider_id
  join public.klanten k        on k.id = o.klant_id
  left join public.aanvragen a on a.id = o.aanvraag_id
  where o.status = 'verstuurd'
    and o.verstuurd_op <= v_vandaag - 14
    and o.laatste_opvolging_op <= v_vandaag - 7
    and m.actief
    and nullif(btrim(m.email), '') is not null
  order by m.id, o.verstuurd_op, o.id
  limit 200;   -- veiligheidsrem
end
$$;

comment on function offertes_voor_werfleider() is
  'Offertes voor de verzamelmail aan de werfleider: status verstuurd, 14 of meer dagen geleden verstuurd, laatste '
  'opvolging minstens 7 dagen oud. Per werfleider gesorteerd; n8n groepeert. De e-mailadressen zijn fictief en enkel '
  'informatief: de workflow mailt altijd naar een testinbox.';

revoke execute on function offertes_voor_werfleider() from public, anon, authenticated, service_role;
grant  execute on function offertes_voor_werfleider() to n8n_opvolging;
