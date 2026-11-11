-- Test van migratie 0004 (werfbon-app): RLS, conceptflow, statusovergangen en storage.
-- SCHRIJFT, maar alles in één transactie die eindigt met rollback. Mag op live (docs/plan-stap-8.md, 1.2).
--
--   psql "<schrijfbare verbinding>" -X -v ON_ERROR_STOP=1 -f scripts/test_0004_werfbon_app.sql
--
-- Staat 0004 er nog niet, dan laadt het script de migratie zelf (binnen de transactie, dus ook teruggerold).
-- Staat ze er al (na db push), dan test het de bestaande objecten.
--
-- Rollen wisselen zoals PostgREST het doet: request.jwt.claims zetten en "set local role".
-- Elke mislukte controle stopt het script met een exception. Op het einde staat "ALLES OK", daarna ROLLBACK.
--
-- Neveneffect dat niet terugrolt: de sequences van werfbonnen, werfbon_lijnen, werfbon_opnames, facturen en
-- factuur_lijnen schuiven een paar nummers op.

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

select to_regclass('public.werfbon_opnames') is not null as heeft_0004 \gset
\if :heeft_0004
  \echo '0004 staat er al: de migratie wordt niet opnieuw geladen'
\else
  \echo '0004 laden binnen de testtransactie'
  \ir ../supabase/migrations/0004_werfbon_app.sql
\endif

-- ── Rollen ───────────────────────────────────
-- Na elke blok: reset role (terug naar de verbindingsrol, die alles ziet).
\set uuid_tech  '''00000000-0000-4000-8000-0000000000a1'''
\set uuid_admin '''00000000-0000-4000-8000-0000000000a2'''
\set als_anon    'reset role; set local request.jwt.claims = ''{"role":"anon"}''; set local role anon;'
\set als_service 'reset role; set local request.jwt.claims = ''{"role":"service_role"}''; set local role service_role;'
\set als_tech    'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}''; set local role authenticated;'
\set als_admin   'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}''; set local role authenticated;'

-- ── Testgegevens (als verbindingsrol) ────────
-- Technieker met een herstelling, een collega-technieker met een eigen interventie, een administratiemedewerker.
select m.id as tech, i.id as interventie
from medewerkers m
join interventie_techniekers it on it.medewerker_id = m.id
join interventies i on i.id = it.interventie_id
where m.rol = 'technieker' and m.actief and i.type = 'herstelling' and i.status <> 'geannuleerd'
order by m.id, i.id
limit 1 \gset

select m.id as collega, it.interventie_id as collega_interventie
from medewerkers m
join interventie_techniekers it on it.medewerker_id = m.id
where m.rol = 'technieker' and m.actief and m.id <> :tech
  and exists (select 1 from werfbonnen w where w.technieker_id = m.id)
  and not exists (select 1 from interventie_techniekers x where x.interventie_id = it.interventie_id and x.medewerker_id = :tech)
order by m.id, it.interventie_id
limit 1 \gset

select id as admin from medewerkers where rol = 'administratie' and actief order by id limit 1 \gset

select (select id from artikelen where code = 'ARB-TECH') as art_arbeid,
       (select id from artikelen where code = 'VERPL')    as art_verpl \gset

insert into auth.users (id, aud, role, email)
values (:uuid_tech,  'authenticated', 'authenticated', 'test-technieker@example.com'),
       (:uuid_admin, 'authenticated', 'authenticated', 'test-administratie@example.com');

update medewerkers set auth_user_id = :uuid_tech  where id = :tech;
update medewerkers set auth_user_id = :uuid_admin where id = :admin;

-- Verwachte aantallen, berekend zonder RLS.
select (select count(distinct interventie_id) from interventie_techniekers where medewerker_id = :tech) as n_interventies,
       (select count(distinct i.klant_id) from interventies i
        where exists (select 1 from interventie_techniekers it
                      where it.interventie_id = i.id and it.medewerker_id = :tech))                 as n_klanten,
       (select count(*) from werfbonnen where technieker_id = :tech)                                as n_eigen_bonnen,
       (select count(*) from werfbonnen)                                                            as n_bonnen,
       (select count(*) from klanten)                                                               as n_alle_klanten,
       (select count(*) from facturen)                                                              as n_facturen
