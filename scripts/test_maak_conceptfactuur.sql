-- Test van maak_conceptfactuur() zelf. SCHRIJFT, maar alles in één transactie die eindigt met rollback.
-- Alleen op een lokale kopie draaien, nooit op live.
--
--   psql -X -v ON_ERROR_STOP=1 -d verbeke -f scripts/test_maak_conceptfactuur.sql
--
-- 1. Weigeringen: installatiebon, bon met factuur, bon op papier, onbestaande bon.
-- 2. Rondreis: elke gefactureerde herstel- en onderhoudsbon terug naar 'ingegeven' zonder factuur, opnieuw factureren
--    met maak_conceptfactuur en de nieuwe factuur vergelijken met de oude.
-- 3. Dubbele aanroep wordt geweigerd.
-- 4. View: een bon die een concept krijgt, verdwijnt uit v_werfbon_te_factureren, met hetzelfde totaal.
-- Elke mislukte controle stopt het script met een exception. Op het einde staat "ALLES OK".

\set ON_ERROR_STOP on

do $$
begin
  if current_setting('transaction_read_only') = 'on' then
    raise exception 'de verbinding is read-only: dit script schrijft en hoort op een lokale kopie';
  end if;
end $$;

begin;

-- Verwacht dat de aanroep weigert met een foutmelding die op het patroon past.
create function pg_temp.verwacht_weigering(p_bon bigint, p_patroon text)
returns text
language plpgsql
as $$
begin
  begin
    perform public.maak_conceptfactuur(p_bon);
  exception when others then
    if sqlerrm ~ p_patroon then
      return 'ok: ' || sqlerrm;
    end if;
    raise exception 'bon %: verkeerde fout: %', p_bon, sqlerrm;
  end;
  raise exception 'bon % werd niet geweigerd (verwacht: %)', p_bon, p_patroon;
end
$$;

-- ── 1. Weigeringen ───────────────────────────
select 'installatie' as geval, pg_temp.verwacht_weigering(
  (select w.id from werfbonnen w join interventies i on i.id = w.interventie_id
   where i.type = 'installatie' and w.status = 'ingegeven' and w.factuur_id is null order by w.id limit 1),
  'alleen herstelling en onderhoud') as resultaat
union all
select 'al gefactureerd', pg_temp.verwacht_weigering(
  (select w.id from werfbonnen w join interventies i on i.id = w.interventie_id
   where i.type = 'herstelling' and w.factuur_id is not null order by w.id limit 1),
  'heeft al factuur')
union all
select 'op papier', pg_temp.verwacht_weigering(
  (select w.id from werfbonnen w join interventies i on i.id = w.interventie_id
   where i.type = 'onderhoud' and w.status = 'op_papier' order by w.id limit 1),
  'alleen een ingegeven bon')
union all
select 'onbestaand', pg_temp.verwacht_weigering(-1, 'bestaat niet');

-- ── 2. Rondreis ──────────────────────────────
create temp table oud as
select w.id as werfbon_id, i.type, w.factuur_id as oude_factuur
from werfbonnen w
join interventies i on i.id = w.interventie_id
where w.status = 'gefactureerd' and i.type in ('herstelling', 'onderhoud');

update werfbonnen w
set factuur_id = null, status = 'ingegeven'
from oud
where w.id = oud.werfbon_id;

create temp table nieuw as
select werfbon_id, public.maak_conceptfactuur(werfbon_id) as nieuwe_factuur
from oud
order by werfbon_id;

create temp table vergelijking as
select o.type, o.werfbon_id, o.oude_factuur, n.nieuwe_factuur,
       fo.klant_id = fn.klant_id                                  as klant_ok,
       fo.btw_tarief = fn.btw_tarief                              as btw_ok,
       fo.totaal_excl_btw = fn.totaal_excl_btw                    as totaal_ok,
       fn.status = 'concept'
         and fn.factuurdatum = public.peildatum()
         and fn.vervaldatum = public.peildatum() + 30
         and fn.nummer = 'FA-' || to_char(public.peildatum(), 'YYYY') || '-' || lpad(fn.id::text, 5, '0')
                                                                  as kop_ok,
       (select count(*) from werfbonnen w where w.id = o.werfbon_id and w.factuur_id = fn.id
                                             and w.status = 'ingegeven') = 1 as bon_ok,
       not exists (select 1 from factuur_lijnen l
                   where l.factuur_id = fn.id
                     and (l.artikel_id is null or l.werfbon_id is distinct from o.werfbon_id)) as herkomst_ok,
       not exists (
         (select omschrijving, aantal, eenheidsprijs from factuur_lijnen where factuur_id = fo.id
          except all
          select omschrijving, aantal, eenheidsprijs from factuur_lijnen where factuur_id = fn.id)
         union all
         (select omschrijving, aantal, eenheidsprijs from factuur_lijnen where factuur_id = fn.id
          except all
          select omschrijving, aantal, eenheidsprijs from factuur_lijnen where factuur_id = fo.id)
       )                                                          as lijnen_ok
from oud o
join nieuw n using (werfbon_id)
join facturen fo on fo.id = o.oude_factuur
join facturen fn on fn.id = n.nieuwe_factuur;

select type,
       count(*)                                  as bonnen,
       count(*) filter (where lijnen_ok)         as lijnen_ok,
       count(*) filter (where totaal_ok)         as totaal_ok,
       count(*) filter (where btw_ok)            as btw_ok,
       count(*) filter (where klant_ok)          as klant_ok,
       count(*) filter (where kop_ok)            as kop_ok,
       count(*) filter (where bon_ok)            as bon_ok,
       count(*) filter (where herkomst_ok)       as herkomst_ok
from vergelijking
group by type
order by type;

do $$
declare
  v_fout integer;
begin
  select count(*) into v_fout
  from vergelijking
  where not (lijnen_ok and totaal_ok and btw_ok and klant_ok and kop_ok and bon_ok and herkomst_ok);
  if v_fout > 0 then
    raise exception 'rondreis: % bonnen wijken af', v_fout;
  end if;
  if (select count(*) from vergelijking) <> (select count(*) from oud) then
    raise exception 'rondreis: niet elke bon kon vergeleken worden';
  end if;
end $$;

-- ── 3. Dubbele aanroep ───────────────────────
select 'dubbele aanroep' as geval,
       pg_temp.verwacht_weigering((select min(werfbon_id) from nieuw), 'heeft al factuur') as resultaat;

-- ── 4. View ──────────────────────────────────
create temp table viewtest as
select werfbon_id, totaal_excl_btw
from v_werfbon_te_factureren
order by werfbon_id
limit 1;

select 'view' as geval, count(*) as bonnen_in_view from v_werfbon_te_factureren;

do $$
declare
  v_bon     bigint;
  v_totaal  numeric;
  v_factuur bigint;
begin
  select werfbon_id, totaal_excl_btw into v_bon, v_totaal from viewtest;
  if v_bon is null then
    raise exception 'view: geen enkele bon te factureren, test niet mogelijk';
  end if;
  v_factuur := public.maak_conceptfactuur(v_bon);
  if exists (select 1 from public.v_werfbon_te_factureren where werfbon_id = v_bon) then
    raise exception 'view: bon % staat er nog na het concept', v_bon;
  end if;
  if (select totaal_excl_btw from public.facturen where id = v_factuur) <> v_totaal then
    raise exception 'view: totaal in de view (%) verschilt van de factuur', v_totaal;
  end if;
end $$;

select 'ALLES OK' as eindoordeel;

rollback;
