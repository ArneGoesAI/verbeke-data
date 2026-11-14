-- Test van migratie 0006 (offerte-opvolging, rol n8n_opvolging).
-- SCHRIJFT, maar alles in één transactie die eindigt met rollback. Mag lokaal en op live.
--
--   psql "<schrijfbare verbinding>" -X -v ON_ERROR_STOP=1 -f scripts/test_0006_opvolging.sql
--
-- Staat 0006 er nog niet, dan laadt het script de migratie zelf (binnen de transactie, dus ook teruggerold,
-- inclusief de rol). Staat ze er al (na db push), dan test het de bestaande objecten.
--
-- Bewijst: n8n_opvolging kan de drie functies uitvoeren, maar niet rechtstreeks lezen of schrijven in offertes,
-- klanten of andere tabellen, en ook geen andere security-definer-functies. De filters en grenzen (7 en 14 dagen),
-- de limiet per run en de idempotentie van registreer_opvolging kloppen. Testdata wordt aangemaakt relatief aan
-- opvolging_vandaag(), zodat de test niet afhangt van de kalender of van de seed.
-- Elke mislukte controle stopt het script met een exception. Op het einde staat "ALLES OK", daarna ROLLBACK.
--
-- Neveneffect dat niet terugrolt: de sequences van klanten, aanvragen en offertes schuiven een paar nummers op.

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

select to_regprocedure('public.registreer_opvolging(bigint)') is not null as heeft_0006 \gset
\if :heeft_0006
  \echo '0006 staat er al: de migratie wordt niet opnieuw geladen'
\else
  \echo '0006 laden binnen de testtransactie'
  \ir ../supabase/migrations/0006_offerte_opvolging.sql
\endif

\set als_n8n 'reset role; set local role n8n_opvolging;'

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
grant execute on function pg_temp.verwacht_fout(text, text, text) to n8n_opvolging;

-- ── 1. Rolattributen ─────────────────────────
do $$
declare r record;
begin
  select * into r from pg_roles where rolname = 'n8n_opvolging';
  if not found then raise exception '1 rol n8n_opvolging bestaat niet'; end if;
  if not r.rolcanlogin then raise exception '1 n8n_opvolging kan niet inloggen'; end if;
  if r.rolsuper or r.rolcreaterole or r.rolcreatedb or r.rolbypassrls or r.rolreplication or r.rolinherit then
    raise exception '1 n8n_opvolging heeft te veel attributen';
  end if;
  if exists (select from pg_auth_members m where m.member = r.oid) then
    raise exception '1 n8n_opvolging is lid van een andere rol';
  end if;
end $$;
select '1 rolattributen' as controle, 'ok' as resultaat;

-- ── 2. Catalogus: rechten ────────────────────
do $$
declare
  v_toegelaten regprocedure[] := array[
    'public.offertes_voor_herinnering(int)'::regprocedure,
    'public.registreer_opvolging(bigint)'::regprocedure,
    'public.offertes_voor_werfleider()'::regprocedure];
  v_alle regprocedure[] := v_toegelaten || 'public.opvolging_vandaag()'::regprocedure;
  v_fn regprocedure;
  v_rol text;
  v_tabellen text;
  v_functies text;