\gset

select (select row(v.*)::text from v_facturatie_achterstand v) as achterstand_voor \gset

\echo 'technieker' :tech 'interventie' :interventie '· collega' :collega 'interventie' :collega_interventie '· administratie' :admin

-- Waarden doorgeven aan do-blokken (die zien geen psql-variabelen): als transactielokale instellingen.
select set_config('t.tech',              :'tech',              true),
       set_config('t.collega',           :'collega',           true),
       set_config('t.admin',             :'admin',             true),
       set_config('t.interventie',       :'interventie',       true),
       set_config('t.collega_interventie', :'collega_interventie', true),
       set_config('t.art_arbeid',        :'art_arbeid',        true),
       set_config('t.n_interventies',    :'n_interventies',    true),
       set_config('t.n_klanten',         :'n_klanten',         true),
       set_config('t.n_eigen_bonnen',    :'n_eigen_bonnen',    true),
       set_config('t.n_bonnen',          :'n_bonnen',          true),
       set_config('t.n_alle_klanten',    :'n_alle_klanten',    true) \g /dev/null

-- Verwacht dat een statement faalt met een foutcode en/of een melding die op het patroon past.
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

-- ── 1. anon ziet niets ───────────────────────
:als_anon
do $$
declare n bigint;
begin
  select (select count(*) from werfbonnen) + (select count(*) from klanten) + (select count(*) from facturen)
       + (select count(*) from werfbon_opnames) + (select count(*) from medewerkers)
    into n;
  if n <> 0 then raise exception '1 anon: ziet % rijen', n; end if;
end $$;
select '1 anon' as controle, pg_temp.verwacht_fout('select public.bevestig_werfbon(1)', '42501', null) as resultaat;

-- ── 2. Technieker ziet alleen het zijne ──────
:als_tech
do $$
declare
  v_ik bigint := current_setting('t.tech')::bigint;
  n bigint;
begin
  if public.mijn_medewerker_id() is distinct from v_ik then
    raise exception '2 tech: mijn_medewerker_id() = %, verwacht %', public.mijn_medewerker_id(), v_ik;
  end if;
  if public.is_administratie() then raise exception '2 tech: is_administratie() is true'; end if;

  select count(*) into n from interventies;
  if n <> current_setting('t.n_interventies')::bigint then
    raise exception '2 tech: ziet % interventies, verwacht %', n, current_setting('t.n_interventies');
  end if;
  select count(*) into n from interventies i
  where not exists (select 1 from interventie_techniekers it where it.interventie_id = i.id and it.medewerker_id = v_ik);
  if n <> 0 then raise exception '2 tech: ziet % interventies van anderen', n; end if;

  select count(*) into n from klanten;
  if n <> current_setting('t.n_klanten')::bigint then
    raise exception '2 tech: ziet % klanten, verwacht %', n, current_setting('t.n_klanten');
  end if;

  select count(*) into n from werfbonnen;
  if n <> current_setting('t.n_eigen_bonnen')::bigint then
    raise exception '2 tech: ziet % bonnen, verwacht %', n, current_setting('t.n_eigen_bonnen');
  end if;
  select count(*) into n from werfbonnen where technieker_id <> v_ik;
  if n <> 0 then raise exception '2 tech: ziet % bonnen van collega''s', n; end if;

  select (select count(*) from facturen) + (select count(*) from factuur_lijnen) into n;
  if n <> 0 then raise exception '2 tech: ziet % facturen/factuurlijnen', n; end if;

  select count(*) into n from medewerkers;
  if n <> 1 then raise exception '2 tech: ziet % medewerkers, verwacht 1', n; end if;

  select count(*) into n from artikelen;
  if n = 0 then raise exception '2 tech: ziet geen artikelen'; end if;
