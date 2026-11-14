-- Test van migratie 0005 (intake via het webformulier, rol n8n_intake).
-- SCHRIJFT, maar alles in één transactie die eindigt met rollback. Mag lokaal en op live.
--
--   psql "<schrijfbare verbinding>" -X -v ON_ERROR_STOP=1 -f scripts/test_0005_intake.sql
--
-- Staat 0005 er nog niet, dan laadt het script de migratie zelf (binnen de transactie, dus ook teruggerold,
-- inclusief de rol). Staat ze er al (na db push), dan test het de bestaande objecten.
--
-- Bewijst: n8n_intake kan intake_aanvraag(...) uitvoeren, maar kan niet rechtstreeks lezen of schrijven in
-- klanten, aanvragen of andere tabellen. Elke mislukte controle stopt het script met een exception.
-- Op het einde staat "ALLES OK", daarna ROLLBACK.
--
-- Neveneffect dat niet terugrolt: de sequences van klanten en aanvragen schuiven een paar nummers op.

\set ON_ERROR_STOP on
\set QUIET on
\pset footer off

do $$
begin
  if current_setting('transaction_read_only') = 'on' then
    raise exception 'de verbinding is read-only: dit script schrijft (en rolt terug)';
  end if;
end $$;

begin;

select to_regprocedure('public.intake_aanvraag(text,text,text,text,text,boolean,text,text)') is not null as heeft_0005 \gset
\if :heeft_0005
  \echo '0005 staat er al: de migratie wordt niet opnieuw geladen'
\else
  \echo '0005 laden binnen de testtransactie'
  \ir ../supabase/migrations/0005_intake_webformulier.sql
\endif

\set als_n8n 'reset role; set local role n8n_intake;'
\set fn 'public.intake_aanvraag(text,text,text,text,text,boolean,text,text)'

create function pg_temp.verwacht_fout(p_sql text, p_code text, p_patroon text)
returns text
language plpgsql
as $$
begin
  begin
    execute p_sql;
  exception when others then
    if (p_code is null or sqlstate = p_code) and (p_patroon is null or sqlerrm ~ p_patroon) then
      return 'ok: ' || sqlerrm;
    end if;
    raise exception 'verkeerde fout bij "%": % (%)', p_sql, sqlerrm, sqlstate;
  end;
  raise exception 'niet geweigerd: %', p_sql;
end
$$;
grant execute on function pg_temp.verwacht_fout(text, text, text) to n8n_intake;

-- ── 1. Rolattributen ─────────────────────────
do $$
declare r record;
begin
  select * into r from pg_roles where rolname = 'n8n_intake';
  if not found then raise exception '1 rol n8n_intake bestaat niet'; end if;
  if not r.rolcanlogin then raise exception '1 n8n_intake kan niet inloggen'; end if;
  if r.rolsuper or r.rolcreaterole or r.rolcreatedb or r.rolbypassrls or r.rolreplication then
    raise exception '1 n8n_intake heeft te veel attributen';
  end if;
  if exists (select from pg_auth_members m join pg_roles g on g.oid = m.roleid
             where m.member = r.oid) then
    raise exception '1 n8n_intake is lid van een andere rol';
  end if;
end $$;
select '1 rolattributen' as controle, 'ok' as resultaat;

-- ── 2. Catalogus: rechten ────────────────────
do $$
declare
  v_fn text := 'public.intake_aanvraag(text,text,text,text,text,boolean,text,text)';
  v_rol text;
  v_tabellen text;
  v_functies text;