begin
  foreach v_fn in array v_toegelaten loop
    if not has_function_privilege('n8n_opvolging', v_fn, 'execute') then
      raise exception '2 n8n_opvolging mag % niet uitvoeren', v_fn;
    end if;
    if not (select prosecdef from pg_proc where oid = v_fn) then
      raise exception '2 % is geen security definer', v_fn;
    end if;
  end loop;

  if has_function_privilege('n8n_opvolging', 'public.opvolging_vandaag()', 'execute') then
    raise exception '2 n8n_opvolging mag opvolging_vandaag uitvoeren';
  end if;

  foreach v_fn in array v_alle loop
    if not exists (select from pg_proc where oid = v_fn
                   and proconfig @> array['search_path=""']) then
      raise exception '2 % heeft geen vaste search_path', v_fn;
    end if;
    foreach v_rol in array array['anon', 'authenticated', 'service_role', 'n8n_intake'] loop
      if exists (select from pg_roles where rolname = v_rol) and has_function_privilege(v_rol, v_fn, 'execute') then
        raise exception '2 % mag % uitvoeren', v_rol, v_fn;
      end if;
    end loop;
  end loop;

  select string_agg(format('%I.%I', n.nspname, c.relname), ', ') into v_tabellen
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'auth', 'storage')
    and c.relkind in ('r', 'v', 'm', 'p', 'f')
    and (has_table_privilege('n8n_opvolging', c.oid, 'select')
      or has_table_privilege('n8n_opvolging', c.oid, 'insert')
      or has_table_privilege('n8n_opvolging', c.oid, 'update')
      or has_table_privilege('n8n_opvolging', c.oid, 'delete'));
  if v_tabellen is not null then
    raise exception '2 n8n_opvolging heeft rechten op: %', v_tabellen;
  end if;

  select string_agg(format('%I.%I', c.relname, a.attname), ', ') into v_tabellen
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  where n.nspname = 'public' and c.relkind = 'r'
    and has_column_privilege('n8n_opvolging', c.oid, a.attnum, 'select,insert,update');
  if v_tabellen is not null then
    raise exception '2 n8n_opvolging heeft kolomrechten op: %', v_tabellen;
  end if;

  -- case: anders evalueert de planner has_sequence_privilege ook op rijen die geen sequence zijn.
  select string_agg(format('%I.%I', n.nspname, c.relname), ', ') into v_tabellen
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'S'
    and case when c.relkind = 'S' then has_sequence_privilege('n8n_opvolging', c.oid, 'usage,select,update') end;
  if v_tabellen is not null then
    raise exception '2 n8n_opvolging heeft sequencerechten op: %', v_tabellen;
  end if;

  select string_agg(p.oid::regprocedure::text, ', ') into v_functies
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and p.oid <> all (v_toegelaten)
    and has_function_privilege('n8n_opvolging', p.oid, 'execute');
  if v_functies is not null then
    raise exception '2 n8n_opvolging mag andere security-definer-functies uitvoeren: %', v_functies;
  end if;
end $$;
select '2 rechten in de catalogus' as controle, 'ok' as resultaat;

-- ── Testdata (als verbindingsrol) ────────────
-- Offertes, relatief aan vandaag:
--   A0 verstuurd vandaag-400, nooit opgevolgd   → herinnering, altijd de oudste (sortering, limiet)
--   A  verstuurd vandaag-7,   nooit opgevolgd   → herinnering (grens)
--   B  verstuurd vandaag-6,   nooit opgevolgd   → te jong
--   C  aanvaard,  vandaag-30, nooit opgevolgd   → verkeerde status
--   D  verstuurd vandaag-14,  opgevolgd -7      → werfleider (beide grenzen)
--   E  verstuurd vandaag-20,  opgevolgd -6      → opvolging te recent
--   F  verstuurd vandaag-30,  klant zonder e-mail → geen herinnering
select public.opvolging_vandaag() as vandaag \gset

select id as werfleider from medewerkers
where rol = 'werfleider' and actief and nullif(btrim(email), '') is not null
order by id limit 1 \gset

insert into klanten (type, voornaam, achternaam, email, straat, huisnummer, postcode, gemeente)
values ('particulier', 'Testje', 'Opvolging', 'opvolging.test.0006@example.com', 'Teststraat', '1', '9340', 'Lede')
returning id as klant \gset
insert into klanten (type, voornaam, achternaam, email, straat, huisnummer, postcode, gemeente)
values ('particulier', 'Zonder', 'Mail', null, 'Teststraat', '2', '9340', 'Lede')
returning id as klant_zonder \gset
insert into aanvragen (klant_id, kanaal, onderwerp, omschrijving, ontvangen_op, status, werfleider_id)
values (:klant, 'mail', 'warmtepomp', 'Test 0006', now(), 'offerte_verstuurd', :werfleider)
returning id as aanvraag \gset

create temp table t_offerte (code text primary key, id bigint);
grant select on t_offerte to n8n_opvolging;

with nieuw (code, klant, status, verstuurd, opvolging) as (values
  ('A0', :klant,        'verstuurd', 400, null),
  ('A',  :klant,        'verstuurd', 7,   null),
  ('B',  :klant,        'verstuurd', 6,   null),
  ('C',  :klant,        'aanvaard',  30,  null),
  ('D',  :klant,        'verstuurd', 14,  7),
  ('E',  :klant,        'verstuurd', 20,  6),
  ('F',  :klant_zonder, 'verstuurd', 30,  null)),
ins as (
  insert into offertes (nummer, aanvraag_id, klant_id, werfleider_id, status, opgemaakt_op, verstuurd_op,
                        laatste_opvolging_op, beslist_op, btw_tarief)
  select 'TEST-0006-' || n.code, :aanvraag, n.klant, :werfleider, n.status,
         :'vandaag'::date - n.verstuurd - 1, :'vandaag'::date - n.verstuurd,
         :'vandaag'::date - n.opvolging, case when n.status = 'aanvaard' then :'vandaag'::date end, 6
  from nieuw n
  returning id, nummer)