end $$;
select '2 technieker' as controle, 'ok' as resultaat;

-- ── 3. Conceptflow ───────────────────────────
-- De verwerking (service role) schrijft een conceptbon met lijnen en een opname, zonder nummer.
:als_service
insert into werfbonnen (interventie_id, technieker_id, datum, uren, km, status, bron, getekend_door_klant)
values (:interventie, :tech, peildatum(), 2, 18, 'concept', 'spraak', true)
returning id as bon, nummer as bon_nummer \gset

insert into werfbon_lijnen (werfbon_id, artikel_id, aantal)
values (:bon, :art_arbeid, 2), (:bon, :art_verpl, 1);

insert into werfbon_opnames (interventie_id, technieker_id, werfbon_id, type, storage_pad, transcript, model)
values (:interventie, :tech, :bon, 'audio', :'tech' || '/' || :'interventie' || '/test.m4a', 'test', 'test');

-- Een conceptbon van de collega, om weigeringen op te testen.
insert into werfbonnen (interventie_id, technieker_id, datum, uren, km, status, bron)
values (:collega_interventie, :collega, peildatum(), 1, 0, 'concept', 'foto')
returning id as collega_bon \gset

reset role;
select set_config('t.bon', :'bon', true), set_config('t.collega_bon', :'collega_bon', true) \g /dev/null

do $$
declare
  v_bon bigint := current_setting('t.bon')::bigint;
  v_nr  text;
begin
  select nummer into v_nr from werfbonnen where id = v_bon;
  if v_nr is distinct from 'WB-' || to_char(peildatum(), 'YYYY') || '-' || lpad(v_bon::text, 5, '0') then
    raise exception '3 nummer: %, verwacht WB-jaar-%', v_nr, lpad(v_bon::text, 5, '0');
  end if;
  if (select bron from werfbonnen where id = v_bon) <> 'spraak' then raise exception '3 bron niet bewaard'; end if;
end $$;

-- 6. De achterstand verandert niet door een conceptbon.
select (select row(v.*)::text from v_facturatie_achterstand v) as achterstand_na \gset
select '6 achterstand' as controle,
       case when :'achterstand_voor' = :'achterstand_na' then 'ok: ' || :'achterstand_na'
            else (select 'achterstand veranderd: ' || :'achterstand_voor' || ' → ' || :'achterstand_na')::int::text
       end as resultaat;

-- De technieker past zijn conceptbon aan.
:als_tech
do $$
declare
  v_bon bigint := current_setting('t.bon')::bigint;
  n bigint;
begin
  update werfbonnen set uren = 3, opmerkingen = 'test' where id = v_bon;
  get diagnostics n = row_count;
  if n <> 1 then raise exception '3 tech: update van eigen conceptbon raakte % rijen', n; end if;

  insert into werfbon_lijnen (werfbon_id, artikel_id, aantal)
  values (v_bon, current_setting('t.art_arbeid')::bigint, 1);

  select count(*) into n from werfbon_lijnen where werfbon_id = v_bon;
  if n <> 3 then raise exception '3 tech: ziet % lijnen op de eigen bon, verwacht 3', n; end if;

  select count(*) into n from werfbon_opnames;
  if n <> 1 then raise exception '3 tech: ziet % opnames, verwacht 1', n; end if;
end $$;

select '3 status zelf zetten' as controle,
       pg_temp.verwacht_fout(format('update werfbonnen set status = %L where id = %s', 'ingegeven', :bon), '42501', null) as resultaat
union all
select '3 nummer wijzigen',
       pg_temp.verwacht_fout(format('update werfbonnen set nummer = %L where id = %s', 'X', :bon), '42501', null)
union all
select '3 lijn op bon collega',
       pg_temp.verwacht_fout(format('insert into werfbon_lijnen (werfbon_id, artikel_id, aantal) values (%s, %s, 1)',
                                    :collega_bon, :art_arbeid), '42501', 'row-level security');

