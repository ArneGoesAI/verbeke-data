# Plan: werfbon-app

Een technieker spreekt een werfbon in of fotografeert hem, AI haalt er uren en materiaal uit, en de administratie
krijgt een conceptfactuur om na te kijken.

Status: voorstel met genomen beslissingen, nog geen code. Cijfers komen uit de live database (peildatum 2026-11-05),
opgevraagd op 2026-11-11.

## Beslissingen

1. **Bouwvolgorde in vier lagen** (zie §2): a) migratiegeschiedenis rechtzetten (afgerond op 2026-11-11),
   b) extractie plus eval zonder app, c) SQL-functie voor de conceptfactuur, d) de app.
2. **Testset:** de bestaande bonnen worden aangevuld met een tiental bonnen die zelf ingesproken worden in het
   Vlaams, en met de hand ingevuld en gefotografeerd.
3. **Embeddings:** Mistral wordt nog niet gebruikt voor embeddings. Het schema is er enkel op voorbereid
   (`document_chunks.embedding vector(1024)`).
4. **Dataverwerking in de EU:** in productie wordt klantdata in de EU verwerkt, met Claude via een EU-regio bij een
   cloudprovider of met Mistral.
5. **Repo's:** migratie 0003 komt in `verbeke-data`, de app in een eigen repo.
6. **Transcriptieprijs nagekeken:** Voxtral kost ongeveer $0,003 à $0,004 per minuut.

## 1. Hoe werfbonnen, interventies en facturen samenhangen

```
interventie (type, klant, werf_id óf contract_id)
  └─ werfbonnen (1–2 per interventie: uren, km, opmerkingen, status, factuur_id)
       └─ werfbon_lijnen (artikel_id, aantal)
factuur ← werfbonnen.factuur_id      factuur_lijnen = vrije tekst, zonder artikel_id of werfbon_id
```

Er zijn drie factuurpatronen, en de regels liggen vast:

| Type | Bonnen | Hoe de factuur ontstaat |
|---|---|---|
| Onderhoud | 404 | Eén lijn tegen de `jaarprijs` van het contract (261 van de 261 kloppen) |
| Herstelling | 144 | Bonlijnen × `verkoopprijs` (arbeid + `VERPL`-forfait + onderdelen) |
| Installatie | 300 | Eén lijn "volgens offerte" voor het offertetotaal, één factuur per werf voor 4 tot 14 bonnen |

### Cijfers die het plan sturen

- **Doorlooptijd:** van bon tot `ingegeven` duurt gemiddeld 19,4 dagen, van `ingegeven` tot factuur nog eens
  13,7 dagen (33,6 in totaal). Het grootste deel van de vertraging zit in het overtypen van het papier.
- **Achterstand:** 172 bonnen staan nog `op_papier`, gemiddeld 20 dagen oud. Er komen ongeveer 53 bonnen per week bij.
- **btw:** 6% bij particulieren, 21% bij bedrijven, met 5 uitzonderingen (particulier aan 21%). De regel kan
  automatisch, maar de administratie moet ze nog bevestigen.
- **Lek:** 123 onderhoudsbonnen hebben een extra onderdeel. 76 daarvan zijn gefactureerd, telkens met alleen het
  forfait, dus zo'n **€ 4.664 aan onderdelen is niet aangerekend**. Dat kan een eigenaardigheid van de generator zijn
  of een bewuste afspraak in het contract. Vraag het na voor je er een functie van maakt.
- **Kleinere vaststellingen:**
  - De kolom `km` wordt nooit gefactureerd: `VERPL` is een forfait en het artikel `KM` wordt niet gebruikt.
  - Bij installaties wijkt de lijn `ARB-TECH` op 173 van de 300 bonnen af van `werfbonnen.uren`. Voor de factuur
    maakt dat niet uit.

## 2. De kleinste versie die werkt

**Scope:** alleen **herstelling en onderhoud**. Dat zijn bonnen die elk één eigen factuur krijgen en waar de AI echt
werk uitspaart. Bij installaties is de factuur gewoon het offertetotaal, daar valt niets uit te halen.

**Flow**

1. De technieker opent in de app zijn interventie van vandaag. Klant, toestel en omschrijving staan al ingevuld
   vanuit de database.
2. Hij **spreekt de bon in** ("anderhalf uur, circulatiepomp vervangen, 16 kilometer") of **fotografeert de papieren
   bon**.
3. Binnen een paar seconden toont de app een voorstel: uren, km, artikellijnen met aantallen, opmerking. Elke lijn
   staat naast het zinnetje waar ze uit komt. De technieker past aan en bevestigt.
4. Bij bevestiging gaat de bon naar `ingegeven` en maakt een **SQL-functie** (dus niet de AI) een conceptfactuur
   volgens de regels uit de tabel hierboven.
5. De administratie krijgt een lijst conceptfacturen met de bon, de foto of audio, de bronzinnen en waarschuwingen
   (onbekend artikel, ongewoon veel uren, btw-uitzondering, onderdeel op een onderhoudsbon). Ze keurt goed en de
   factuur gaat naar `verstuurd`.

