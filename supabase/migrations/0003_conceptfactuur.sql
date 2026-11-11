-- Conceptfactuur voor een werfbon (laag c van docs/plan-werfbon-app.md).
--
-- De AI haalt alleen gegevens uit de bon. Prijzen, btw en factuurlijnen komen uit deze regels, dezelfde als die van
-- de bestaande facturen (scripts/generate_seed.py):
--   onderhoud:   één lijn "Jaarlijks onderhoud {toesteltype} {merk} {model}" aan de jaarprijs van het contract.
--                Een extra onderdeel op de bon wordt niet aangerekend, maar komt als waarschuwing bij de factuur
--                (open punt in §7 van het plan: zit het in het contract of niet?).
--   herstelling: elke bonlijn (arbeid, VERPL-forfait, onderdelen) × verkoopprijs, met de artikelomschrijving.
--   btw:         6% voor een particulier, 21% voor een bedrijf.
-- Alleen herstelling en onderhoud. Een installatie wordt gefactureerd volgens de offerte, per werf.
--
-- Test: scripts/test_conceptfactuur.sql (read-only, vergelijkt met de bestaande facturen) en
-- scripts/test_maak_conceptfactuur.sql (alleen lokaal, schrijft in een transactie met rollback).

-- ─────────────────────────────────────────────
-- Herkomst van een factuurlijn
-- ─────────────────────────────────────────────

alter table factuur_lijnen
  add column artikel_id bigint references artikelen(id),
  add column werfbon_id bigint references werfbonnen(id);

comment on column factuur_lijnen.artikel_id is 'Catalogusartikel van de lijn. Null bij facturen van vóór 0003.';
comment on column factuur_lijnen.werfbon_id is 'Werfbon waaruit de lijn komt. Null bij facturen van vóór 0003.';

create index on factuur_lijnen (werfbon_id);

-- ─────────────────────────────────────────────
-- btw
-- ─────────────────────────────────────────────

create or replace function btw_tarief_voor(p_klant_id bigint)
returns numeric
language sql
stable
set search_path = ''
as $$
  select case k.type when 'particulier' then 6 when 'bedrijf' then 21 end::numeric
  from public.klanten k
  where k.id = p_klant_id
$$;

comment on function btw_tarief_voor(bigint) is
  'btw-tarief volgens het klanttype: 6 voor een particulier, 21 voor een bedrijf. Uitzonderingen kijkt de administratie na.';

-- ─────────────────────────────────────────────
-- Factuurvoorstel: de lijnen, zonder iets weg te schrijven
-- ─────────────────────────────────────────────

create or replace function factuurvoorstel(p_werfbon_id bigint)
returns table (volgorde integer, omschrijving text, aantal numeric, eenheidsprijs numeric, artikel_id bigint)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_type     text;
  v_contract bigint;
begin
  select i.type, i.contract_id
    into v_type, v_contract
  from public.werfbonnen w
  join public.interventies i on i.id = w.interventie_id
  where w.id = p_werfbon_id;

  if not found then
    raise exception 'werfbon % bestaat niet', p_werfbon_id;
  end if;

  if v_type = 'onderhoud' then
    -- Zonder contract geen lijn: factuurwaarschuwingen meldt het, maak_conceptfactuur weigert een leeg voorstel.
    return query
      select 1,
             'Jaarlijks onderhoud ' || c.toesteltype || ' ' || c.merk || ' ' || c.model,
             1::numeric,
             c.jaarprijs::numeric,
             a.id
      from public.onderhoudscontracten c
      left join public.artikelen a on a.code = case c.toesteltype
                                                 when 'warmtepomp'  then 'ARB-ONDERH-WP'
                                                 when 'ventilatie'  then 'ARB-ONDERH-VENT'
                                                 when 'zonneboiler' then 'ARB-ONDERH-ZB'
                                               end
      where c.id = v_contract;

  elsif v_type = 'herstelling' then
    return query
      select (row_number() over (order by case a.code when 'ARB-TECH' then 0 when 'VERPL' then 1 else 2 end, l.id))::integer,
             a.omschrijving,
             l.aantal::numeric,
             a.verkoopprijs::numeric,
             a.id
      from public.werfbon_lijnen l
      join public.artikelen a on a.id = l.artikel_id
      where l.werfbon_id = p_werfbon_id
      order by 1;

  else
    raise exception 'werfbon % is van type %: alleen herstelling en onderhoud krijgen een conceptfactuur',
      p_werfbon_id, v_type;
  end if;
end
$$;

comment on function factuurvoorstel(bigint) is
  'Factuurlijnen voor een herstel- of onderhoudsbon, zonder neveneffecten. Basis voor maak_conceptfactuur en de test.';

-- ─────────────────────────────────────────────
-- Waarschuwingen voor de administratie
-- ─────────────────────────────────────────────

