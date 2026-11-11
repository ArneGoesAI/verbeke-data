-- Werfbon-app (laag d van docs/plan-werfbon-app.md, uitgewerkt in docs/plan-stap-8.md, deel 1).
--
-- De technieker spreekt een bon in of fotografeert hem. De verwerking (service role) schrijft een bon in status
-- 'concept' met lijnen en een opname. De technieker past aan en bevestigt (bevestig_werfbon), wat meteen een
-- conceptfactuur maakt. De administratie keurt die goed (keur_factuur_goed).
--
-- Rechten: de app leest en schrijft met de sessie van de gebruiker (rol authenticated). RLS bepaalt wat iemand ziet.
-- anon krijgt niets. Statusovergangen gaan alleen via security-definer-functies die zelf controleren wie belt.
--
-- Let op: Supabase geeft anon en authenticated standaard expliciet execute op elke nieuwe functie in public.
-- Een "revoke ... from public" alleen volstaat dus niet; hieronder wordt telkens ook anon/authenticated ingetrokken.
--
-- Test: scripts/test_0004_werfbon_app.sql (schrijft in een transactie met rollback).

-- ─────────────────────────────────────────────
-- 1. Login-koppeling
-- ─────────────────────────────────────────────

alter table medewerkers
  add column auth_user_id uuid unique references auth.users(id) on delete set null;

comment on column medewerkers.auth_user_id is 'Supabase-login van de medewerker. Handmatig gekoppeld.';

-- ─────────────────────────────────────────────
-- 2. Status 'concept' en bron
-- ─────────────────────────────────────────────

alter table werfbonnen drop constraint werfbonnen_status_check;
alter table werfbonnen
  add constraint werfbonnen_status_check check (status in ('concept','op_papier','ingegeven','gefactureerd'));

alter table werfbonnen
  add column bron text not null default 'papier' check (bron in ('papier','spraak','foto'));

comment on column werfbonnen.bron is 'Hoe de bon binnenkwam: papier (overgetikt), spraak of foto (via de app).';

-- Nummer volgens het patroon van de generator: WB-{jaar}-{id, 5 cijfers}. De identity is al toegekend wanneer een
-- before-trigger loopt, en not null wordt pas daarna gecontroleerd.
create or replace function werfbon_nummer_invullen()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.nummer is null then
    new.nummer := 'WB-' || to_char(new.datum, 'YYYY') || '-'
                  || lpad(new.id::text, greatest(5, length(new.id::text)), '0');
  end if;
  return new;
end
$$;

revoke execute on function werfbon_nummer_invullen() from public, anon, authenticated;

create trigger werfbonnen_nummer_invullen
  before insert on werfbonnen
  for each row execute function werfbon_nummer_invullen();

-- Een onbevestigd voorstel ('concept') telt niet mee in de achterstand.
create or replace view v_facturatie_achterstand with (security_invoker = true) as
select
  count(*)                                   as open_werfbonnen,
  min(datum)                                 as oudste_bon,
  round(avg(peildatum() - datum), 1)         as gem_dagen_open,
  sum(uren)                                  as open_uren
from werfbonnen
where status in ('op_papier','ingegeven');

-- ─────────────────────────────────────────────
-- 3. Opnames (audio of foto) achter een bon
-- ─────────────────────────────────────────────

create table werfbon_opnames (
  id              bigint generated always as identity primary key,
  interventie_id  bigint not null references interventies(id),
  technieker_id   bigint not null references medewerkers(id),
  werfbon_id      bigint references werfbonnen(id) on delete set null,  -- de opname bestaat vóór de bon
  type            text not null check (type in ('audio','foto')),
  storage_pad     text not null,
  transcript      text,
  extractie       jsonb,
  model           text,
  input_tokens    integer,
  output_tokens   integer,
  aangemaakt_op   timestamptz not null default now()
);

comment on table werfbon_opnames is
  'Spraakopname of foto in bucket werfbon-opnames, met transcript en extractie. Geschreven door de verwerking.';

create index on werfbon_opnames (werfbon_id);
create index on werfbon_opnames (interventie_id);

alter table werfbon_opnames enable row level security;

-- ─────────────────────────────────────────────
-- 4. Hulpfuncties voor de policies
-- ─────────────────────────────────────────────
-- security definer: ze lezen medewerkers en interventie_techniekers zonder zelf door RLS te gaan, zodat policies
-- elkaar niet recursief aanroepen.

create or replace function mijn_medewerker_id()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select m.id
  from public.medewerkers m
  where m.auth_user_id = auth.uid() and m.actief
$$;

comment on function mijn_medewerker_id() is 'Id van de actieve medewerker achter de huidige login, anders null.';

create or replace function is_administratie()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.medewerkers m
    where m.auth_user_id = auth.uid() and m.actief and m.rol in ('administratie','zaakvoerder')
  )
$$;

comment on function is_administratie() is 'True als de huidige login een actieve administratiemedewerker of zaakvoerder is.';

