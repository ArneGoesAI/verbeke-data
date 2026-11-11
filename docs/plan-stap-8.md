# Stap 8: de werfbon-app (laag d)

Status: plan, nog niets gebouwd (2026-11-11). Deel 1 is uitgewerkt, deel 2 en 3 zijn schetsen.

## Context

Laag a, b en c zijn af: de migratiegeschiedenis staat goed, de eval koos Haiku `medium` als kandidaat voor het
spraakpad, en migratie 0003 levert `maak_conceptfactuur`, `factuurwaarschuwingen` en `v_werfbon_te_factureren`.
Laag d maakt er een app van: de technieker spreekt een bon in of fotografeert hem, krijgt een voorstel, bevestigt,
en de administratie keurt de conceptfactuur goed. Volgens §5 van `plan-werfbon-app.md` hoort daar migratie 0004 bij
(punten 1, 2, 3, 5 en 7). Dit plan werkt deel 1 uit; deel 2 en 3 zijn schetsen.

Vastgesteld bij het lezen:
- RLS staat op elke tabel aan zonder policies; alleen de service role kan erbij.
- `werfbonnen.nummer` is `not null unique`, patroon `WB-{jaar}-{id:05d}` (generator r. 600).
- `maak_conceptfactuur` is niet `security definer` en heeft standaard `execute` voor iedereen.
- `v_facturatie_achterstand` telt `status <> 'gefactureerd'`, dus zou conceptbonnen meetellen.
- De live stand (staat 0003 er al? zijn er al policies of buckets?) kon ik niet nakijken: de Supabase-connector in
  deze sessie heeft geen toegang tot het project. Dat is de eerste stap van de uitvoering.

## Deel 1: migratie 0004 (in detail)

**Waar:** `verbeke-data`, branch `migratie/0004-werfbon-app`, bestand
`supabase/migrations/0004_werfbon_app.sql`, plus `scripts/test_0004_werfbon_app.sql`. PR naar `main`. Pas na de
merge `supabase db push`.

### 1.0 Vooraf (read-only op live)
- Staat 0003 in de migratiegeschiedenis en bestaan `maak_conceptfactuur` en `factuur_lijnen.werfbon_id`? Zo niet:
  eerst 0003 pushen.
- Bestaan er al policies in `public`/`storage`, buckets of rijen in `auth.users`? (verwacht: geen)
- `scripts/vingerafdruk.sql` draaien en de uitvoer bewaren als referentie.

### 1.1 Inhoud van de migratie, in deze volgorde

1. **Login-koppeling**
   `medewerkers.auth_user_id uuid unique references auth.users(id) on delete set null`.
2. **Status `concept` en bron**
   - Check-constraint `werfbonnen_status_check` vervangen door
     `('concept','op_papier','ingegeven','gefactureerd')`.
   - `werfbonnen.bron text not null default 'papier' check (bron in ('papier','spraak','foto'))`. Bestaande bonnen
     worden `papier`.
   - Trigger `before insert` op `werfbonnen`: als `nummer` null is, vult hij `'WB-' || jaar(datum) || '-' ||
     lpad(id, 5)`. Zo hoeft de verwerking geen nummer te verzinnen (identity is al toegekend in een before-trigger).
   - `v_facturatie_achterstand` herdefiniëren met `status in ('op_papier','ingegeven')`, zodat een onbevestigd
     voorstel de achterstand niet verandert. Verder ongewijzigd (`security_invoker`, `peildatum()`).
3. **Tabel `werfbon_opnames`** (velden uit §5.3 van het appplan)
   `id` identity, `interventie_id` (not null, fk), `technieker_id` (not null, fk medewerkers), `werfbon_id`
   (nullable fk, `on delete set null`: de opname bestaat vóór de bon), `type check in ('audio','foto')`,
   `storage_pad text not null`, `transcript text`, `extractie jsonb`, `model text`, `input_tokens int`,
   `output_tokens int`, `aangemaakt_op timestamptz default now()`. Index op `werfbon_id` en `interventie_id`. RLS aan.
4. **Hulpfuncties** (`security definer`, `stable`, `set search_path = ''`, execute alleen voor `authenticated`)
   - `mijn_medewerker_id()`: het `medewerkers.id` bij `auth.uid()`, alleen als `actief`.
   - `is_administratie()`: true als die medewerker rol `administratie` (of `zaakvoerder`) heeft.
   - `is_mijn_interventie(p_interventie_id)`: bestaat er een rij in `interventie_techniekers` voor mij.
   Security definer is nodig om recursie tussen policies te vermijden.
