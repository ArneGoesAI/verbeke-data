-- Test van laag c: geeft factuurvoorstel() voor elke gefactureerde herstel- en onderhoudsbon dezelfde factuur als de
-- bestaande? Alleen lezen: de query roept alleen stable functies aan en mag dus ook op live draaien (na db push).
--
--   psql "$DATABASE_URL" -X -A -F ' | ' -v ON_ERROR_STOP=1 -c 'begin read only' -f scripts/test_conceptfactuur.sql
--
-- Uitvoer: eerst een overzicht per type, dan elke afwijking, en als laatste rij het eindoordeel.
-- Verwacht: 261 onderhoudsbonnen en 92 herstelbonnen, overal gelijk.
-- De rij "waarschuwingen" telt de onderhoudsbonnen met een onderdeel (alle statussen); het appplan noemt er 123.

with populatie as (
  select w.id as werfbon_id, i.type, i.klant_id, w.factuur_id
  from public.werfbonnen w
  join public.interventies i on i.id = w.interventie_id
  where w.status = 'gefactureerd'
    and i.type in ('herstelling', 'onderhoud')
),
verwacht as (
  select p.werfbon_id, v.omschrijving, v.aantal, v.eenheidsprijs
  from populatie p
  cross join lateral public.factuurvoorstel(p.werfbon_id) v
),
bestaand as (
  select p.werfbon_id, l.omschrijving, l.aantal, l.eenheidsprijs
  from populatie p
  join public.factuur_lijnen l on l.factuur_id = p.factuur_id
),
-- Lijnen als multiset: per (bon, omschrijving, aantal, prijs) het aantal keer aan elke kant.
lijnverschil as (
  select werfbon_id, omschrijving, aantal, eenheidsprijs,
         coalesce(v.n, 0) as verwacht_n,
         coalesce(b.n, 0) as bestaand_n
  from (select werfbon_id, omschrijving, aantal, eenheidsprijs, count(*) as n
        from verwacht group by 1, 2, 3, 4) v
  full join (select werfbon_id, omschrijving, aantal, eenheidsprijs, count(*) as n
             from bestaand group by 1, 2, 3, 4) b
    using (werfbon_id, omschrijving, aantal, eenheidsprijs)
  where coalesce(v.n, 0) <> coalesce(b.n, 0)
),
per_bon as (
  select p.werfbon_id, p.type, p.factuur_id,
         p.klant_id                          as v_klant,  f.klant_id         as b_klant,
         public.btw_tarief_voor(p.klant_id)  as v_btw,    f.btw_tarief       as b_btw,
         (select round(sum(v.aantal * v.eenheidsprijs), 2)
          from verwacht v where v.werfbon_id = p.werfbon_id) as v_totaal,
         f.totaal_excl_btw                   as b_totaal,
         (select count(*) from public.werfbonnen w2 where w2.factuur_id = p.factuur_id) as bonnen_op_factuur,
         not exists (select 1 from lijnverschil d where d.werfbon_id = p.werfbon_id) as lijnen_ok
  from populatie p
  left join public.facturen f on f.id = p.factuur_id
),
controles as (
  select b.*,
         b.lijnen_ok
           and b.v_totaal is not distinct from b.b_totaal
           and b.v_btw = b.b_btw
           and b.v_klant = b.b_klant
           and b.bonnen_op_factuur = 1 as alles_ok
  from per_bon b
),
afwijkingen as (
  select type, werfbon_id, factuur_id, 'totaal: verwacht ' || coalesce(v_totaal::text, '-')
         || ', bestaand ' || coalesce(b_totaal::text, '-') as resultaat
  from controles where v_totaal is distinct from b_totaal
  union all
  select type, werfbon_id, factuur_id, 'btw: verwacht ' || v_btw || ', bestaand ' || coalesce(b_btw::text, '-')
  from controles where v_btw is distinct from b_btw
  union all
  select type, werfbon_id, factuur_id, 'klant: verwacht ' || v_klant || ', bestaand ' || coalesce(b_klant::text, '-')
  from controles where v_klant is distinct from b_klant
  union all
  select type, werfbon_id, factuur_id, 'factuur heeft ' || bonnen_op_factuur || ' bonnen'
  from controles where bonnen_op_factuur <> 1
  union all
  select c.type, d.werfbon_id, c.factuur_id,
         'lijn "' || d.omschrijving || '" × ' || trim_scale(d.aantal) || ' à ' || d.eenheidsprijs
         || ': verwacht ' || d.verwacht_n || ', bestaand ' || d.bestaand_n
  from lijnverschil d join controles c using (werfbon_id)
),
waarschuwingen as (
  select count(*) filter (where exists (
           select 1 from unnest(public.factuurwaarschuwingen(w.id)) t
           where t like 'onderdeel op onderhoudsbon%')) as onderhoud_met_onderdeel,
         count(*) filter (where exists (
           select 1 from unnest(public.factuurwaarschuwingen(w.id)) t
           where t like 'arbeid op de bon%')) as arbeid_wijkt_af
  from public.werfbonnen w
  join public.interventies i on i.id = w.interventie_id
  where i.type in ('herstelling', 'onderhoud')
)
select soort, type, werfbon_id, factuur_id, resultaat
from (
  select 1 as o, 'overzicht' as soort, type, null::bigint as werfbon_id, null::bigint as factuur_id,
         count(*) || ' bonnen | alles gelijk ' || count(*) filter (where alles_ok)
         || ' | lijnen ' || count(*) filter (where lijnen_ok)
         || ' | totaal ' || count(*) filter (where v_totaal is not distinct from b_totaal)
         || ' | btw ' || count(*) filter (where v_btw = b_btw)
         || ' | klant ' || count(*) filter (where v_klant = b_klant)
         || ' | 1 bon per factuur ' || count(*) filter (where bonnen_op_factuur = 1)
         || ' | som verwacht ' || coalesce(sum(v_totaal), 0) || ', bestaand ' || coalesce(sum(b_totaal), 0) as resultaat
  from controles
  group by type

  union all
  select 2, 'waarschuwingen', 'alle', null, null,
         onderhoud_met_onderdeel || ' onderhoudsbonnen met een onderdeel | '
         || arbeid_wijkt_af || ' herstelbonnen waar de arbeid afwijkt van de uren'
  from waarschuwingen

  union all
  select 3, 'afwijking', type, werfbon_id, factuur_id, resultaat
  from afwijkingen

  union all
  select 4, 'eindoordeel', 'alle', null, null,
         case when (select count(*) from controles) = 0 then 'GEEN BONNEN GEVONDEN'
              when (select count(*) from afwijkingen) = 0 then 'ALLES GELIJK'
              else (select count(*) from afwijkingen) || ' AFWIJKINGEN' end
) r
order by o, type, werfbon_id, resultaat;
