-- Intake via het webformulier (project 3: n8n).
--
-- n8n krijgt een eigen login-rol, n8n_intake, die precies één ding mag: intake_aanvraag(...) uitvoeren. Die rol heeft
-- geen rechten op tabellen. De functie draait als security definer en controleert zelf haar invoer.
--
-- Het wachtwoord staat NIET in deze migratie. Zet het buiten de repo, in de SQL-editor:
--   alter role n8n_intake password '...';
-- n8n verbindt daarna via de Supavisor-pooler als gebruiker "n8n_intake.<project-ref>" en roept aan:
--   select public.intake_aanvraag($1, $2, $3, $4, $5, $6, $7, $8);
-- Gebruik query-parameters in n8n, geen stringconcatenatie.
--
-- Let op (zie ook 0004): Supabase geeft anon, authenticated en service_role standaard expliciet execute op elke nieuwe
-- functie in public. Daarom wordt hieronder van al die rollen ingetrokken; alleen n8n_intake krijgt execute.
--
-- Test: scripts/test_0005_intake.sql (schrijft in een transactie met rollback).

-- ─────────────────────────────────────────────
-- 1. Kolommen
-- ─────────────────────────────────────────────

alter table aanvragen
  add column dringend     boolean not null default false,
  add column samenvatting text;

comment on column aanvragen.dringend     is 'Door de AI bij de intake als dringend ingeschat.';
comment on column aanvragen.samenvatting is 'Korte samenvatting van de aanvraag, gemaakt door de AI bij de intake.';

-- Het webformulier vraagt geen adres. Een onbekend adres is null en wordt later aangevuld (bv. bij het plaatsbezoek).
alter table klanten
  alter column straat     drop not null,
  alter column huisnummer drop not null,
  alter column postcode   drop not null;

comment on column klanten.straat     is 'null = nog onbekend (bv. klant aangemaakt via het webformulier).';
comment on column klanten.huisnummer is 'null = nog onbekend (bv. klant aangemaakt via het webformulier).';
comment on column klanten.postcode   is 'null = nog onbekend (bv. klant aangemaakt via het webformulier).';

-- Opzoeken op genormaliseerd e-mailadres. Niet uniek: in de data delen enkele klanten een adres.
create index klanten_email_genormaliseerd_idx on klanten (lower(btrim(email)));

-- ─────────────────────────────────────────────
-- 2. Rol voor n8n
-- ─────────────────────────────────────────────

do $$
begin
  if not exists (select from pg_catalog.pg_roles where rolname = 'n8n_intake') then
    create role n8n_intake login nosuperuser nocreatedb nocreaterole noinherit nobypassrls connection limit 5;
  end if;
end $$;

comment on role n8n_intake is 'Login voor de n8n-intake. Mag enkel public.intake_aanvraag(...) uitvoeren.';

-- usage op het schema is nodig om de functie te kunnen benoemen; het geeft geen rechten op tabellen.
grant usage on schema public to n8n_intake;
-- Geen tabel- of sequencerechten. Expliciet ingetrokken, zodat de bedoeling in de code staat.
revoke all on all tables    in schema public from n8n_intake;
revoke all on all sequences in schema public from n8n_intake;

-- ─────────────────────────────────────────────
-- 3. intake_aanvraag
-- ─────────────────────────────────────────────

create or replace function intake_aanvraag(
  p_naam         text,
  p_email        text,
  p_gemeente     text,
  p_omschrijving text,
  p_onderwerp    text,
  p_dringend     boolean,
  p_samenvatting text,
  p_telefoon     text default null
)
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_naam         text := regexp_replace(btrim(coalesce(p_naam, '')), '\s+', ' ', 'g');
  v_email        text := lower(btrim(coalesce(p_email, '')));
  v_gemeente     text := btrim(coalesce(p_gemeente, ''));
  v_omschrijving text := btrim(coalesce(p_omschrijving, ''));
  v_onderwerp    text := lower(btrim(coalesce(p_onderwerp, '')));
  v_samenvatting text := nullif(btrim(coalesce(p_samenvatting, '')), '');
  v_telefoon     text := nullif(btrim(coalesce(p_telefoon, '')), '');
  v_spatie       int;
  v_klant_id     bigint;
  v_aanvraag_id  bigint;