create or replace function is_mijn_interventie(p_interventie_id bigint)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.interventie_techniekers it
    join public.medewerkers m on m.id = it.medewerker_id
    where it.interventie_id = p_interventie_id
      and m.auth_user_id = auth.uid() and m.actief
  )
$$;

comment on function is_mijn_interventie(bigint) is 'True als de huidige login op deze interventie ingepland staat.';

-- Storagepad {medewerker_id}/{interventie_id}/{bestand}: van mij en voor een interventie van mij.
-- Apart, zodat een pad dat geen getal bevat gewoon false geeft in plaats van een castfout.
create or replace function is_mijn_opnamepad(p_naam text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ik bigint := public.mijn_medewerker_id();
begin
  -- Eerst de vorm, pas daarna de cast: zo kan een vreemd pad geen fout geven.
  if v_ik is null
     or p_naam is null
     or split_part(p_naam, '/', 1) <> v_ik::text
     or split_part(p_naam, '/', 2) !~ '^[0-9]{1,18}$'
     or split_part(p_naam, '/', 3) = ''
     or split_part(p_naam, '/', 4) <> '' then
    return false;
  end if;
  return public.is_mijn_interventie(split_part(p_naam, '/', 2)::bigint);
end
$$;

comment on function is_mijn_opnamepad(text) is
  'True als het pad {medewerker_id}/{interventie_id}/{bestand} bij de huidige login en een eigen interventie hoort.';

revoke execute on function mijn_medewerker_id()          from public, anon;
revoke execute on function is_administratie()            from public, anon;
revoke execute on function is_mijn_interventie(bigint)   from public, anon;
revoke execute on function is_mijn_opnamepad(text)       from public, anon;
grant  execute on function mijn_medewerker_id()          to authenticated, service_role;
grant  execute on function is_administratie()            to authenticated, service_role;
grant  execute on function is_mijn_interventie(bigint)   to authenticated, service_role;
grant  execute on function is_mijn_opnamepad(text)       to authenticated, service_role;

-- ─────────────────────────────────────────────
-- 5. RLS-policies (alles to authenticated; anon heeft geen enkele policy)
-- ─────────────────────────────────────────────
-- De hulpfuncties staan in (select ...), zodat Postgres ze één keer per query uitrekent in plaats van per rij.

-- medewerkers
create policy medewerkers_lezen on medewerkers
  for select to authenticated
  using (id = (select mijn_medewerker_id()) or (select is_administratie()));

-- artikelen: de catalogus, voor elke actieve medewerker
create policy artikelen_lezen on artikelen
  for select to authenticated
  using ((select mijn_medewerker_id()) is not null);

-- interventies en wie erop staat
create policy interventies_lezen on interventies
  for select to authenticated
  using ((select is_administratie()) or is_mijn_interventie(id));

create policy interventie_techniekers_lezen on interventie_techniekers
  for select to authenticated
  using ((select is_administratie()) or is_mijn_interventie(interventie_id));

-- klanten en contracten: alleen als ze bij een eigen interventie horen
create policy klanten_lezen on klanten
  for select to authenticated
  using (
    (select is_administratie())
    or exists (select 1 from interventies i where i.klant_id = klanten.id and is_mijn_interventie(i.id))
  );

create policy onderhoudscontracten_lezen on onderhoudscontracten
  for select to authenticated
  using (
    (select is_administratie())
    or exists (select 1 from interventies i
               where i.contract_id = onderhoudscontracten.id and is_mijn_interventie(i.id))
  );

-- werfbonnen: eigen bonnen lezen, een eigen conceptbon aanpassen
create policy werfbonnen_lezen on werfbonnen
  for select to authenticated
  using (technieker_id = (select mijn_medewerker_id()) or (select is_administratie()));

create policy werfbonnen_concept_aanpassen on werfbonnen
  for update to authenticated
  using (technieker_id = (select mijn_medewerker_id()) and status = 'concept')
  with check (technieker_id = (select mijn_medewerker_id()) and status = 'concept');

-- Op kolomniveau: de technieker past alleen de inhoud van de bon aan, niet status, nummer, interventie, factuur, ...
-- (Supabase geeft authenticated standaard update op de hele tabel.)
revoke update on werfbonnen from anon, authenticated;
grant  update (datum, uren, km, opmerkingen, getekend_door_klant) on werfbonnen to authenticated;

-- werfbon_lijnen: lezen bij een zichtbare bon, schrijven bij een eigen conceptbon
create policy werfbon_lijnen_lezen on werfbon_lijnen
  for select to authenticated
  using (
    (select is_administratie())
    or exists (select 1 from werfbonnen w
               where w.id = werfbon_lijnen.werfbon_id and w.technieker_id = (select mijn_medewerker_id()))
  );

create policy werfbon_lijnen_toevoegen on werfbon_lijnen
  for insert to authenticated
  with check (
    exists (select 1 from werfbonnen w
            where w.id = werfbon_lijnen.werfbon_id and w.status = 'concept'
              and w.technieker_id = (select mijn_medewerker_id()))
  );

create policy werfbon_lijnen_aanpassen on werfbon_lijnen
  for update to authenticated
  using (
    exists (select 1 from werfbonnen w
            where w.id = werfbon_lijnen.werfbon_id and w.status = 'concept'
              and w.technieker_id = (select mijn_medewerker_id()))
  )
  with check (
    exists (select 1 from werfbonnen w
            where w.id = werfbon_lijnen.werfbon_id and w.status = 'concept'
              and w.technieker_id = (select mijn_medewerker_id()))
  );

create policy werfbon_lijnen_verwijderen on werfbon_lijnen
  for delete to authenticated
  using (
    exists (select 1 from werfbonnen w
            where w.id = werfbon_lijnen.werfbon_id and w.status = 'concept'
              and w.technieker_id = (select mijn_medewerker_id()))
  );

-- werfbon_opnames
create policy werfbon_opnames_lezen on werfbon_opnames
  for select to authenticated
  using (technieker_id = (select mijn_medewerker_id()) or (select is_administratie()));

-- facturen: alleen de administratie
create policy facturen_lezen on facturen
  for select to authenticated
  using ((select is_administratie()));

create policy factuur_lijnen_lezen on factuur_lijnen
  for select to authenticated
  using ((select is_administratie()));

-- ─────────────────────────────────────────────
-- 6. Statusovergangen
-- ─────────────────────────────────────────────

create or replace function bevestig_werfbon(p_werfbon_id bigint)
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_ik   bigint := public.mijn_medewerker_id();
  v_bon  record;
begin
  if v_ik is null then
    raise exception 'geen actieve medewerker gekoppeld aan deze login' using errcode = '42501';
  end if;

  select w.id, w.status, w.technieker_id, i.type
    into v_bon
  from public.werfbonnen w
  join public.interventies i on i.id = w.interventie_id
  where w.id = p_werfbon_id
  for update of w;

  if not found or v_bon.technieker_id <> v_ik then
    raise exception 'werfbon % bestaat niet of is niet van jou', p_werfbon_id using errcode = '42501';
  end if;
  if v_bon.status <> 'concept' then
    raise exception 'werfbon % heeft status %: alleen een conceptbon kan bevestigd worden',
      p_werfbon_id, v_bon.status;
  end if;

  update public.werfbonnen
  set status = 'ingegeven', ingegeven_op = public.peildatum()
  where id = p_werfbon_id;

  if v_bon.type in ('herstelling', 'onderhoud') then
    return public.maak_conceptfactuur(p_werfbon_id);
  end if;
  return null;
end
$$;

comment on function bevestig_werfbon(bigint) is
  'De technieker bevestigt zijn conceptbon: status ingegeven en, voor herstelling en onderhoud, een conceptfactuur. '
  'Geeft het factuur-id terug (null bij een ander type).';

create or replace function keur_factuur_goed(p_factuur_id bigint)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  if not public.is_administratie() then
    raise exception 'alleen de administratie keurt facturen goed' using errcode = '42501';
  end if;

  select f.status into v_status
  from public.facturen f
  where f.id = p_factuur_id
  for update;

  if not found then
    raise exception 'factuur % bestaat niet', p_factuur_id;
  end if;
  if v_status <> 'concept' then
    raise exception 'factuur % heeft status %: alleen een conceptfactuur kan goedgekeurd worden',
      p_factuur_id, v_status;
  end if;

  update public.facturen set status = 'verstuurd' where id = p_factuur_id;
  update public.werfbonnen set status = 'gefactureerd' where factuur_id = p_factuur_id;
end
$$;

comment on function keur_factuur_goed(bigint) is
  'De administratie keurt een conceptfactuur goed: factuur verstuurd, gekoppelde bonnen gefactureerd.';

revoke execute on function bevestig_werfbon(bigint)  from public, anon;
revoke execute on function keur_factuur_goed(bigint) from public, anon;
grant  execute on function bevestig_werfbon(bigint)  to authenticated, service_role;
grant  execute on function keur_factuur_goed(bigint) to authenticated, service_role;

-- Een conceptfactuur ontstaat alleen via bevestig_werfbon (of door de service role).
revoke execute on function maak_conceptfactuur(bigint) from public, anon, authenticated;
grant  execute on function maak_conceptfactuur(bigint) to service_role;

-- ─────────────────────────────────────────────
-- 7. Storage: privé bucket voor opnames
-- ─────────────────────────────────────────────
-- Pad: {medewerker_id}/{interventie_id}/{uuid}.{ext}. Geen update of delete, dus uploaden zonder upsert.

insert into storage.buckets (id, name, public)
values ('werfbon-opnames', 'werfbon-opnames', false)
on conflict (id) do nothing;

create policy werfbon_opnames_uploaden on storage.objects
  for insert to authenticated
  with check (bucket_id = 'werfbon-opnames' and public.is_mijn_opnamepad(name));

create policy werfbon_opnames_bekijken on storage.objects
  for select to authenticated
  using (
    bucket_id = 'werfbon-opnames'
    and ((select public.is_administratie()) or public.is_mijn_opnamepad(name))
  );