**Bewust weggelaten in deze versie:** offline werken, digitale handtekening (alleen het vinkje
`getekend_door_klant`), installaties en koppeling met de boekhouding.

### Bouwvolgorde

Elke laag levert iets op dat zonder de volgende laag te controleren is.

| Laag | Wat | Waar | Klaar als |
|---|---|---|---|
| a | **Afgerond (2026-11-11).** Migratiegeschiedenis van het live project rechtzetten (`supabase migration repair`), zodat `db push` 0001 en 0002 niet opnieuw probeert | `verbeke-data` | 0001 en 0002 zijn eerst nagekeken in de live database en daarna met `migration repair` als toegepast gemarkeerd. De migratiegeschiedenis toont nu `0001 schema` en `0002 peildatum` |
| b | Extractie plus eval, zonder app: een script dat een transcript of foto plus de interventie inleest en de gestructureerde bon teruggeeft, en dat scoort tegen de testset | eigen repo van de app | De score op artikelen, aantallen en uren is gemeten per model en per invoerweg (spraak, foto) |
| c | SQL-functie `maak_conceptfactuur(werfbon_id)`, de view `v_werfbon_te_factureren` en de rest van migratie 0003 | `verbeke-data` | Voor bestaande bonnen geeft de functie dezelfde factuur als in de seed (onderhoud: jaarprijs, herstelling: lijnen × verkoopprijs) |
| d | De app: opname, voorstel, bevestiging, admin-scherm | eigen repo van de app | Een technieker kan een bon inspreken of fotograferen en de administratie ziet de conceptfactuur |

Laag b komt vóór c en d omdat de modelkeuze en de kwaliteit van de extractie bepalen of de rest de moeite waard is.

## 3. Architectuur

```
PWA (Next.js)  ──auth──▶ Supabase Auth (technieker ↔ medewerkers)
     │ upload audio/foto
     ▼
Supabase Storage (privé bucket)  ──▶  Edge Function "verwerk-opname"
                                        1. audio → transcriptie
                                        2. LLM-extractie met structured output
                                        3. validatie in code (artikelcode bestaat? uren 0–12?)
                                        4. werfbon + lijnen als 'concept'
     ◀── voorstel ───────────────────────┘
bevestigen ─▶ rpc maak_conceptfactuur(werfbon_id)  (deterministisch, per type)
Admin-scherm ─▶ facturen.status = 'concept' → nakijken → 'verstuurd'
```

Het belangrijkste ontwerpprincipe: **de AI haalt alleen gegevens uit de bon, ze rekent geen prijzen.** Prijzen, btw
en factuurlijnen komen uit SQL-regels. Zo is elke factuur te verklaren, en een fout van het model levert in het
slechtste geval een verkeerde lijn op, nooit een verzonnen prijs.

**Repo's:** het datamodel (migratie 0003, de SQL-functie en de view) hoort in `verbeke-data`, net als de andere
schemawijzigingen. De Edge Function, de PWA en het eval-script komen in een eigen repo voor de app.