begin
  -- Verplichte velden
  if v_naam = ''         then raise exception 'naam ontbreekt'         using errcode = '22023'; end if;
  if v_email = ''        then raise exception 'e-mail ontbreekt'       using errcode = '22023'; end if;
  if v_gemeente = ''     then raise exception 'gemeente ontbreekt'     using errcode = '22023'; end if;
  if v_omschrijving = '' then raise exception 'omschrijving ontbreekt' using errcode = '22023'; end if;
  if p_dringend is null  then raise exception 'dringend ontbreekt'     using errcode = '22023'; end if;

  -- Vorm en waarden
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'ongeldig e-mailadres' using errcode = '22023';
  end if;
  if v_onderwerp not in ('warmtepomp','ventilatie','sanitair','renovatie','herstelling') then
    raise exception 'ongeldig onderwerp: %', left(v_onderwerp, 50) using errcode = '22023';
  end if;

  -- Lengtegrenzen (rem op misbruik via het formulier)
  if length(v_naam) > 200                     then raise exception 'naam te lang'         using errcode = '22023'; end if;
  if length(v_email) > 254                    then raise exception 'e-mail te lang'       using errcode = '22023'; end if;
  if length(v_gemeente) > 100                 then raise exception 'gemeente te lang'     using errcode = '22023'; end if;
  if length(v_telefoon) > 50                  then raise exception 'telefoon te lang'     using errcode = '22023'; end if;
  if length(v_omschrijving) > 5000            then raise exception 'omschrijving te lang' using errcode = '22023'; end if;
  if length(v_samenvatting) > 2000            then raise exception 'samenvatting te lang' using errcode = '22023'; end if;

  -- Twee gelijktijdige inzendingen met hetzelfde nieuwe adres mogen geen twee klanten maken.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('intake:' || v_email));

  -- Bestaande klant: hergebruiken, maar niets overschrijven. Wie een e-mailadres kent, mag zo geen klantgegevens
  -- wijzigen. Bij meerdere klanten met hetzelfde adres: de oudste (laagste id).
  select k.id into v_klant_id
  from public.klanten k
  where lower(btrim(k.email)) = v_email
  order by k.id
  limit 1;

  if v_klant_id is null then
    v_spatie := strpos(v_naam, ' ');
    insert into public.klanten (type, voornaam, achternaam, email, telefoon, gemeente)
    values ('particulier',
            case when v_spatie = 0 then v_naam else left(v_naam, v_spatie - 1) end,
            case when v_spatie = 0 then null   else substr(v_naam, v_spatie + 1) end,
            v_email, v_telefoon, v_gemeente)
    returning id into v_klant_id;
  end if;

  insert into public.aanvragen (klant_id, kanaal, onderwerp, omschrijving, ontvangen_op, status, dringend, samenvatting)
  values (v_klant_id, 'webformulier', v_onderwerp, v_omschrijving, now(), 'nieuw', p_dringend, v_samenvatting)
  returning id into v_aanvraag_id;

  return v_aanvraag_id;
end
$$;

comment on function intake_aanvraag(text, text, text, text, text, boolean, text, text) is
  'Intake van het webformulier (n8n). Hergebruikt een klant met hetzelfde e-mailadres (zonder iets te overschrijven) '
  'of maakt een particuliere klant aan, en voegt een aanvraag toe (kanaal webformulier, status nieuw). Geeft het id '
  'van de aanvraag terug. ontvangen_op is de echte tijd (now()), niet peildatum().';

revoke execute on function intake_aanvraag(text, text, text, text, text, boolean, text, text)
  from public, anon, authenticated, service_role;
grant  execute on function intake_aanvraag(text, text, text, text, text, boolean, text, text) to n8n_intake;
