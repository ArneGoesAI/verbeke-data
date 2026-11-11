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

## Data-veiligheid

Alles is verzonnen. E-mailadressen gebruiken `example.com`. Telefoonnummers zijn willekeurig en kunnen echt bestaan:
stuur er nooit sms'en of WhatsApp-berichten naar en verbind ze niet met echte verzendflows.