-- Voorstel berekenen (zonder RLS) en bevestigen (als technieker).
reset role;
select round(sum(aantal * eenheidsprijs), 2) as voorstel from factuurvoorstel(:bon) \gset

:als_tech
select bevestig_werfbon(:bon) as factuur \gset

reset role;
select set_config('t.factuur', :'factuur', true), set_config('t.voorstel', :'voorstel', true) \g /dev/null
do $$
declare
  v_bon     bigint := current_setting('t.bon')::bigint;
  v_factuur bigint := nullif(current_setting('t.factuur'), '')::bigint;
  b record;
  f record;
begin
  if v_factuur is null then raise exception '3 bevestig: geen factuur-id terug'; end if;
  select * into b from werfbonnen where id = v_bon;
  select * into f from facturen where id = v_factuur;
  if b.status <> 'ingegeven' or b.ingegeven_op <> peildatum() or b.factuur_id is distinct from v_factuur then
    raise exception '3 bevestig: bon % / % / %', b.status, b.ingegeven_op, b.factuur_id;
  end if;
  if f.status <> 'concept' then raise exception '3 bevestig: factuur heeft status %', f.status; end if;
  if f.totaal_excl_btw <> current_setting('t.voorstel')::numeric then
    raise exception '3 bevestig: totaal %, voorstel %', f.totaal_excl_btw, current_setting('t.voorstel');
  end if;
  if (select uren from werfbonnen where id = v_bon) <> 3 then raise exception '3 aanpassing uren niet bewaard'; end if;
end $$;

-- Na bevestigen is de bon niet meer aan te passen.
:als_tech
do $$
declare
  v_bon bigint := current_setting('t.bon')::bigint;
  n bigint;
begin
  update werfbonnen set uren = 4 where id = v_bon;
  get diagnostics n = row_count;
  if n <> 0 then raise exception '3 tech: update na bevestigen raakte % rijen', n; end if;

  delete from werfbon_lijnen where werfbon_id = v_bon;
  get diagnostics n = row_count;
  if n <> 0 then raise exception '3 tech: delete van lijnen na bevestigen raakte % rijen', n; end if;

  select count(*) into n from facturen;
  if n <> 0 then raise exception '3 tech: ziet % facturen na bevestigen', n; end if;
end $$;
select '3 conceptflow' as controle, 'ok: bon ' || :'bon_nummer' || ', factuur ' || :'factuur' || ', totaal ' || :'voorstel' as resultaat;

-- ── 4. Weigeringen voor de technieker ────────
select '4 maak_conceptfactuur direct' as controle,
       pg_temp.verwacht_fout(format('select public.maak_conceptfactuur(%s)', :collega_bon), '42501', null) as resultaat
union all
select '4 bevestig bon collega',
       pg_temp.verwacht_fout(format('select public.bevestig_werfbon(%s)', :collega_bon), '42501', 'niet van jou')
union all
select '4 bevestig tweede keer',
       pg_temp.verwacht_fout(format('select public.bevestig_werfbon(%s)', :bon), null, 'alleen een conceptbon')
union all
select '4 keur_factuur_goed',
       pg_temp.verwacht_fout(format('select public.keur_factuur_goed(%s)', :factuur), '42501', 'alleen de administratie')
union all
select '4 insert in facturen',
       pg_temp.verwacht_fout(
         format('insert into facturen (nummer, klant_id, factuurdatum, vervaldatum, btw_tarief, totaal_excl_btw, status)'
                ' select %L, klant_id, peildatum(), peildatum() + 30, 6, 1, %L from interventies limit 1',
                'FA-TEST', 'concept'),
         '42501', 'row-level security');

-- ── 5. Administratie ─────────────────────────
:als_admin
do $$
declare
  v_factuur bigint := current_setting('t.factuur')::bigint;
  n bigint;
