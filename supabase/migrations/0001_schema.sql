-- Verbeke Installatietechniek BV — datamodel
-- Fictief bedrijf (case AI-adviseur). Alle data is verzonnen.
-- Doel: één gedeelde database voor alle portfolioprojecten.

create extension if not exists vector;

-- ─────────────────────────────────────────────
-- Mensen
-- ─────────────────────────────────────────────

create table medewerkers (
  id              bigint generated always as identity primary key,
  voornaam        text not null,
  achternaam      text not null,
  rol             text not null check (rol in (
                    'zaakvoerder','commercieel','planner','administratie',
                    'klantendienst','werfleider','calculator','technieker','magazijnier')),
  email           text unique,
  telefoon        text,
  thuis_gemeente  text,
  in_dienst_sinds date not null,
  actief          boolean not null default true
);

create table vaardigheden (
  id    bigint generated always as identity primary key,
  code  text unique not null,
  naam  text not null
);

create table medewerker_vaardigheden (
  medewerker_id  bigint references medewerkers(id) on delete cascade,
  vaardigheid_id bigint references vaardigheden(id) on delete cascade,
  niveau         smallint not null check (niveau between 1 and 3), -- 1 basis, 2 zelfstandig, 3 expert
  primary key (medewerker_id, vaardigheid_id)
);

