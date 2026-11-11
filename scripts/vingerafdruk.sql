-- Vingerafdruk van de data die de conceptfactuur raakt. Alleen lezen.
-- Draai dit op live (read-only) en op een lokale kopie: zijn de rijen gelijk, dan test de lokale kopie dezelfde data.
--
--   psql "$DATABASE_URL" -X -A -F ' | ' -f scripts/vingerafdruk.sql

select 'bonnen ' || i.type                                         as onderdeel,
       count(*)::text || ' bonnen, '
       || count(*) filter (where w.status = 'gefactureerd') || ' gefactureerd, '
       || count(distinct w.factuur_id) || ' facturen'                as waarde
from public.werfbonnen w
join public.interventies i on i.id = w.interventie_id
group by i.type

union all
select 'md5 werfbonnen',
       md5(string_agg(concat_ws('|', id, interventie_id, uren, km, status, factuur_id, getekend_door_klant),
                      ',' order by id))
from public.werfbonnen

union all
select 'md5 werfbon_lijnen',
       md5(string_agg(concat_ws('|', id, werfbon_id, artikel_id, aantal), ',' order by id))
from public.werfbon_lijnen

union all
select 'md5 facturen',
       md5(string_agg(concat_ws('|', id, nummer, klant_id, btw_tarief, totaal_excl_btw), ',' order by id))
from public.facturen

union all
select 'md5 factuur_lijnen',
       md5(string_agg(concat_ws('|', id, factuur_id, omschrijving, aantal, eenheidsprijs), ',' order by id))
from public.factuur_lijnen

union all
select 'md5 artikelen',
       md5(string_agg(concat_ws('|', id, code, omschrijving, categorie, verkoopprijs), ',' order by id))
from public.artikelen

union all
select 'md5 contracten',
       md5(string_agg(concat_ws('|', id, klant_id, toesteltype, merk, model, jaarprijs), ',' order by id))
from public.onderhoudscontracten

union all
select 'md5 klanten (id, type)',
       md5(string_agg(concat_ws('|', id, type), ',' order by id))
from public.klanten

order by 1;