5. **RLS-policies**, alles `to authenticated`; `anon` krijgt niets. Schrijven gaat zoveel mogelijk via functies.

   | Tabel | Technieker | Administratie |
   |---|---|---|
   | `medewerkers` | eigen rij lezen | alles lezen |
   | `artikelen` | lezen | lezen |
   | `interventies`, `interventie_techniekers` | eigen interventies lezen | alles lezen |
   | `klanten`, `onderhoudscontracten` | lezen als ze bij een eigen interventie horen | alles lezen |
   | `werfbonnen` | eigen bonnen lezen; `update` alleen als `status = 'concept'`, met check dat status `concept` blijft | alles lezen |
   | `werfbon_lijnen` | lezen bij eigen bon; insert/update/delete alleen bij eigen bon in `concept` | alles lezen |
   | `werfbon_opnames` | eigen opnames lezen | alles lezen |
   | `facturen`, `factuur_lijnen` | niets | alles lezen |

   Insert van een conceptbon en een opname doet de verwerking (deel 2) met de service role; die passeert RLS.
6. **Statusovergangen als functies** (`security definer`, controleren zelf wie belt)
   - `bevestig_werfbon(p_werfbon_id)`: alleen de eigen technieker, alleen vanuit `concept`. Zet `ingegeven`,
     `ingegeven_op = peildatum()`, en roept voor herstelling/onderhoud `maak_conceptfactuur` aan. Geeft het
     factuur-id terug (null bij een ander type).
   - `keur_factuur_goed(p_factuur_id)`: alleen administratie, alleen vanuit `concept`. Zet de factuur op
     `verstuurd` en de gekoppelde bonnen op `gefactureerd`.
   - `revoke execute ... from public` op `maak_conceptfactuur`, zodat een technieker geen factuur buiten
     `bevestig_werfbon` om kan maken.
7. **Storage**: privé bucket `werfbon-opnames`. Pad `{medewerker_id}/{interventie_id}/{uuid}.{ext}`. Policies op
   `storage.objects`: technieker mag `insert` en `select` als het eerste padsegment zijn eigen id is en de
   interventie de zijne is; administratie mag alles in de bucket lezen. Geen update/delete.

Niet in 0004, bewust: correcties door de administratie op een ingegeven bon (afkeuren, herberekenen). Eerst zien of
dat in de praktijk nodig is; zo ja, een kleine 0005.

Geen aanpassing aan de generator nodig: de seed bevat geen conceptbonnen of opnames. De nieuwe kolom `bron` heeft
een default, dus `seed.sql` blijft laadbaar. (Als de seed later opnames vult: tabel in de `setval`-lijst.)

### 1.2 Test op live, in één transactie met rollback

`scripts/test_0004_werfbon_app.sql`, zelfde stijl als `test_maak_conceptfactuur.sql`: elke mislukte controle is een
exception, op het einde `ALLES OK`, dan `rollback`.

```
begin;
\ir ../supabase/migrations/0004_werfbon_app.sql
-- twee testgebruikers in auth.users (uuid's vast in het script) en koppeling aan een bestaande technieker
-- met een herstelling, en aan een bestaande administratiemedewerker
-- rol wisselen met: select set_config('request.jwt.claims', '{"sub":"…","role":"authenticated"}', true);
--                   set local role authenticated;   …   reset role;
... controles ...
select 'ALLES OK';
rollback;
```

Controles:
1. **anon** ziet 0 rijen in `werfbonnen`, `klanten`, `facturen`.
2. **Technieker** ziet precies zijn eigen interventies (aantal = telling via `interventie_techniekers`), geen klant
   van een andere interventie, geen enkele factuur, geen bon van een collega.
3. **Conceptflow:** als service role een conceptbon met lijnen en een opname invoegen → `nummer` is gevuld volgens
   het patroon. Als technieker: uren aanpassen en een lijn toevoegen lukt. `bevestig_werfbon` → status
   `ingegeven`, factuur `concept` bestaat, totaal = `factuurvoorstel`. Daarna wijzigt een update 0 rijen.
4. **Weigeringen:** technieker roept `maak_conceptfactuur` direct aan → permission denied; `bevestig_werfbon` op
   een bon van een collega of een bon die niet `concept` is → fout; `keur_factuur_goed` → fout; insert in
   `facturen` → geweigerd.
5. **Administratie** ziet alle bonnen en de nieuwe conceptfactuur; `keur_factuur_goed` → factuur `verstuurd`,
   bon `gefactureerd`.
