-- Peildatum: de "vandaag" van de fictieve data.
-- De views rekenden met current_date, waardoor de achterstand elke echte dag opliep zonder dat de data veranderde.
-- seed.sql herdefinieert deze functie met VANDAAG uit scripts/generate_seed.py.

create or replace function peildatum()
returns date
language sql
stable
set search_path = ''
as $$ select date '2026-11-05' $$;

-- security_invoker: de view draait met de rechten van wie hem opvraagt, zodat RLS op de onderliggende tabellen geldt.
create or replace view v_facturatie_achterstand with (security_invoker = true) as
select
  count(*)                                   as open_werfbonnen,
  min(datum)                                 as oudste_bon,
  round(avg(peildatum() - datum), 1)         as gem_dagen_open,
  sum(uren)                                  as open_uren
from werfbonnen
where status <> 'gefactureerd';

alter view v_offerte_opvolging set (security_invoker = true);
