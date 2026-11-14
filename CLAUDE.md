# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Wat dit is

Gedeelde Supabase/Postgres-database met **fictieve** data van "Verbeke Installatietechniek" (installatiebedrijf in Lede:
warmtepompen, ventilatie, sanitair). Ze is het fundament voor zeven aparte AI-/automatisatieprojecten (zie README).
Er is geen applicatiecode, build of testsuite: de repo bestaat uit een schema, een seed-generator en de gegenereerde seed.
Code, commentaar, tabel- en kolomnamen zijn in het Nederlands; houd dat zo.

- **Live database:** Supabase-project `verbeke`, regio Frankfurt. Een nieuwe migratie in deze repo staat daar pas na
  `supabase db push` (of `apply_migration`); wijzig dus nooit een bestaande migratie, maar voeg een nieuwe toe.
- **GitHub:** `ArneGoesAI/verbeke-data`.

## Commando's

```bash
python3 scripts/generate_seed.py > supabase/seed.sql   # seed opnieuw genereren (enkel stdlib, Python 3.9+)

supabase link --project-ref <ref>
supabase db push                                       # migraties toepassen
psql "$DATABASE_URL" -f supabase/seed.sql              # data laden (in één transactie)
```

Controle na laden: `select * from v_facturatie_achterstand;` en `select * from v_offerte_opvolging;`.

### Een nieuwe migratie testen zonder de live database te wijzigen

Op een lokale Postgres 17 met pgvector (zelfde major versie als live), in een wegwerpcluster:

```bash
export LC_ALL=C                                   # anders weigert de server te starten ("became multithreaded")
PG=/opt/homebrew/Cellar/postgresql@17/17.11_1/bin; D=$(mktemp -d)
$PG/initdb -D "$D/data" -U postgres --no-locale -E UTF8 >/dev/null
$PG/pg_ctl -D "$D/data" -o "-p 54329 -k '' -c listen_addresses=localhost" -l "$D/log" -w start
$PG/createdb -h localhost -p 54329 -U postgres verbeke
L="$PG/psql -X -q -v ON_ERROR_STOP=1 -h localhost -p 54329 -U postgres -d verbeke"
for f in scripts/supabase_stubs_lokaal.sql supabase/migrations/000[123]_*.sql supabase/seed.sql; do
  $L -f "$f"; done                                # de stand van live (stubs: rollen, auth, storage)
$L -A -t -F ' | ' -f scripts/vingerafdruk.sql     # vergelijk met live (read-only)
$L -f scripts/test_0004_werfbon_app.sql           # laadt 0004 zelf in een transactie met rollback
```

In zsh wordt `$L` niet gesplitst: gebruik daar een functie (`L() { $PG/psql ... "$@"; }`) of bash.
`scripts/supabase_stubs_lokaal.sql` bootst de Supabase-rollen (`anon`, `authenticated`, `service_role`), hun
standaardrechten, `auth.uid()` en `storage` minimaal na. Laad het vóór 0001, anders krijgen de tabellen niet dezelfde
rechten als live.

**Installatie op macOS 14:** Homebrew bouwt hier alles uit broncode (`brew install postgresql@17` duurt ±20 min).
`brew install pgvector` mislukt, omdat het de pgxs-map van postgresql@17 niet vindt zolang die keg niet gelinkt is.
Volledig linken botst met `libpq`. Wat werkt:
- **Symlinks:** alleen de twee versiegebonden mappen linken, `/opt/homebrew/share/postgresql@17` en
  `/opt/homebrew/lib/postgresql@17`, naar `share/postgresql` en `lib/postgresql` in de keg.
- **pgvector:** de bron uit de Homebrew-cache zelf bouwen met
  `make PG_CONFIG=<keg>/bin/pg_config PGXS=<keg>/lib/postgresql/pgxs/src/makefiles/pgxs.mk PG_CPPFLAGS="-I<keg>/include/postgresql/server -I<keg>/include/postgresql/internal"`,
  en daarna `vector.dylib` en `vector.control` plus `sql/vector--*.sql` naar die mappen kopiëren.
- **Verbinding:** de server luistert alleen op localhost, want een Unix-socket in een lang tijdelijk pad is te lang.

- **Zelfde data als live?** Draai `scripts/vingerafdruk.sql` lokaal en read-only op live. Alle rijen moeten gelijk
  zijn.