6. **Achterstand:** `v_facturatie_achterstand` is gelijk vóór en na het invoegen van de conceptbon.
7. **Storage:** insert in `storage.objects` als technieker onder het eigen id lukt, onder een ander id niet.

Uitvoeren (door jou, in de terminal, met een schrijfbare verbinding naar het project; de read-only verbinding van de
eval-repo weigert het script terecht):

```
psql "<verbinding verbeke-data>" -X -v ON_ERROR_STOP=1 -f scripts/test_0004_werfbon_app.sql
```

Een fout stopt psql en verbreekt de verbinding: de open transactie wordt dan ook teruggerold.

**Daarna aantonen dat live onveranderd is:** `vingerafdruk.sql` opnieuw en vergelijken met 1.0; `auth.users` nog
leeg; 0004 niet in de migratiegeschiedenis.

**Bekende neveneffecten van de test:**
- Sequences (`werfbonnen`, `facturen`, `werfbon_opnames`, `werfbon_lijnen`) schuiven op; `nextval` rolt niet terug.
  Gevolg: een gat in de nummering (bv. FA-2026-… springt een paar nummers). Aanvaardbaar bij fictieve data.
- De DDL neemt korte exclusieve locks op `werfbonnen`, `medewerkers` en enkele andere tabellen. Andere projecten op
  dezelfde database wachten even. Draai het niet tijdens een eval-run van een ander project.

### 1.3 Echt toepassen
Na groene test en merge van de PR: `supabase db push` vanuit `verbeke-data`, controle via de migratiegeschiedenis,
dan de test nogmaals draaien zonder de `\ir` (de migratie staat er dan al) — of de test zo schrijven dat hij de
migratie overslaat als `werfbon_opnames` al bestaat. `CLAUDE.md` en §5 van het appplan bijwerken.

## Deel 2: van opname of foto naar voorstel (schets)

- **Waar:** in deze repo (`verbeke-werfbon`), als server-route van de Next.js-app op Vercel (regio `fra1`), niet als
  aparte Supabase Edge Function. Eén codebase en één plek voor de geheimen. Dit wijkt af van §3 van het appplan;
  dat plan bijwerken als je akkoord gaat.
- **Flow:** de app uploadt naar de bucket → route `POST /api/verwerk` met het storage-pad en de interventie →
  controleert met de sessie van de technieker dat de interventie de zijne is → audio: Voxtral-transcriptie →
  Claude met structured output (schema en prompt overgezet uit `eval/schema.py` en `eval/prompts/`) → afgeleide
  lijnen zoals `eval/afgeleide_lijnen.py` → validatie (code bestaat, uren 0–12) → met de service role een bon in
  `concept`, de lijnen en de opname wegschrijven → bon-id terug.
- **Model:** per invoerweg de winnaar uit de eval (spraak: Haiku `medium`, nog te bevestigen met de echte bonnen).
  Zelfde instellingen als de eval, ook `max_tokens` 2000 en geen refusal-fallback.
- **Test:** de route draaien op een paar gevallen uit `eval/data/cases.jsonl` en vergelijken met de eval-uitvoer.

## Deel 3: schermen (schets)

**Eerst mockups, pas daarna code.** Statische mockups (HTML, met fictieve voorbeelddata uit de seed, zonder namen
of telefoonnummers) van elk scherm hieronder, één voor gsm-breedte en één voor de administratie op desktop. Pas als
de mockups nagekeken en goedgekeurd zijn, begint de code.

Schermen:
- **Technieker** (mobiel): interventies van vandaag → interventie openen → opnemen of foto nemen → voorstel met
  per lijn de bronzin → aanpassen → bevestigen (`bevestig_werfbon`).
- **Administratie:** lijst uit `v_werfbon_te_factureren` en conceptfacturen, met bon, opname, bronzinnen en
  `factuurwaarschuwingen` → goedkeuren (`keur_factuur_goed`).

Daarna de code: Next.js (App Router) met Supabase Auth (e-mail + wachtwoord, accounts handmatig aangemaakt en via
`auth_user_id` gekoppeld), online op Vercel. Alles leest met de sessie van de gebruiker, dus RLS uit deel 1 bepaalt
wat iemand ziet.

## Verificatie (deel 1)
1. Read-only checks uit 1.0 en referentie-vingerafdruk.
2. `test_0004_werfbon_app.sql` op live eindigt op `ALLES OK` en `ROLLBACK`.
3. Vingerafdruk identiek, `auth.users` leeg, geen 0004 in de geschiedenis.
4. Na `db push`: test opnieuw groen; Supabase-advisors (security) tonen geen nieuwe meldingen voor de
   0004-objecten.