create or replace function factuurwaarschuwingen(p_werfbon_id bigint)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(x.tekst order by x.o, x.tekst), '{}')
  from (
    select 1 as o, 'niet getekend door de klant' as tekst
    from public.werfbonnen w
    where w.id = p_werfbon_id and not w.getekend_door_klant

    union all
    select 2, 'ongewoon veel uren: ' || trim_scale(w.uren)
    from public.werfbonnen w
    where w.id = p_werfbon_id and w.uren > 8

    union all
    select 3, 'onderhoud zonder contract: geen jaarprijs'
    from public.werfbonnen w
    join public.interventies i on i.id = w.interventie_id
    where w.id = p_werfbon_id and i.type = 'onderhoud' and i.contract_id is null

    union all
    select 4, 'onderdeel op onderhoudsbon, niet aangerekend: ' || a.code || ' × ' || trim_scale(l.aantal)
    from public.werfbonnen w
    join public.interventies i on i.id = w.interventie_id
    join public.werfbon_lijnen l on l.werfbon_id = w.id
    join public.artikelen a on a.id = l.artikel_id
    where w.id = p_werfbon_id and i.type = 'onderhoud' and a.categorie <> 'arbeid'

    union all
    select 5, 'arbeid op de bon (' || trim_scale(coalesce(arb.uren, 0)) || ' u) wijkt af van de uren ('
              || trim_scale(w.uren) || ' u)'
    from public.werfbonnen w
    join public.interventies i on i.id = w.interventie_id
    cross join lateral (
      select sum(l.aantal) as uren
      from public.werfbon_lijnen l
      join public.artikelen a on a.id = l.artikel_id
      where l.werfbon_id = w.id and a.code = 'ARB-TECH'
    ) arb
    where w.id = p_werfbon_id and i.type = 'herstelling' and coalesce(arb.uren, 0) <> w.uren
  ) x
$$;

comment on function factuurwaarschuwingen(bigint) is
  'Punten die de administratie moet nakijken voor ze een conceptfactuur goedkeurt.';

-- ─────────────────────────────────────────────
-- Conceptfactuur aanmaken
-- ─────────────────────────────────────────────

create or replace function maak_conceptfactuur(p_werfbon_id bigint)
returns bigint
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_bon    record;
  v_datum  date := public.peildatum();
  v_aantal integer;
  v_totaal numeric;
  v_id     bigint;
begin
  select w.id, w.status, w.factuur_id, i.type, i.klant_id
    into v_bon
  from public.werfbonnen w
  join public.interventies i on i.id = w.interventie_id
  where w.id = p_werfbon_id
  for update of w;

  if not found then
    raise exception 'werfbon % bestaat niet', p_werfbon_id;
  end if;
  if v_bon.type not in ('herstelling', 'onderhoud') then
    raise exception 'werfbon % is van type %: alleen herstelling en onderhoud krijgen een conceptfactuur',
      p_werfbon_id, v_bon.type;
  end if;
  if v_bon.factuur_id is not null then
    raise exception 'werfbon % heeft al factuur %', p_werfbon_id, v_bon.factuur_id;
  end if;
  if v_bon.status <> 'ingegeven' then
    raise exception 'werfbon % heeft status %: alleen een ingegeven bon krijgt een conceptfactuur',
      p_werfbon_id, v_bon.status;
  end if;

  select count(*), round(sum(v.aantal * v.eenheidsprijs), 2)
    into v_aantal, v_totaal
  from public.factuurvoorstel(p_werfbon_id) v;

  if v_aantal = 0 then
    raise exception 'werfbon % levert geen factuurlijnen op', p_werfbon_id;
  end if;

  -- Eerst het id, zodat het nummer meteen het patroon van de bestaande facturen volgt: FA-{jaar}-{id, 5 cijfers}.
  v_id := nextval(pg_get_serial_sequence('public.facturen', 'id'));

  insert into public.facturen
    (id, nummer, klant_id, factuurdatum, vervaldatum, btw_tarief, totaal_excl_btw, status)
  overriding system value
  values
    (v_id,
     'FA-' || to_char(v_datum, 'YYYY') || '-' || lpad(v_id::text, greatest(5, length(v_id::text)), '0'),
     v_bon.klant_id,
     v_datum,
     v_datum + 30,
     public.btw_tarief_voor(v_bon.klant_id),
     v_totaal,
     'concept');

  insert into public.factuur_lijnen (factuur_id, omschrijving, aantal, eenheidsprijs, artikel_id, werfbon_id)
  select v_id, v.omschrijving, v.aantal, v.eenheidsprijs, v.artikel_id, p_werfbon_id
  from public.factuurvoorstel(p_werfbon_id) v
  order by v.volgorde;

  -- De bon blijft 'ingegeven'. 'gefactureerd' volgt pas als de administratie de factuur goedkeurt (laag d).
  update public.werfbonnen set factuur_id = v_id where id = p_werfbon_id;

  return v_id;
end
$$;

comment on function maak_conceptfactuur(bigint) is
  'Maakt een conceptfactuur (status concept) voor een ingegeven herstel- of onderhoudsbon en koppelt de bon eraan.';

-- ─────────────────────────────────────────────
-- Werklijst voor de administratie
-- ─────────────────────────────────────────────

create or replace view v_werfbon_te_factureren with (security_invoker = true) as
select
  w.id                                   as werfbon_id,
  w.nummer,
  i.type,
  i.klant_id,
  w.datum,
  public.peildatum() - w.datum           as dagen_open,
  (select round(sum(v.aantal * v.eenheidsprijs), 2)
   from public.factuurvoorstel(w.id) v)  as totaal_excl_btw,
  public.btw_tarief_voor(i.klant_id)     as btw_tarief,
  public.factuurwaarschuwingen(w.id)     as waarschuwingen
from public.werfbonnen w
join public.interventies i on i.id = w.interventie_id
where w.status = 'ingegeven'
  and w.factuur_id is null
  and i.type in ('herstelling', 'onderhoud');