begin
  if not has_function_privilege('n8n_intake', v_fn, 'execute') then
    raise exception '2 n8n_intake mag intake_aanvraag niet uitvoeren';
  end if;

  foreach v_rol in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select from pg_roles where rolname = v_rol) and has_function_privilege(v_rol, v_fn, 'execute') then
      raise exception '2 % mag intake_aanvraag uitvoeren', v_rol;
    end if;
  end loop;

  select string_agg(format('%I.%I', n.nspname, c.relname), ', ') into v_tabellen
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'auth', 'storage')
    and c.relkind in ('r', 'v', 'm', 'p', 'f')
    and (has_table_privilege('n8n_intake', c.oid, 'select')
      or has_table_privilege('n8n_intake', c.oid, 'insert')
      or has_table_privilege('n8n_intake', c.oid, 'update')
      or has_table_privilege('n8n_intake', c.oid, 'delete'));
  if v_tabellen is not null then
    raise exception '2 n8n_intake heeft rechten op: %', v_tabellen;
  end if;

  select string_agg(format('%I.%I', c.relname, a.attname), ', ') into v_tabellen
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  where n.nspname = 'public' and c.relkind = 'r'
    and has_column_privilege('n8n_intake', c.oid, a.attnum, 'select,insert,update');
  if v_tabellen is not null then
    raise exception '2 n8n_intake heeft kolomrechten op: %', v_tabellen;
  end if;

  -- case: anders evalueert de planner has_sequence_privilege ook op rijen die geen sequence zijn.
  select string_agg(format('%I.%I', n.nspname, c.relname), ', ') into v_tabellen
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'S'
    and case when c.relkind = 'S' then has_sequence_privilege('n8n_intake', c.oid, 'usage,select,update') end;
  if v_tabellen is not null then
    raise exception '2 n8n_intake heeft sequencerechten op: %', v_tabellen;
  end if;

  select string_agg(p.oid::regprocedure::text, ', ') into v_functies
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and p.oid <> v_fn::regprocedure
    and has_function_privilege('n8n_intake', p.oid, 'execute');
  if v_functies is not null then
    raise exception '2 n8n_intake mag andere security-definer-functies uitvoeren: %', v_functies;
  end if;
end $$;
select '2 rechten in de catalogus' as controle, 'ok' as resultaat;

-- Uitgangstoestand van klant 222 (deelt het e-mailadres met klant 794), om straks te bewijzen dat niets overschreven is.
select to_jsonb(k) as klant_222_voor from klanten k where id = 222 \gset

-- ── 3. Gedrag als n8n_intake ─────────────────
-- Op Supabase is postgres geen superuser. Wie een rol aanmaakt, krijgt er sinds PG16 alleen ADMIN op, geen SET.
-- "set role n8n_intake" mag dus pas na deze grant. Ze geldt enkel binnen deze transactie (rollback op het einde).
-- inherit false: de verbindingsrol erft niets van n8n_intake.
grant n8n_intake to current_user with inherit false, set true;

:als_n8n
select public.intake_aanvraag('Testje  Van der Test', 'Intake.Test.0005@Example.com', 'Lede',
                              'Mijn ketel is stuk en het is koud.', 'herstelling', true,
                              'Ketel defect, geen verwarming.', '0470 00 00 00') as a1 \gset
select public.intake_aanvraag('Testje Van der Test', '  intake.test.0005@example.COM ', 'Lede',
                              'Nog een vraag over ventilatie.', 'ventilatie', false, null) as a2 \gset
select public.intake_aanvraag('Iemand Anders', 'inge.declercq63@example.com', 'Gent',
                              'Offerte voor een warmtepomp graag.', 'warmtepomp', false,
                              'Vraagt offerte warmtepomp.', '0499 99 99 99') as a3 \gset
select public.intake_aanvraag('Madonna', 'madonna.intake0005@example.com', 'Aalst',
                              'Lekkende kraan.', 'sanitair', false, 'Kraan lekt.') as a4 \gset

select '3 ongeldig onderwerp' as controle,
       pg_temp.verwacht_fout($q$select public.intake_aanvraag('A B', 'a@example.com', 'Lede', 'x', 'zwembad', false, null)$q$,
                             '22023', 'onderwerp') as resultaat
union all
select '3 leeg e-mailadres',
       pg_temp.verwacht_fout($q$select public.intake_aanvraag('A B', '  ', 'Lede', 'x', 'sanitair', false, null)$q$,
                             '22023', 'e-mail')
union all
select '3 ongeldig e-mailadres',
       pg_temp.verwacht_fout($q$select public.intake_aanvraag('A B', 'geen-adres', 'Lede', 'x', 'sanitair', false, null)$q$,
                             '22023', 'e-mail')
union all
select '3 te lange omschrijving',
       pg_temp.verwacht_fout($q$select public.intake_aanvraag('A B', 'a@example.com', 'Lede', repeat('x', 5001), 'sanitair', false, null)$q$,
                             '22023', 'te lang')
union all
select '3 dringend ontbreekt',
       pg_temp.verwacht_fout($q$select public.intake_aanvraag('A B', 'a@example.com', 'Lede', 'x', 'sanitair', null, null)$q$,
                             '22023', 'dringend');

-- ── 4. Geen directe toegang ──────────────────
select '4 select klanten' as controle,
       pg_temp.verwacht_fout('select * from public.klanten limit 1', '42501', 'klanten') as resultaat