- **Testen:**
  - `scripts/test_conceptfactuur.sql` (read-only, mag ook live na `db push`) moet eindigen op `ALLES GELIJK`.
  - `scripts/test_maak_conceptfactuur.sql` schrijft in een transactie met rollback. Draai het alleen lokaal; het
    moet eindigen op `ALLES OK`.
  - `scripts/test_0004_werfbon_app.sql` (RLS, conceptflow, storage) schrijft in een transactie met rollback en mag
    ook op live. Het laadt 0004 zelf als die er nog niet staat. Moet eindigen op `ALLES OK`.
  - `scripts/test_0005_intake.sql` (rol `n8n_intake`, `intake_aanvraag`) schrijft in een transactie met rollback
    en mag ook op live. Het laadt 0005 zelf als die er nog niet staat. Moet eindigen op `ALLES OK`.
- **Laag c, 2026-11-11:** lokaal identiek aan live. 92 herstellingen en 261 onderhouden, allemaal gelijk.
  123 onderhoudsbonnen met een onderdeel.
- **Opruimen:** `$PG/pg_ctl -D "$D/data" stop && rm -rf "$D"`.

## Architectuur

- `supabase/migrations/0001_schema.sql`: het volledige datamodel. Flow: aanvraag → offerte → werf → interventies →
  werfbonnen → factuur; onderhoud loopt apart: onderhoudscontract → interventie → werfbon → factuur.
  Statussen en types zijn `text` met `check (... in (...))`-constraints, geen Postgres-enums. Een nieuwe status vraagt
  dus een nieuwe migratie én een aanpassing in de generator.
- `scripts/generate_seed.py` schrijft SQL naar stdout. **`supabase/seed.sql` is gegenereerde output: pas de generator
  aan, niet de seed rechtstreeks.**
  - Reproduceerbaar via `random.seed(42)`. Elke extra `random`-aanroep vroeg in het script verschuift alle data erna.
  - `VANDAAG = date(2026, 11, 5)` is de peildatum. Historiek en planning worden relatief daaraan opgebouwd
    (`GESCHIEDENIS` = 16 weken terug, `HORIZON` = 6 weken vooruit). De generator zet dezelfde datum in de SQL-functie
    `peildatum()` (bovenaan `seed.sql`).
  - Rijen krijgen expliciete id's (`overriding system value`). Op het einde worden de identity-sequences met `setval`
    rechtgezet. Een nieuwe tabel moet dus ook in die `setval`-lijst.
  - De data bevat bewust de pijnpunten van de case: ±33 dagen van werfbon tot factuur, ±26 dagen tot offerte, ±40% van
    de offertes nooit opgevolgd, ±275 interventies `te_plannen`. Wijzigingen aan de generator mogen die cijfers niet
    ongemerkt verschuiven: de README en de projecten steunen erop.
- `peildatum()` (migratie `0002_peildatum.sql`) geeft de "vandaag" van de fictieve data terug. Gebruik die in views en
  queries in plaats van `current_date`, anders loopt de achterstand op met de echte kalender terwijl de data stilstaat.
  `v_facturatie_achterstand` gebruikt ze al.
- `document_chunks.embedding` is `vector(1024)` (mistral-embed). De seed vult enkel `documenten`. Chunks en embeddings
  maakt elk project zelf aan.
- RLS staat op elke tabel aan **zonder policies**: enkel de service role heeft toegang. Policies horen bij de
  afzonderlijke projecten, niet in deze basismigratie.
- Intake (migratie `0005_intake_webformulier.sql`): de login-rol `n8n_intake` mag enkel
  `intake_aanvraag(...)` uitvoeren (security definer) en heeft geen tabelrechten. Het wachtwoord staat niet in de
  repo. Sinds 0005 kunnen `klanten.straat`, `huisnummer` en `postcode` null zijn (webformulier zonder adres), en
  heeft `aanvragen` de kolommen `dringend` en `samenvatting`.

## Data-veiligheid

Alles is verzonnen. E-mailadressen gebruiken `example.com`. Telefoonnummers zijn willekeurig en kunnen echt bestaan:
stuur er nooit sms'en of WhatsApp-berichten naar en verbind ze niet met echte verzendflows.