begin
  if not public.is_administratie() then raise exception '5 admin: is_administratie() is false'; end if;

  select count(*) into n from werfbonnen;
  if n <> current_setting('t.n_bonnen')::bigint + 2 then
    raise exception '5 admin: ziet % bonnen, verwacht %', n, current_setting('t.n_bonnen')::bigint + 2;
  end if;
  select count(*) into n from klanten;
  if n <> current_setting('t.n_alle_klanten')::bigint then raise exception '5 admin: ziet % klanten', n; end if;
  select count(*) into n from facturen where id = v_factuur and status = 'concept';
  if n <> 1 then raise exception '5 admin: ziet de conceptfactuur niet'; end if;
  select count(*) into n from factuur_lijnen where factuur_id = v_factuur;
  if n = 0 then raise exception '5 admin: ziet geen factuurlijnen'; end if;
  select count(*) into n from werfbon_opnames;
  if n <> 1 then raise exception '5 admin: ziet % opnames, verwacht 1', n; end if;

  -- Bijwerken mag de administratie niet rechtstreeks.
  update facturen set status = 'verstuurd' where id = v_factuur;
  get diagnostics n = row_count;
  if n <> 0 then raise exception '5 admin: rechtstreekse update van een factuur raakte % rijen', n; end if;
end $$;

select '5 admin bevestigt bon technieker' as controle,
       pg_temp.verwacht_fout(format('select public.bevestig_werfbon(%s)', :collega_bon), '42501', null) as resultaat;

select keur_factuur_goed(:factuur) \g /dev/null

reset role;
do $$
declare
  v_factuur bigint := current_setting('t.factuur')::bigint;
begin
  if (select status from facturen where id = v_factuur) <> 'verstuurd' then
    raise exception '5 goedkeuren: factuur niet verstuurd';
  end if;
  if (select status from werfbonnen where id = current_setting('t.bon')::bigint) <> 'gefactureerd' then
    raise exception '5 goedkeuren: bon niet gefactureerd';
  end if;
end $$;

:als_admin
select '5 tweede keer goedkeuren' as controle,
       pg_temp.verwacht_fout(format('select public.keur_factuur_goed(%s)', :factuur), null, 'alleen een conceptfactuur') as resultaat;

-- ── 7. Storage ───────────────────────────────
:als_tech
insert into storage.objects (bucket_id, name)
values ('werfbon-opnames', :'tech' || '/' || :'interventie' || '/test-0004.m4a');

select '7 upload onder id collega' as controle,
       pg_temp.verwacht_fout(format('insert into storage.objects (bucket_id, name) values (%L, %L)',
                                    'werfbon-opnames', :'collega' || '/' || :'collega_interventie' || '/x.m4a'),
                             '42501', 'row-level security') as resultaat
union all
select '7 upload voor interventie collega',
       pg_temp.verwacht_fout(format('insert into storage.objects (bucket_id, name) values (%L, %L)',
                                    'werfbon-opnames', :'tech' || '/' || :'collega_interventie' || '/x.m4a'),
                             '42501', 'row-level security')
union all
select '7 upload met vreemd pad',
       pg_temp.verwacht_fout(format('insert into storage.objects (bucket_id, name) values (%L, %L)',
                                    'werfbon-opnames', :'tech' || '/abc/x.m4a'),
                             '42501', 'row-level security');

do $$
begin
  if (select count(*) from storage.objects where bucket_id = 'werfbon-opnames') <> 1 then
    raise exception '7 tech: ziet de eigen upload niet (of meer dan één object)';
  end if;
end $$;

:als_admin
do $$
begin
  if (select count(*) from storage.objects where bucket_id = 'werfbon-opnames') <> 1 then
    raise exception '7 admin: ziet de upload niet';
  end if;
end $$;

:als_anon
do $$
begin
  if (select count(*) from storage.objects where bucket_id = 'werfbon-opnames') <> 0 then
    raise exception '7 anon: ziet objecten in de bucket';
  end if;
end $$;
select '7 storage' as controle, 'ok' as resultaat;

reset role;
select 'ALLES OK' as resultaat;

rollback;