**EU-verwerking:** in productie gaat klantdata (audio, foto's, transcripten) alleen naar verwerking in de EU. De
database staat al in Frankfurt. Voor het model zijn er twee wegen: Claude via een EU-regio bij een cloudprovider
(Amazon Bedrock, Google Vertex AI of Microsoft Foundry), of Mistral. Tijdens laag b op fictieve data maakt dat nog
niet uit, maar de eval moet wel draaien op de provider en regio die in productie gebruikt worden.

## 4. Welk model voor welke stap

| Stap | Model | Waarom |
|---|---|---|
| Spraak naar tekst | Mistral Voxtral (transcriptie) | Claude neemt geen audio aan. Mistral verwerkt in de EU, wat bij beslissing 4 past. Het schema is al voorbereid op Mistral-embeddings, al worden die nog niet gebruikt. Hoe goed Voxtral Vlaams verstaat, meet laag b met de zelf ingesproken bonnen. |
| Gegevens uit transcript of foto halen | **Claude Sonnet 5.5** via een EU-regio bij een cloudprovider, effort `low`, structured output (`output_config.format`) | Eén model voor beide invoerwegen. Het leest handschrift op foto's goed, is snel genoeg om de technieker niet te laten wachten, en structured output dwingt een geldig JSON-schema af met artikelcodes uit een lijst. Nog na te gaan: of Sonnet 5.5 en structured output beschikbaar zijn in de gekozen EU-regio. Een Mistral-model is het alternatief als dat niet zo is of als het in de eval even goed scoort. |
| Conceptfactuur | Geen model, SQL | Er zijn vaste regels (jaarprijs, catalogusprijs, offertetotaal). |

- **Claude Haiku 5.5** is ongeveer 20 keer goedkoper. Probeer het voor het spraakpad, maar pas als een test aantoont
  dat het de juiste artikelen kiest.
- **Claude Opus 5.5** komt pas in beeld als slecht leesbaar handschrift in de test misloopt.
- **Testset** (laag b), in twee delen:
  - **Synthetisch:** de 848 bestaande bonnen met hun lijnen en opmerkingen. Daar worden inspreekteksten en ingevulde
    bonformulieren van gemaakt.
  - **Echt:** een tiental bonnen, zelf ingesproken in het Vlaams en met de hand ingevuld en gefotografeerd. Die
    testen wat synthetische data niet kan: dialect, achtergrondlawaai, echt handschrift en slechte foto's.

  Meet hoe vaak de juiste artikelen, aantallen en uren terugkomen, apart per deel en per invoerweg, vóór je een model
  vastlegt. Op de echte set zijn tien bonnen te weinig voor een percentage. Bekijk ze daarom één voor één.

## 5. Wat er in de database moet veranderen

**Laag a, afgerond op 2026-11-11:** de migratiegeschiedenis van het live project was leeg, terwijl het schema wel
stond, zodat `supabase db push` 0001 en 0002 opnieuw zou proberen. 0001 en 0002 zijn eerst nagekeken in de live
database (18 tabellen, 2 views, `peildatum()` geeft 2026-11-05) en daarna met `supabase migration repair` als
toegepast gemarkeerd. Een nieuwe migratie kan nu gewoon met `db push`.

Daarna één nieuwe migratie (`0003_werfbon_app.sql`) in `verbeke-data` (laag c); 0001 blijft ongewijzigd. De app-repo
bevat geen migraties op deze tabellen.

1. **`werfbonnen.status`:** voeg `'concept'` toe aan de check-constraint, voor een AI-voorstel dat de technieker nog
   niet bevestigd heeft. Volgens CLAUDE.md hoort bij een nieuwe status ook een aanpassing in de generator. Die is
   alleen nodig als de seed conceptbonnen moet bevatten.
2. **`werfbonnen.bron`:** `'papier' | 'spraak' | 'foto'`, zodat je kunt meten wat de app oplevert.
3. **Nieuwe tabel `werfbon_opnames`:** `interventie_id`, `technieker_id`, `werfbon_id`, `type` (audio/foto),
   `storage_pad`, `transcript`, `extractie jsonb` (ruwe output met de bronzinnen), `model`, `input_tokens`,
   `output_tokens`, `aangemaakt_op`. Dit is de audit trail en tegelijk testdata. Als de seed deze tabel ooit vult,
   moet ze ook in de `setval`-lijst van de generator.
4. **`factuur_lijnen`:** `artikel_id` en `werfbon_id` toevoegen, allebei nullable. Dan ziet de administratie waar elke
   lijn vandaan komt, en dat ontbreekt nu.
5. **`medewerkers.auth_user_id uuid`:** de koppeling met Supabase Auth, nodig om in te loggen.
6. **Functie `maak_conceptfactuur(werfbon_id)`** en een view **`v_werfbon_te_factureren`**, die `peildatum()`
   gebruiken en niet `current_date`.
7. **RLS-policies** voor de rollen technieker (alleen eigen interventies) en administratie. Die horen in dit project,
   niet in de basismigratie.

## 6. Kosten per werfbon

Ruwe schatting voor één bon:

- **Invoer:** ongeveer 3.000 tokens (prompt, artikelcatalogus van 32 artikelen, context van de interventie,
  transcript), plus ongeveer 1.500 tokens voor een foto.
- **Uitvoer:** ongeveer 1.500 tokens, inclusief het denkwerk van het model.

| | Spraak | Foto |
|---|---|---|
| Transcriptie met Voxtral (~1 min, $0,003–0,004/min) | ≈ € 0,003–0,004 | n.v.t. |
| Claude Sonnet 5.5 ($2 / $10 per miljoen tokens) | ≈ € 0,02 | ≈ € 0,025 |
| Claude Haiku 5.5 ($0,10 / $0,50) | ≈ € 0,001 | ≈ € 0,002 |
| Claude Opus 5.5 ($4 / $20) | ≈ € 0,04 | ≈ € 0,05 |

- **Per bon:** met Sonnet ongeveer **2 à 3 cent**.
- **Per maand:** bij ongeveer 230 bonnen is dat **€ 5 à 7** aan modelkosten. Storage en Edge Functions vallen binnen
  het gratis volume van Supabase.
- **Onzekerheid:** de Voxtral-prijs is nagekeken. De Claude-prijzen hierboven zijn de tarieven van de Anthropic API
  zelf. Via een cloudprovider in een EU-regio (beslissing 4) gelden de prijzen van die provider, en die kunnen
  afwijken. Reken ze na zodra provider en regio gekozen zijn. Aan de orde van grootte (enkele centen per bon)
  verandert dat waarschijnlijk niets.
- **Ter vergelijking:** het lek bij de onderhoudsonderdelen alleen al (€ 4.664) is meer dan vijftig jaar aan
  API-kosten. De echte winst zit in de doorlooptijd: 19 dagen overtypen wordt dezelfde dag.

## 7. Open punten

- Nagaan of onderdelen bij onderhoud aangerekend moeten worden of in het contract zitten.
- Cloudprovider en EU-regio kiezen, en nagaan of Sonnet 5.5 en structured output daar beschikbaar zijn.
- De prijzen van die provider narekenen.
- Modelkeuze pas vastleggen na de eval in laag b, op de synthetische set en op de zelf ingesproken bonnen.