union all
select '4 select aanvragen',
       pg_temp.verwacht_fout('select * from public.aanvragen limit 1', '42501', 'aanvragen')
union all
select '4 select medewerkers',
       pg_temp.verwacht_fout('select * from public.medewerkers limit 1', '42501', 'medewerkers')
union all
select '4 insert aanvragen',
       pg_temp.verwacht_fout($q$insert into public.aanvragen (kanaal, onderwerp, omschrijving, ontvangen_op, status)
                                values ('webformulier', 'sanitair', 'x', now(), 'nieuw')$q$, '42501', 'aanvragen')
union all
select '4 update klanten',
       pg_temp.verwacht_fout($q$update public.klanten set telefoon = 'x' where id = 222$q$, '42501', 'klanten')
union all
select '4 andere functie (bevestig_werfbon)',
       pg_temp.verwacht_fout('select public.bevestig_werfbon(1)', '42501', null);

-- ── 5. Resultaat nakijken (als verbindingsrol) ─
reset role;
select set_config('t.a1', :'a1', true), set_config('t.a2', :'a2', true),
       set_config('t.a3', :'a3', true), set_config('t.a4', :'a4', true),
       set_config('t.k222', :'klant_222_voor', true) \g /dev/null
do $$
declare
  a1 public.aanvragen; a2 public.aanvragen; a3 public.aanvragen; a4 public.aanvragen;
  k  public.klanten;  k4 public.klanten;
begin
  select * into a1 from public.aanvragen where id = current_setting('t.a1')::bigint;
  select * into a2 from public.aanvragen where id = current_setting('t.a2')::bigint;
  select * into a3 from public.aanvragen where id = current_setting('t.a3')::bigint;
  select * into a4 from public.aanvragen where id = current_setting('t.a4')::bigint;

  if a1.kanaal <> 'webformulier' or a1.status <> 'nieuw' or a1.onderwerp <> 'herstelling'
     or a1.omschrijving <> 'Mijn ketel is stuk en het is koud.' or not a1.dringend
     or a1.samenvatting is distinct from 'Ketel defect, geen verwarming.' or a1.werfleider_id is not null then
    raise exception '5 aanvraag 1 klopt niet: %', to_jsonb(a1);
  end if;
  if a2.dringend or a2.samenvatting is not null or a2.onderwerp <> 'ventilatie' then
    raise exception '5 aanvraag 2 klopt niet: %', to_jsonb(a2);
  end if;

  -- Nieuwe klant: particulier, naam gesplitst, e-mail genormaliseerd, adres null.
  select * into k from public.klanten where id = a1.klant_id;
  if k.type <> 'particulier' or k.voornaam <> 'Testje' or k.achternaam <> 'Van der Test'
     or k.email <> 'intake.test.0005@example.com' or k.telefoon <> '0470 00 00 00' or k.gemeente <> 'Lede'
     or k.straat is not null or k.huisnummer is not null or k.postcode is not null then
    raise exception '5 nieuwe klant klopt niet: %', to_jsonb(k);
  end if;

  -- Zelfde adres in andere schrijfwijze: dezelfde klant.
  if a2.klant_id <> a1.klant_id then
    raise exception '5 tweede inzending maakte een nieuwe klant (% <> %)', a2.klant_id, a1.klant_id;
  end if;
  if (select count(*) from public.klanten where lower(btrim(email)) = 'intake.test.0005@example.com') <> 1 then
    raise exception '5 meer dan één klant met het testadres';
  end if;

  -- Bestaand seedadres (gedeeld door 222 en 794): klant 222, niets overschreven.
  if a3.klant_id <> 222 then
    raise exception '5 bestaand adres gaf klant %, verwacht 222', a3.klant_id;
  end if;
  if (select to_jsonb(x) from public.klanten x where id = 222) <> current_setting('t.k222')::jsonb then
    raise exception '5 klant 222 is gewijzigd';
  end if;

  -- Naam van één woord: achternaam null.
  select * into k4 from public.klanten where id = a4.klant_id;
  if k4.voornaam <> 'Madonna' or k4.achternaam is not null then
    raise exception '5 naam van één woord klopt niet: %', to_jsonb(k4);
  end if;
end $$;
select '5 resultaat' as controle, 'ok' as resultaat;

reset role;
select 'ALLES OK' as resultaat;

rollback;