insert into t_offerte select substr(nummer, 11), id from ins;

-- Steekproef van seedoffertes om straks te bewijzen dat niets anders gewijzigd is.
select coalesce(jsonb_agg(to_jsonb(o) order by o.id), '[]') as seed_voor
from offertes o where o.id <= 40 \gset
select set_config('t.seed', :'seed_voor', true), set_config('t.vandaag', :'vandaag', true) \g /dev/null

-- n8n_opvolging tijdelijk SET geven (zie test_0005: op Supabase krijgt de aanmaker enkel ADMIN). inherit false:
-- de verbindingsrol erft niets. De grant rolt terug op het einde.
grant n8n_opvolging to current_user with inherit false, set true;

-- ── 3. Gedrag als n8n_opvolging ──────────────
:als_n8n
do $$
declare
  v_vandaag date := current_setting('t.vandaag')::date;
  v_a0 bigint := (select id from pg_temp.t_offerte where code = 'A0');
  v_a  bigint := (select id from pg_temp.t_offerte where code = 'A');
  v_b  bigint := (select id from pg_temp.t_offerte where code = 'B');
  v_c  bigint := (select id from pg_temp.t_offerte where code = 'C');
  v_d  bigint := (select id from pg_temp.t_offerte where code = 'D');
  v_e  bigint := (select id from pg_temp.t_offerte where code = 'E');
  v_f  bigint := (select id from pg_temp.t_offerte where code = 'F');
  v_ids bigint[];
  v_data date[];
  r record;
  v_aantal int;
begin
  -- Herinneringslijst. Met 50: in de seed zijn er hoogstens 24 kandidaten (2026-11-14).
  select array_agg(h.offerte_id order by h.ordinality), array_agg(h.verstuurd_op order by h.ordinality)
    into v_ids, v_data
  from public.offertes_voor_herinnering(50) with ordinality h;

  if v_ids[1] <> v_a0 then raise exception '3 oudste offerte (A0) staat niet eerst'; end if;
  if not v_a = any(v_ids) then
    if array_length(v_ids, 1) = 50 then raise exception '3 lijst zit vol (50): grens niet testbaar'; end if;
    raise exception '3 A (verstuurd vandaag-7) ontbreekt';
  end if;
  if v_b = any(v_ids) then raise exception '3 B (vandaag-6) staat in de lijst'; end if;
  if v_c = any(v_ids) then raise exception '3 C (aanvaard) staat in de lijst'; end if;
  if v_d = any(v_ids) or v_e = any(v_ids) then raise exception '3 opgevolgde offerte staat in de lijst'; end if;
  if v_f = any(v_ids) then raise exception '3 F (klant zonder e-mail) staat in de lijst'; end if;
  if exists (select from unnest(v_data) with ordinality d(dt, i)
             where i > 1 and dt < v_data[i - 1]) then
    raise exception '3 lijst is niet gesorteerd op verstuurd_op';
  end if;

  select * into r from public.offertes_voor_herinnering(50) h where h.offerte_id = v_a;
  if r.offertenummer <> 'TEST-0006-A' or r.voornaam <> 'Testje' or r.email <> 'opvolging.test.0006@example.com'
     or r.onderwerp <> 'warmtepomp' or r.verstuurd_op <> v_vandaag - 7 then
    raise exception '3 velden van A kloppen niet: %', to_jsonb(r);
  end if;

  select count(*) into v_aantal from public.offertes_voor_herinnering(1);
  if v_aantal <> 1 then raise exception '3 p_limiet 1 gaf % rijen', v_aantal; end if;
  select count(*) into v_aantal from public.offertes_voor_herinnering();
  if v_aantal > 20 then raise exception '3 standaardlimiet gaf % rijen', v_aantal; end if;

  -- Werfleiderlijst vóór de registratie: D wel, E en A niet.
  select array_agg(w.offerte_id) into v_ids from public.offertes_voor_werfleider() w;
  if not v_d = any(v_ids) then raise exception '3 D ontbreekt in de werfleiderlijst'; end if;
  if v_e = any(v_ids) then raise exception '3 E (opvolging vandaag-6) staat in de werfleiderlijst'; end if;
  if v_a = any(v_ids) then raise exception '3 A staat in de werfleiderlijst'; end if;

  select * into r from public.offertes_voor_werfleider() w where w.offerte_id = v_d;
  if r.offertenummer <> 'TEST-0006-D' or r.klant_naam <> 'Testje Opvolging' or r.onderwerp <> 'warmtepomp'
     or r.verstuurd_op <> v_vandaag - 14 or r.laatste_opvolging_op <> v_vandaag - 7 or r.dagen_open <> 14
     or r.werfleider_email is null then
    raise exception '3 velden van D kloppen niet: %', to_jsonb(r);
  end if;

  -- Registreren: idempotent per dag.
  if not public.registreer_opvolging(v_a) then raise exception '3 eerste registratie van A gaf false'; end if;
  if public.registreer_opvolging(v_a) then raise exception '3 tweede registratie van A gaf true'; end if;
  if v_a = any(array(select h.offerte_id from public.offertes_voor_herinnering(50) h)) then
    raise exception '3 A staat na registratie nog in de herinneringslijst';
  end if;
  if v_a = any(array(select w.offerte_id from public.offertes_voor_werfleider() w)) then
    raise exception '3 A staat na registratie in de werfleiderlijst';
  end if;

  -- Een nieuwe opvolging schuift de datum op: D valt uit de werfleiderlijst.
  if not public.registreer_opvolging(v_d) then raise exception '3 registratie van D gaf false'; end if;
  if v_d = any(array(select w.offerte_id from public.offertes_voor_werfleider() w)) then
    raise exception '3 D staat na een nieuwe opvolging nog in de werfleiderlijst';
  end if;