create table klanten (
  id             bigint generated always as identity primary key,
  type           text not null check (type in ('particulier','bedrijf')),
  voornaam       text,
  achternaam     text,
  bedrijfsnaam   text,
  btw_nummer     text,
  email          text,
  telefoon       text,
  straat         text not null,
  huisnummer     text not null,
  postcode       text not null,
  gemeente       text not null,
  aangemaakt_op  timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- Catalogus
-- ─────────────────────────────────────────────

create table artikelen (
  id            bigint generated always as identity primary key,
  code          text unique not null,
  omschrijving  text not null,
  categorie     text not null check (categorie in (
                  'warmtepomp','ventilatie','sanitair','onderdeel','arbeid','verplaatsing')),
  eenheid       text not null check (eenheid in ('stuk','uur','m','km','forfait')),
  verkoopprijs  numeric(10,2) not null,
  aankoopprijs  numeric(10,2)
);

-- ─────────────────────────────────────────────
-- Sales: aanvraag → offerte → werf
-- ─────────────────────────────────────────────

create table aanvragen (
  id             bigint generated always as identity primary key,
  klant_id       bigint references klanten(id),
  kanaal         text not null check (kanaal in ('telefoon','mail','webformulier')),
  onderwerp      text not null check (onderwerp in ('warmtepomp','ventilatie','sanitair','renovatie','herstelling')),
  omschrijving   text not null,
  ontvangen_op   timestamptz not null,
  status         text not null check (status in (
                   'nieuw','plaatsbezoek_gepland','offerte_in_opmaak','offerte_verstuurd',
                   'gewonnen','verloren','geen_opvolging')),
  werfleider_id  bigint references medewerkers(id)
);

create table offertes (
  id                    bigint generated always as identity primary key,
  nummer                text unique not null,
  aanvraag_id           bigint references aanvragen(id),
  klant_id              bigint not null references klanten(id),
  werfleider_id         bigint references medewerkers(id),
  status                text not null check (status in ('concept','verstuurd','aanvaard','geweigerd','verlopen')),
  plaatsbezoek_op       date,
  opgemaakt_op          date not null,
  verstuurd_op          date,
  laatste_opvolging_op  date,          -- null = nooit opgevolgd (het 40%-probleem)
  beslist_op            date,
  btw_tarief            numeric(4,2) not null check (btw_tarief in (6, 21)),
  totaal_excl_btw       numeric(12,2) not null default 0
);

create table offerte_lijnen (
  id          bigint generated always as identity primary key,
  offerte_id  bigint not null references offertes(id) on delete cascade,
  artikel_id  bigint not null references artikelen(id),
  aantal      numeric(10,2) not null,
  eenheidsprijs numeric(10,2) not null
);

create table werven (
  id             bigint generated always as identity primary key,
  offerte_id     bigint references offertes(id),
  klant_id       bigint not null references klanten(id),
  werfleider_id  bigint references medewerkers(id),
  omschrijving   text not null,
  straat         text not null,
  huisnummer     text not null,
  postcode       text not null,
  gemeente       text not null,
  status         text not null check (status in ('gepland','lopend','afgewerkt','opgeleverd')),
  startdatum     date,
  einddatum      date,
  whatsapp_groep text            -- zo werkt het vandaag
);

-- ─────────────────────────────────────────────
-- Onderhoud
-- ─────────────────────────────────────────────

create table onderhoudscontracten (
  id                 bigint generated always as identity primary key,
  klant_id           bigint not null references klanten(id),
  toesteltype        text not null check (toesteltype in ('warmtepomp','ventilatie','zonneboiler')),
  merk               text not null,
  model              text not null,
  installatiedatum   date not null,
  frequentie_maanden smallint not null default 12,
  laatste_onderhoud  date,
  volgend_onderhoud  date not null,
  jaarprijs          numeric(8,2) not null,
  status             text not null check (status in ('actief','opgezegd'))
);

-- ─────────────────────────────────────────────
-- Planning & uitvoering
-- ─────────────────────────────────────────────

create table interventies (
  id              bigint generated always as identity primary key,
  type            text not null check (type in ('installatie','onderhoud','herstelling','plaatsbezoek')),
  klant_id        bigint not null references klanten(id),
  werf_id         bigint references werven(id),
  contract_id     bigint references onderhoudscontracten(id),
  gepland_start   timestamptz,
  gepland_eind    timestamptz,
  status          text not null check (status in ('te_plannen','gepland','uitgevoerd','geannuleerd')),
  omschrijving    text,
  check (werf_id is not null or contract_id is not null or type in ('herstelling','plaatsbezoek'))
);

create table interventie_techniekers (
  interventie_id bigint references interventies(id) on delete cascade,
  medewerker_id  bigint references medewerkers(id),
  primary key (interventie_id, medewerker_id)
);

-- Werfbon: vandaag op papier, overgetikt door de administratie.
create table werfbonnen (
  id               bigint generated always as identity primary key,
  nummer           text unique not null,
  interventie_id   bigint not null references interventies(id),
  technieker_id    bigint not null references medewerkers(id),
  datum            date not null,
  uren             numeric(5,2) not null,
  km               integer not null default 0,
  opmerkingen      text,
  getekend_door_klant boolean not null default true,
  status           text not null check (status in ('op_papier','ingegeven','gefactureerd')),
  ingegeven_op     date,
  factuur_id       bigint
);

create table werfbon_lijnen (
  id           bigint generated always as identity primary key,
  werfbon_id   bigint not null references werfbonnen(id) on delete cascade,
  artikel_id   bigint not null references artikelen(id),
  aantal       numeric(10,2) not null
);

-- ─────────────────────────────────────────────
-- Facturatie
-- ─────────────────────────────────────────────

create table facturen (
  id               bigint generated always as identity primary key,
  nummer           text unique not null,
  klant_id         bigint not null references klanten(id),
  factuurdatum     date not null,
  vervaldatum      date not null,
  btw_tarief       numeric(4,2) not null check (btw_tarief in (6, 21)),
  totaal_excl_btw  numeric(12,2) not null,
  status           text not null check (status in ('concept','verstuurd','betaald','vervallen')),
  betaald_op       date
);

alter table werfbonnen
  add constraint werfbonnen_factuur_fk foreign key (factuur_id) references facturen(id);

create table factuur_lijnen (
  id             bigint generated always as identity primary key,
  factuur_id     bigint not null references facturen(id) on delete cascade,
  omschrijving   text not null,
  aantal         numeric(10,2) not null,
  eenheidsprijs  numeric(10,2) not null
);

-- ─────────────────────────────────────────────
-- Kennis (voor RAG: klantenbot en kennisagent)
-- ─────────────────────────────────────────────

create table documenten (
  id          bigint generated always as identity primary key,
  titel       text not null,
  type        text not null check (type in (
                'werkinstructie','technische_fiche','veiligheidsfiche','premieregel','faq','lastenboek')),
  inhoud      text not null,
  bijgewerkt_op date not null default current_date
);

create table document_chunks (
  id           bigint generated always as identity primary key,
  document_id  bigint not null references documenten(id) on delete cascade,
  volgorde     integer not null,
  inhoud       text not null,
  embedding    vector(1024)   -- mistral-embed geeft 1024 dimensies
);

-- ─────────────────────────────────────────────
-- Indexen
-- ─────────────────────────────────────────────

create index on aanvragen (status);
create index on offertes (status, verstuurd_op);
create index on interventies (gepland_start);
create index on interventies (status);
create index on werfbonnen (status, datum);
create index on onderhoudscontracten (volgend_onderhoud) where status = 'actief';
create index on klanten (postcode);

-- ─────────────────────────────────────────────
-- Rapportering: de pijnpunten uit de case, meetbaar
-- ─────────────────────────────────────────────

create view v_facturatie_achterstand as
select
  count(*)                                   as open_werfbonnen,
  min(datum)                                 as oudste_bon,
  round(avg(current_date - datum), 1)        as gem_dagen_open,
  sum(uren)                                  as open_uren
from werfbonnen
where status <> 'gefactureerd';

create view v_offerte_opvolging as
select
  count(*)                                                        as verstuurde_offertes,
  count(*) filter (where o.status = 'verstuurd')                  as nog_openstaand,
  count(*) filter (where o.laatste_opvolging_op is null)          as nooit_opgevolgd,
  round(100.0 * count(*) filter (where o.laatste_opvolging_op is null) / nullif(count(*), 0), 1)
                                                                  as pct_nooit_opgevolgd,
  round(avg(o.verstuurd_op - a.ontvangen_op::date), 1)            as gem_dagen_aanvraag_tot_offerte
from offertes o
join aanvragen a on a.id = o.aanvraag_id
where o.verstuurd_op is not null;

-- ─────────────────────────────────────────────
-- Beveiliging: RLS aan; toegang voorlopig enkel via service role.
-- Policies volgen per project (bv. technieker ziet enkel eigen werfbonnen).
-- ─────────────────────────────────────────────

alter table medewerkers              enable row level security;
alter table vaardigheden             enable row level security;
alter table medewerker_vaardigheden  enable row level security;
alter table klanten                  enable row level security;
alter table artikelen                enable row level security;
alter table aanvragen                enable row level security;
alter table offertes                 enable row level security;
alter table offerte_lijnen           enable row level security;
alter table werven                   enable row level security;
alter table onderhoudscontracten     enable row level security;
alter table interventies             enable row level security;
alter table interventie_techniekers  enable row level security;
alter table werfbonnen               enable row level security;
alter table werfbon_lijnen           enable row level security;
alter table facturen                 enable row level security;
alter table factuur_lijnen           enable row level security;
alter table documenten               enable row level security;
alter table document_chunks          enable row level security;