end $$;
select '3 gedrag' as controle, 'ok' as resultaat;

-- ── 4. Negatief ──────────────────────────────
select id as id_c from pg_temp.t_offerte where code = 'C' \gset
select '4 p_limiet 0' as controle,
       pg_temp.verwacht_fout('select * from public.offertes_voor_herinnering(0)', '22023', 'p_limiet') as resultaat
union all
select '4 p_limiet 51',
       pg_temp.verwacht_fout('select * from public.offertes_voor_herinnering(51)', '22023', 'p_limiet')
union all
select '4 p_limiet null',
       pg_temp.verwacht_fout('select * from public.offertes_voor_herinnering(null)', '22023', 'p_limiet')
union all
select '4 onbestaande offerte',
       pg_temp.verwacht_fout('select public.registreer_opvolging(-1)', 'P0002', 'bestaat niet')
union all
select '4 offerte niet op verstuurd',
       pg_temp.verwacht_fout('select public.registreer_opvolging(' || :id_c || ')', '22023', 'verstuurd')
union all
select '4 select offertes',
       pg_temp.verwacht_fout('select * from public.offertes limit 1', '42501', 'offertes')
union all
select '4 update offertes',
       pg_temp.verwacht_fout($q$update public.offertes set laatste_opvolging_op = current_date where id = 1$q$,
                             '42501', 'offertes')
union all
select '4 select klanten',
       pg_temp.verwacht_fout('select * from public.klanten limit 1', '42501', 'klanten')
union all
select '4 select medewerkers',
       pg_temp.verwacht_fout('select * from public.medewerkers limit 1', '42501', 'medewerkers')
union all
select '4 opvolging_vandaag',
       pg_temp.verwacht_fout('select public.opvolging_vandaag()', '42501', null)
union all
select '4 intake_aanvraag',
       pg_temp.verwacht_fout($q$select public.intake_aanvraag('A B', 'a@example.com', 'Lede', 'x', 'sanitair', false, null)$q$,
                             '42501', null)
union all
select '4 bevestig_werfbon',
       pg_temp.verwacht_fout('select public.bevestig_werfbon(1)', '42501', null);

-- ── 5. Resultaat nakijken (als verbindingsrol) ─
reset role;
do $$
declare
  v_vandaag date := current_setting('t.vandaag')::date;
  o_a public.offertes;
  o_c public.offertes;
begin
  select * into o_a from public.offertes where id = (select id from pg_temp.t_offerte where code = 'A');
  select * into o_c from public.offertes where id = (select id from pg_temp.t_offerte where code = 'C');
  if o_a.laatste_opvolging_op is distinct from v_vandaag or o_a.status <> 'verstuurd' then
    raise exception '5 A klopt niet: %', to_jsonb(o_a);
  end if;
  if o_c.laatste_opvolging_op is not null then
    raise exception '5 C (geweigerde registratie) is gewijzigd';
  end if;
  if (select coalesce(jsonb_agg(to_jsonb(o) order by o.id), '[]') from public.offertes o where o.id <= 40)
     <> current_setting('t.seed')::jsonb then
    raise exception '5 seedoffertes zijn gewijzigd';
  end if;
end $$;
select '5 resultaat' as controle, 'ok' as resultaat;

select 'ALLES OK' as resultaat;

rollback;
