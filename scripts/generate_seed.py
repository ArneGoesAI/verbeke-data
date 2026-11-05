"""
Genereert fictieve, reproduceerbare testdata voor Verbeke Installatietechniek BV.

De cijfers volgen de case:
  - 38 medewerkers: 26 techniekers, 4 werfleiders/calculatoren, 5 administratie & planning
  - 1.800 onderhoudscontracten
  - offerte doorlooptijd 3 tot 4 weken, 40% nooit opgevolgd
  - werfbonnen op papier, facturatie 3 tot 6 weken achter

Gebruik:  python scripts/generate_seed.py > supabase/seed.sql
Alle namen, adressen en contactgegevens zijn verzonnen. E-mailadressen gebruiken
het gereserveerde domein example.com zodat een automatisatie nooit echte mensen mailt.
"""

import random
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

random.seed(42)
TZ = ZoneInfo("Europe/Brussels")
VANDAAG = date(2026, 11, 5)

# ─────────────────────────────────────────────
# Hulpfuncties
# ─────────────────────────────────────────────

out: list[str] = []


def q(v):
    """SQL-literal."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, datetime):
        return "'" + v.isoformat() + "'"
    if isinstance(v, date):
        return "'" + v.isoformat() + "'"
    return "'" + str(v).replace("'", "''") + "'"


def insert(table, cols, rows, chunk=500):
    if not rows:
        return
    for i in range(0, len(rows), chunk):
        part = rows[i:i + chunk]
        vals = ",\n".join("(" + ", ".join(q(v) for v in r) + ")" for r in part)
        out.append(
            f"insert into {table} ({', '.join(cols)}) overriding system value values\n{vals};\n"
        )


def werkdag(d: date) -> date:
    while d.weekday() >= 5:
        d += timedelta(days=1)
    return d


def ts(d: date, h: int, m: int = 0) -> datetime:
    return datetime.combine(d, time(h, m), tzinfo=TZ)


def euro(x) -> float:
    return round(float(x), 2)


# ─────────────────────────────────────────────
# Basislijsten
# ─────────────────────────────────────────────

VOORNAMEN_M = ["Jan", "Pieter", "Koen", "Bart", "Tom", "Wim", "Dirk", "Kris", "Stijn", "Joris",
               "Wout", "Jens", "Thomas", "Ruben", "Bram", "Lars", "Seppe", "Niels", "Glenn", "Kevin",
               "Dries", "Arno", "Robbe", "Tim", "Steven", "Geert", "Filip", "Marc", "Patrick", "Yves",
               "Sander", "Jonas", "Mathias", "Brecht", "Gert", "Hans", "Erik", "Frank", "Peter", "Johan"]
VOORNAMEN_V = ["An", "Els", "Katrien", "Sofie", "Lies", "Inge", "Veerle", "Sarah", "Lotte", "Hanne",
               "Eline", "Leen", "Nathalie", "Griet", "Ann", "Kim", "Evelien", "Jolien", "Lien", "Marijke",
               "Ilse", "Caroline", "Tine", "Femke", "Charlotte", "Elke", "Karen", "Liesbeth", "Nele", "Hilde"]
ACHTERNAMEN = ["Peeters", "Janssens", "Maes", "Jacobs", "Mertens", "Willems", "Claes", "Goossens",
               "Wouters", "De Smet", "Dubois", "Lambert", "Hermans", "De Clercq", "Van den Broeck",
               "Desmet", "De Backer", "Van de Velde", "Martens", "Coppens", "De Vos", "Verhaeghe",
               "Van Damme", "De Wilde", "Cools", "Pauwels", "Van Hecke", "De Meyer", "Bogaert",
               "Vandenberghe", "Declercq", "Van Acker", "De Paepe", "Moens", "Van Impe", "Baert",
               "De Bruyne", "Verstraete", "De Coninck", "Vermeulen", "Van Laere", "Schepens",
               "D'hondt", "Van Wesemael", "De Keyser", "Lievens", "Van Hoorebeke", "Bracke",
               "De Roeck", "Callebaut", "Van der Linden", "Rogiers", "Temmerman", "Steurbaut"]
GEMEENTEN = [  # (postcode, gemeente, gewicht) — rond de vestiging in Lede
    ("9340", "Lede", 10), ("9300", "Aalst", 14), ("9320", "Erembodegem", 4), ("9310", "Moorsel", 3),
    ("9420", "Erpe-Mere", 7), ("9400", "Ninove", 7), ("9470", "Denderleeuw", 5), ("9450", "Haaltert", 5),
    ("9230", "Wetteren", 7), ("9260", "Wichelen", 4), ("9290", "Berlare", 3), ("9200", "Dendermonde", 6),
    ("9620", "Zottegem", 5), ("9550", "Herzele", 4), ("9820", "Merelbeke", 4), ("9070", "Destelbergen", 3),
    ("9000", "Gent", 6), ("9050", "Gentbrugge", 2), ("9240", "Zele", 3), ("9160", "Lokeren", 4),
    ("9500", "Geraardsbergen", 4), ("9520", "Sint-Lievens-Houtem", 3), ("9860", "Oosterzele", 3),
]
STRATEN = ["Kerkstraat", "Stationsstraat", "Molenstraat", "Dorpsstraat", "Nieuwstraat", "Schoolstraat",
           "Kapelstraat", "Veldstraat", "Hoogstraat", "Beekstraat", "Lindenlaan", "Kouterstraat",
           "Bosstraat", "Meersstraat", "Kasteelstraat", "Groenstraat", "Hekkestraat", "Steenweg",
           "Populierenlaan", "Eikenlaan", "Ringlaan", "Akkerstraat", "Weverijstraat", "Broekstraat",
           "Heirbaan", "Langemunt", "Smissestraat", "Kluisstraat", "Hofstraat", "Pastorijstraat"]
BEDRIJFSTYPES = ["Bakkerij", "Tandartspraktijk", "Kapsalon", "Boekhoudkantoor", "Garage", "Apotheek",
                 "Brasserie", "Dierenartsenpraktijk", "Schrijnwerkerij", "Kinderdagverblijf",
                 "Fysiotherapie", "Architectenbureau", "Drukkerij", "Fietsenwinkel", "Notariskantoor"]


def gemeente():
    pc, gem, _ = random.choices(GEMEENTEN, weights=[g[2] for g in GEMEENTEN])[0]
    return pc, gem


def telefoon():
    return f"04{random.randint(70, 99)} {random.randint(10, 99)} {random.randint(10, 99)} {random.randint(10, 99)}"


def slug(s):
    return (s.lower().replace(" ", "").replace("'", "").replace("é", "e").replace("ë", "e"))


# ─────────────────────────────────────────────
# Medewerkers en vaardigheden
# ─────────────────────────────────────────────

VAARDIGHEDEN = [
    (1, "wp_lucht_water", "Warmtepomp lucht-water"),
    (2, "wp_geothermie", "Warmtepomp geothermie"),
    (3, "koeltechniek", "Koeltechniek (F-gassen certificaat)"),
    (4, "vent_d", "Ventilatie systeem D"),
    (5, "vent_c", "Ventilatie systeem C"),
    (6, "sanitair", "Sanitair"),
    (7, "elektriciteit", "Elektrische aansluitingen"),
    (8, "zonneboiler", "Zonneboiler"),
]
insert("vaardigheden", ["id", "code", "naam"], VAARDIGHEDEN)

medewerkers = []  # dicts
mid = 0


def add_mw(vn, an, rol, sinds, gem=None):
    global mid
    mid += 1
    g = gem or gemeente()[1]
    m = dict(id=mid, voornaam=vn, achternaam=an, rol=rol,
             email=f"{slug(vn)}.{slug(an)}@verbeke-installatie.example.com",
             telefoon=telefoon(), thuis_gemeente=g, in_dienst_sinds=sinds)
    medewerkers.append(m)
    return m


LUC = add_mw("Luc", "Verbeke", "zaakvoerder", date(1991, 3, 1), "Lede")
SARAH = add_mw("Sarah", "Verbeke", "commercieel", date(2015, 9, 1), "Lede")
MARTINE = add_mw("Martine", "De Smet", "planner", date(2001, 2, 1), "Erpe-Mere")
add_mw("Katrien", "Moens", "administratie", date(2012, 5, 14))
add_mw("Ilse", "Baert", "administratie", date(2019, 1, 7))
add_mw("Hilde", "Cools", "klantendienst", date(2008, 10, 1))   # halftijds
add_mw("Femke", "Lievens", "klantendienst", date(2022, 4, 4))  # halftijds
WERFLEIDERS = [
    add_mw("Geert", "Van Damme", "werfleider", date(2004, 6, 1)),
    add_mw("Kris", "Bracke", "werfleider", date(2010, 3, 15)),
    add_mw("Stijn", "Pauwels", "werfleider", date(2017, 8, 21)),
]
add_mw("Ruben", "Temmerman", "calculator", date(2020, 11, 2))
add_mw("Dirk", "Rogiers", "magazijnier", date(1999, 4, 6))

gebruikt = {(m["voornaam"], m["achternaam"]) for m in medewerkers}
TECHNIEKERS = []
while len(TECHNIEKERS) < 26:
    vn, an = random.choice(VOORNAMEN_M), random.choice(ACHTERNAMEN)
    if (vn, an) in gebruikt:
        continue
    gebruikt.add((vn, an))
    sinds = date(random.randint(1996, 2026), random.randint(1, 12), 1)
    if sinds > VANDAAG:
        sinds = date(2026, 3, 1)
    TECHNIEKERS.append(add_mw(vn, an, "technieker", sinds))

# Profielen: elke technieker heeft een hoofdrichting
PROFIELEN = (
    [("warmtepomp", {1: 3, 3: 2, 7: 2, 2: 1})] * 10
    + [("ventilatie", {4: 3, 5: 3, 7: 1})] * 7
    + [("sanitair", {6: 3, 8: 2})] * 6
    + [("allround", {1: 2, 4: 2, 6: 2, 7: 2})] * 3
)
mv_rows = []
tech_skill = {}  # medewerker_id -> {vaardigheid_id: niveau}
tech_richting = {}
for t, (richting, skills) in zip(TECHNIEKERS, PROFIELEN):
    s = dict(skills)
    jaren = VANDAAG.year - t["in_dienst_sinds"].year
    if jaren < 2:  # nieuwe mensen: lager niveau
        s = {k: max(1, v - 1) for k, v in s.items()}
    if random.random() < 0.3:
        extra = random.choice([1, 4, 6, 7, 8])
        s.setdefault(extra, 1)
    tech_skill[t["id"]] = s
    tech_richting[t["id"]] = richting
    for v, n in s.items():
        mv_rows.append((t["id"], v, n))

insert("medewerkers",
       ["id", "voornaam", "achternaam", "rol", "email", "telefoon", "thuis_gemeente", "in_dienst_sinds", "actief"],
       [(m["id"], m["voornaam"], m["achternaam"], m["rol"], m["email"], m["telefoon"],
         m["thuis_gemeente"], m["in_dienst_sinds"], True) for m in medewerkers])
out.append("insert into medewerker_vaardigheden (medewerker_id, vaardigheid_id, niveau) values\n"
           + ",\n".join(f"({a}, {b}, {c})" for a, b, c in mv_rows) + ";\n")

# ─────────────────────────────────────────────
# Artikelen
# ─────────────────────────────────────────────

ART = [  # code, omschrijving, categorie, eenheid, verkoop, aankoop
    ("WP-LW-06", "Lucht-water warmtepomp 6 kW monobloc", "warmtepomp", "stuk", 7450, 5200),
    ("WP-LW-08", "Lucht-water warmtepomp 8 kW monobloc", "warmtepomp", "stuk", 8350, 5850),
    ("WP-LW-11", "Lucht-water warmtepomp 11 kW split", "warmtepomp", "stuk", 9900, 6950),
    ("WP-GEO-08", "Bodem-water warmtepomp 8 kW", "warmtepomp", "stuk", 11800, 8300),
    ("WP-BUF-200", "Buffervat 200 l", "warmtepomp", "stuk", 890, 560),
    ("WP-SWW-300", "Sanitair warmwaterboiler 300 l", "warmtepomp", "stuk", 1650, 1090),
    ("WP-CONS", "Montageconsole en trillingsdempers buitenunit", "onderdeel", "stuk", 245, 120),
    ("WP-KOEL", "Koelmiddel bijvullen R32 (per kg)", "onderdeel", "stuk", 95, 38),
    ("VENT-D-350", "Ventilatie-unit systeem D 350 m³/h met WTW", "ventilatie", "stuk", 3950, 2650),
    ("VENT-D-450", "Ventilatie-unit systeem D 450 m³/h met WTW", "ventilatie", "stuk", 4450, 3000),
    ("VENT-C-VRAAG", "Vraaggestuurde ventilatie systeem C", "ventilatie", "stuk", 2350, 1550),
    ("VENT-KAN", "Ventilatiekanaal geïsoleerd", "ventilatie", "m", 28, 11),
    ("VENT-VENT", "Ventiel toevoer/afvoer", "ventilatie", "stuk", 34, 14),
    ("VENT-FILT", "Filterset ventilatie-unit", "onderdeel", "stuk", 49, 18),
    ("SAN-DOUCHE", "Inloopdouche compleet met thermostatische kraan", "sanitair", "stuk", 1890, 1150),
    ("SAN-WC", "Hangtoilet met inbouwreservoir", "sanitair", "stuk", 690, 380),
    ("SAN-LAVABO", "Badkamermeubel met lavabo 80 cm", "sanitair", "stuk", 940, 560),
    ("SAN-BUIS", "Meerlagenbuis met koppelingen", "sanitair", "m", 14, 5),
    ("SAN-ONTH", "Waterontharder", "sanitair", "stuk", 1450, 890),
    ("ZB-ONDERD", "Onderdelenset zonneboiler", "onderdeel", "stuk", 120, 55),
    ("OND-PRES", "Expansievat 18 l", "onderdeel", "stuk", 89, 36),
    ("OND-SENS", "Temperatuursensor", "onderdeel", "stuk", 64, 22),
    ("OND-PCB", "Printplaat binnenunit", "onderdeel", "stuk", 485, 270),
    ("OND-VENTIEL", "Driewegklep", "onderdeel", "stuk", 215, 110),
    ("OND-POMP", "Circulatiepomp", "onderdeel", "stuk", 295, 150),
    ("ARB-TECH", "Arbeid technieker", "arbeid", "uur", 62, None),
    ("ARB-ONDERH-WP", "Jaarlijks onderhoud warmtepomp", "arbeid", "forfait", 215, None),
    ("ARB-ONDERH-VENT", "Jaarlijks onderhoud ventilatie", "arbeid", "forfait", 145, None),
    ("ARB-ONDERH-ZB", "Jaarlijks onderhoud zonneboiler", "arbeid", "forfait", 140, None),
    ("ELEK-AANSL", "Elektrische aansluiting en zekering", "onderdeel", "forfait", 385, 140),
    ("VERPL", "Verplaatsingskosten", "verplaatsing", "forfait", 45, None),
    ("KM", "Kilometervergoeding", "verplaatsing", "km", 0.45, None),
]
art_id = {}
art_rows = []
for i, a in enumerate(ART, start=1):
    art_id[a[0]] = i
    art_rows.append((i,) + a)
insert("artikelen", ["id", "code", "omschrijving", "categorie", "eenheid", "verkoopprijs", "aankoopprijs"], art_rows)
PRIJS = {a[0]: a[4] for a in ART}

# ─────────────────────────────────────────────
# Klanten
# ─────────────────────────────────────────────

klanten = []
for kid in range(1, 1701):
    pc, gem = gemeente()
    straat, nr = random.choice(STRATEN), str(random.randint(1, 180))
    if random.random() < 0.15:
        nr += random.choice(["A", "B", " bus 2", " bus 1"])
    aangemaakt = ts(date(2014, 1, 1) + timedelta(days=random.randint(0, (date(2026, 9, 30) - date(2014, 1, 1)).days)),
                    random.randint(8, 17), random.choice([0, 15, 30, 45]))
    if kid <= 1600:
        vn = random.choice(VOORNAMEN_M + VOORNAMEN_V)
        an = random.choice(ACHTERNAMEN)
        k = dict(id=kid, type="particulier", voornaam=vn, achternaam=an, bedrijfsnaam=None, btw=None,
                 email=f"{slug(vn)}.{slug(an)}{random.randint(1, 99)}@example.com" if random.random() < 0.85 else None)
    else:
        bt, an = random.choice(BEDRIJFSTYPES), random.choice(ACHTERNAMEN)
        naam = f"{bt} {an}"
        k = dict(id=kid, type="bedrijf", voornaam=None, achternaam=None, bedrijfsnaam=naam,
                 btw=f"BE0{random.randint(400, 999)}.{random.randint(100, 999)}.{random.randint(100, 999)}",
                 email=f"info@{slug(bt)}{slug(an)}.example.com")
    k.update(telefoon=telefoon(), straat=straat, huisnummer=nr, postcode=pc, gemeente=gem, aangemaakt_op=aangemaakt)
    klanten.append(k)

insert("klanten",
       ["id", "type", "voornaam", "achternaam", "bedrijfsnaam", "btw_nummer", "email", "telefoon",
        "straat", "huisnummer", "postcode", "gemeente", "aangemaakt_op"],
       [(k["id"], k["type"], k["voornaam"], k["achternaam"], k["bedrijfsnaam"], k["btw"], k["email"],
         k["telefoon"], k["straat"], k["huisnummer"], k["postcode"], k["gemeente"], k["aangemaakt_op"])
        for k in klanten])
KLANT = {k["id"]: k for k in klanten}


def klantnaam(k):
    return k["bedrijfsnaam"] or f"{k['voornaam']} {k['achternaam']}"


# ─────────────────────────────────────────────
# Planning-hulp: wie is wanneer bezet?
# ─────────────────────────────────────────────

bezet: dict[tuple[int, date], int] = {}  # (medewerker, dag) -> aantal ingeplande blokken (max 4 per dag)


def kies_tech(dag, vaardigheid, n=1, blokken=1, uitsluiten=()):
    kandidaten = [t["id"] for t in TECHNIEKERS
                  if vaardigheid in tech_skill[t["id"]]
                  and t["in_dienst_sinds"] <= dag
                  and t["id"] not in uitsluiten
                  and bezet.get((t["id"], dag), 0) + blokken <= 4]
    if len(kandidaten) < n:
        kandidaten = [t["id"] for t in TECHNIEKERS
                      if t["in_dienst_sinds"] <= dag and bezet.get((t["id"], dag), 0) + blokken <= 4
                      and t["id"] not in uitsluiten]
    random.shuffle(kandidaten)
    # voorkeur voor hoger niveau
    kandidaten.sort(key=lambda i: -tech_skill[i].get(vaardigheid, 0))
    gekozen = kandidaten[:n]
    for g in gekozen:
        bezet[(g, dag)] = bezet.get((g, dag), 0) + blokken
    return gekozen


# ─────────────────────────────────────────────
# Onderhoudscontracten (1.800)
# ─────────────────────────────────────────────

MERKEN = {
    "warmtepomp": [("Daikin", ["Altherma 3 R 8 kW", "Altherma 3 H 11 kW"]),
                   ("Vaillant", ["aroTHERM plus 7 kW", "aroTHERM plus 10 kW"]),
                   ("Viessmann", ["Vitocal 250-A 8 kW"]),
                   ("Mitsubishi Electric", ["Ecodan 8 kW"]),
                   ("Panasonic", ["Aquarea 9 kW"]),
                   ("Nibe", ["S2125 8 kW", "S1155 geothermie 8 kW"])],
    "ventilatie": [("Renson", ["Endura Delta 380", "Healthbox 3.0"]),
                   ("Zehnder", ["ComfoAir Q350", "ComfoAir Q450"]),
                   ("Brink", ["Flair 325"]),
                   ("Itho Daalderop", ["HRU ECO 350"])],
    "zonneboiler": [("Viessmann", ["Vitosol 200-FM"]), ("Vaillant", ["auroSTEP plus 250"])],
}
JAARPRIJS = {"warmtepomp": (195, 245), "ventilatie": (125, 165), "zonneboiler": (135, 150)}


def maand_plus(d: date, maanden: int) -> date:
    m = d.month - 1 + maanden
    y = d.year + m // 12
    m = m % 12 + 1
    dag = min(d.day, 28)
    return date(y, m, dag)


contracten = []
klant_ids = [k["id"] for k in klanten]
random.shuffle(klant_ids)
contract_klanten = klant_ids[:1500] + random.sample(klant_ids[:1500], 300)  # 300 klanten met 2 contracten
gezien = {}
for cid, kid in enumerate(contract_klanten, start=1):
    if kid in gezien:  # tweede contract: ander type
        tt = "ventilatie" if gezien[kid] == "warmtepomp" else "warmtepomp"
    else:
        tt = random.choices(["warmtepomp", "ventilatie", "zonneboiler"], weights=[58, 36, 6])[0]
    gezien[kid] = tt
    merk, modellen = random.choice(MERKEN[tt])
    inst = date(2015, 1, 1) + timedelta(days=random.randint(0, (date(2026, 6, 30) - date(2015, 1, 1)).days))
    status = "opgezegd" if random.random() < 0.04 else "actief"
    if inst > VANDAAG - timedelta(days=365):
        laatste = None
        volgend = maand_plus(inst, 12)
    else:
        # laatste onderhoud ergens in de voorbije 14 maanden
        laatste = werkdag(VANDAAG - timedelta(days=random.randint(5, 420)))
        volgend = maand_plus(laatste, 12)
    contracten.append(dict(id=cid, klant_id=kid, type=tt, merk=merk, model=random.choice(modellen),
                           inst=inst, laatste=laatste, volgend=volgend,
                           prijs=random.randint(*JAARPRIJS[tt]), status=status))

insert("onderhoudscontracten",
       ["id", "klant_id", "toesteltype", "merk", "model", "installatiedatum", "frequentie_maanden",
        "laatste_onderhoud", "volgend_onderhoud", "jaarprijs", "status"],
       [(c["id"], c["klant_id"], c["type"], c["merk"], c["model"], c["inst"], 12, c["laatste"],
         c["volgend"], c["prijs"], c["status"]) for c in contracten])

# ─────────────────────────────────────────────
# Aanvragen → offertes → werven
# ─────────────────────────────────────────────

OMSCHRIJVINGEN = {
    "warmtepomp": [
        "Wij willen onze gasketel vervangen door een warmtepomp. Woning uit 1985, deels gerenoveerd, vloerverwarming beneden.",
        "Graag een offerte voor een lucht-water warmtepomp. We bouwen nieuw, oplevering voorzien in het voorjaar.",
        "Stookolieketel is 22 jaar oud. Is een warmtepomp mogelijk met gewone radiatoren?",
        "Interesse in hybride warmtepomp of volledig elektrisch. Wat raden jullie aan voor een rijwoning?",
        "Buurman heeft er een van jullie. Wij willen ook overschakelen, graag plaatsbezoek.",
        "Offerte gevraagd voor warmtepomp + boiler voor sanitair warm water. Dak heeft zonnepanelen.",
    ],
    "ventilatie": [
        "Veel condens aan de ramen in de slaapkamers. Graag advies over ventilatie.",
        "Renovatie lopende, architect adviseert systeem D. Kunnen jullie een prijs geven?",
        "Bestaande ventilatie maakt veel lawaai, mogelijk vervangen door nieuw toestel.",
        "Nieuwbouw, EPB-verslaggever vraagt ventilatie. Plannen in bijlage.",
    ],
    "sanitair": [
        "Badkamer volledig vernieuwen: inloopdouche, hangtoilet en meubel. Tegels doet de aannemer.",
        "Waterontharder plaatsen, veel kalk in het water.",
        "Tweede badkamer op zolder, leidingen moeten nog getrokken worden.",
    ],
    "renovatie": [
        "Totaalrenovatie van een woning uit 1960: verwarming, ventilatie en badkamer. Graag één aanspreekpunt.",
        "Wij kochten een oudere woning en willen alles in één keer laten doen. Wanneer kan iemand langskomen?",
    ],
    "herstelling": [
        "Warmtepomp geeft foutcode en verwarmt niet meer. Dringend!",
        "Ventilatie-unit maakt een tikkend geluid.",
        "Lek onder de boiler, water op de vloer.",
        "Geen warm water sinds gisteren.",
    ],
}

aanvragen, offertes, olijnen, werven = [], [], [], []
start_aanvragen = VANDAAG - timedelta(days=270)
oid = wid = olid = 0
for aid in range(1, 421):
    onderwerp = random.choices(["warmtepomp", "ventilatie", "sanitair", "renovatie", "herstelling"],
                               weights=[42, 20, 16, 7, 15])[0]
    kanaal = random.choices(["telefoon", "mail", "webformulier"], weights=[40, 35, 25])[0]
    ontvangen_dag = start_aanvragen + timedelta(days=random.randint(0, 269))
    ontvangen = ts(ontvangen_dag, random.randint(7, 21), random.choice([0, 10, 25, 40, 55]))
    # bestaande of nieuwe klant
    kid = random.choice(klant_ids) if random.random() < 0.35 or onderwerp == "herstelling" else random.randint(1, 1600)
    wl = random.choice(WERFLEIDERS)["id"]
    leeftijd = (VANDAAG - ontvangen_dag).days

    if onderwerp == "herstelling":
        status = "gewonnen"  # gaat rechtstreeks naar de planning
        aanvragen.append((aid, kid, kanaal, onderwerp, random.choice(OMSCHRIJVINGEN[onderwerp]), ontvangen, status, None))
        continue

    # pipeline-vertraging: 3 tot 4 weken van aanvraag tot verstuurde offerte
    plaatsbezoek = werkdag(ontvangen_dag + timedelta(days=random.randint(5, 12)))
    opgemaakt = werkdag(plaatsbezoek + timedelta(days=random.randint(10, 18)))
    verstuurd = werkdag(opgemaakt + timedelta(days=random.randint(0, 4)))

    if leeftijd < 6:
        aanvragen.append((aid, kid, kanaal, onderwerp, random.choice(OMSCHRIJVINGEN[onderwerp]), ontvangen, "nieuw", None))
        continue
    if plaatsbezoek > VANDAAG:
        aanvragen.append((aid, kid, kanaal, onderwerp, random.choice(OMSCHRIJVINGEN[onderwerp]), ontvangen, "plaatsbezoek_gepland", wl))
        continue
    if random.random() < 0.12:  # klant haakt af voor offerte
        aanvragen.append((aid, kid, kanaal, onderwerp, random.choice(OMSCHRIJVINGEN[onderwerp]), ontvangen, "verloren", wl))
        continue

    oid += 1
    btw = 21 if KLANT[kid]["type"] == "bedrijf" or random.random() < 0.2 else 6
    nummer = f"OF-{verstuurd.year if verstuurd <= VANDAAG else VANDAAG.year}-{oid:04d}"

    # offertelijnen
    lijnen = []
    if onderwerp in ("warmtepomp", "renovatie"):
        wp = random.choice(["WP-LW-06", "WP-LW-08", "WP-LW-08", "WP-LW-11", "WP-GEO-08"])
        lijnen += [(wp, 1), ("WP-BUF-200", 1), ("WP-CONS", 1), ("ELEK-AANSL", 1),
                   ("ARB-TECH", random.choice([16, 20, 24, 32]))]
        if random.random() < 0.6:
            lijnen.append(("WP-SWW-300", 1))
    if onderwerp in ("ventilatie", "renovatie"):
        unit = random.choice(["VENT-D-350", "VENT-D-450", "VENT-C-VRAAG"])
        lijnen += [(unit, 1), ("VENT-KAN", random.randint(25, 60)), ("VENT-VENT", random.randint(6, 12)),
                   ("ARB-TECH", random.choice([12, 16, 20]))]
    if onderwerp in ("sanitair", "renovatie"):
        if random.random() < 0.25 and onderwerp == "sanitair":
            lijnen += [("SAN-ONTH", 1), ("SAN-BUIS", 6), ("ARB-TECH", 4)]
        else:
            lijnen += [("SAN-DOUCHE", 1), ("SAN-WC", 1), ("SAN-LAVABO", 1), ("SAN-BUIS", random.randint(15, 35)),
                       ("ARB-TECH", random.choice([16, 24, 32]))]
    totaal = 0.0
    for code, aantal in lijnen:
        olid += 1
        olijnen.append((olid, oid, art_id[code], aantal, PRIJS[code]))
        totaal += aantal * PRIJS[code]

    # status, opvolging en beslissing
    opvolging = beslist = None
    if verstuurd > VANDAAG:
        ostatus, verstuurd_op = "concept", None
        astatus = "offerte_in_opmaak"
    else:
        verstuurd_op = verstuurd
        opgevolgd = random.random() < 0.60   # 40% wordt nooit opgevolgd
        dagen_sinds = (VANDAAG - verstuurd).days
        r = random.random()
        if opgevolgd:
            opvolging = werkdag(verstuurd + timedelta(days=random.randint(7, 21)))
            if opvolging > VANDAAG:
                opvolging = None
            if r < 0.55 and dagen_sinds > 7:
                ostatus = "aanvaard"
            elif r < 0.80 and dagen_sinds > 7:
                ostatus = "geweigerd"
            else:
                ostatus = "verstuurd" if dagen_sinds <= 60 else "verlopen"
        else:
            if r < 0.15 and dagen_sinds > 10:
                ostatus = "aanvaard"   # klant belt zelf terug
            elif r < 0.22 and dagen_sinds > 10:
                ostatus = "geweigerd"
            else:
                ostatus = "verstuurd" if dagen_sinds <= 60 else "verlopen"
        if ostatus in ("aanvaard", "geweigerd"):
            beslist = werkdag(verstuurd + timedelta(days=random.randint(8, min(45, max(9, dagen_sinds)))))
            if beslist > VANDAAG:
                beslist = VANDAAG
        astatus = {"aanvaard": "gewonnen", "geweigerd": "verloren", "verlopen": "geen_opvolging"}.get(ostatus, "offerte_verstuurd")
        if ostatus == "verlopen" and opvolging is not None:
            astatus = "verloren"

    aanvragen.append((aid, kid, kanaal, onderwerp, random.choice(OMSCHRIJVINGEN[onderwerp]), ontvangen, astatus, wl))
    offertes.append(dict(id=oid, nummer=nummer, aanvraag_id=aid, klant_id=kid, wl=wl, status=ostatus,
                         plaatsbezoek=plaatsbezoek, opgemaakt=opgemaakt if opgemaakt <= VANDAAG else VANDAAG,
                         verstuurd=verstuurd_op, opvolging=opvolging, beslist=beslist, btw=btw,
                         totaal=euro(totaal), onderwerp=onderwerp))

    if ostatus == "aanvaard":
        wid += 1
        start = werkdag(beslist + timedelta(days=random.randint(14, 42)))
        duur = {"warmtepomp": 3, "ventilatie": 2, "sanitair": 3, "renovatie": 7}[onderwerp]
        eind = start
        for _ in range(duur - 1):
            eind = werkdag(eind + timedelta(days=1))
        if start > VANDAAG:
            wstatus = "gepland"
        elif eind >= VANDAAG:
            wstatus = "lopend"
        elif (VANDAAG - eind).days < 10:
            wstatus = "afgewerkt"
        else:
            wstatus = "opgeleverd"
        k = KLANT[kid]
        werven.append(dict(id=wid, offerte_id=oid, klant_id=kid, wl=wl,
                           omschrijving={"warmtepomp": "Plaatsing warmtepomp", "ventilatie": "Plaatsing ventilatiesysteem",
                                         "sanitair": "Sanitaire werken", "renovatie": "Renovatie technieken"}[onderwerp],
                           k=k, status=wstatus, start=start, eind=eind, onderwerp=onderwerp, duur=duur,
                           groep=f"Werf {k['achternaam'] or k['bedrijfsnaam']} {k['gemeente']}"))

insert("aanvragen", ["id", "klant_id", "kanaal", "onderwerp", "omschrijving", "ontvangen_op", "status", "werfleider_id"], aanvragen)
insert("offertes",
       ["id", "nummer", "aanvraag_id", "klant_id", "werfleider_id", "status", "plaatsbezoek_op", "opgemaakt_op",
        "verstuurd_op", "laatste_opvolging_op", "beslist_op", "btw_tarief", "totaal_excl_btw"],
       [(o["id"], o["nummer"], o["aanvraag_id"], o["klant_id"], o["wl"], o["status"], o["plaatsbezoek"],
         o["opgemaakt"], o["verstuurd"], o["opvolging"], o["beslist"], o["btw"], o["totaal"]) for o in offertes])
insert("offerte_lijnen", ["id", "offerte_id", "artikel_id", "aantal", "eenheidsprijs"], olijnen)
insert("werven",
       ["id", "offerte_id", "klant_id", "werfleider_id", "omschrijving", "straat", "huisnummer", "postcode",
        "gemeente", "status", "startdatum", "einddatum", "whatsapp_groep"],
       [(w["id"], w["offerte_id"], w["klant_id"], w["wl"], w["omschrijving"], w["k"]["straat"], w["k"]["huisnummer"],
         w["k"]["postcode"], w["k"]["gemeente"], w["status"], w["start"], w["eind"], w["groep"]) for w in werven])
OFFERTE = {o["id"]: o for o in offertes}

# ─────────────────────────────────────────────
# Interventies (planning) en werfbonnen
# ─────────────────────────────────────────────

interventies, it_rows, bonnen, bonlijnen = [], [], [], []
iid = bid = blid = 0
GESCHIEDENIS = VANDAAG - timedelta(weeks=16)   # oudere uitvoering is gefactureerd en gearchiveerd
HORIZON = VANDAAG + timedelta(weeks=6)

NOTITIES_ONDERHOUD = {
    "warmtepomp": ["filters gekuist, druk ok 1,6 bar", "druk te laag, bijgevuld tot 1,5 bar",
                   "buitenunit vuil, gereinigd. klant vraagt naar thermostaat app",
                   "foutcode historiek gecheckt, niks bijzonders", "sensor buitentemp vervangen",
                   "klant vraagt offerte voor ventilatie D!", "koelmiddel gecontroleerd geen lek",
                   "expansievat bijna leeg -> vervangen", "alles ok", "condensafvoer verstopt, vrijgemaakt"],
    "ventilatie": ["filters vervangen", "filters vervangen + ventielen gekuist", "debieten ingeregeld",
                   "unit maakt lawaai, lager versleten? opvolgen", "alles ok, klant tevreden",
                   "filters vervangen. klant wil ook offerte badkamer"],
    "zonneboiler": ["glycol gecontroleerd ok", "druk bijgezet", "collector gereinigd", "alles ok"],
}
NOTITIES_HERSTELLING = [
    ("printplaat binnenunit defect, vervangen", "OND-PCB"), ("driewegklep hing vast, vervangen", "OND-VENTIEL"),
    ("circulatiepomp kapot", "OND-POMP"), ("lek aan koppeling boiler, hersteld", "SAN-BUIS"),
    ("sensor defect", "OND-SENS"), ("expansievat lek", "OND-PRES"), ("reset + software update, geen onderdelen", None),
]
NOTITIES_WERF = ["dag 1: buitenunit geplaatst", "leidingen getrokken", "opstart gedaan, klant uitleg gegeven",
                 "wachten op elektricien", "kanalen in zolder gelegd", "materiaal tekort: 2 ventielen",
                 "afgewerkt, nog opkuis", "inregelen gedaan", "", "klant niet thuis, sleutel bij buren"]


def bon_status(dag: date):
    d = (VANDAAG - dag).days
    r = random.random()
    if d > 45:
        return "gefactureerd" if r < 0.97 else "ingegeven"
    if d > 21:
        return "gefactureerd" if r < 0.30 else ("ingegeven" if r < 0.65 else "op_papier")
    return "op_papier" if r < 0.75 else "ingegeven"


def maak_bon(iid_, tech, dag, uren, km, notitie, lijnen):
    global bid, blid
    bid += 1
    st = bon_status(dag)
    ingegeven = None
    if st != "op_papier":
        ingegeven = min(VANDAAG, werkdag(dag + timedelta(days=random.randint(10, 30))))
    bonnen.append(dict(id=bid, nummer=f"WB-{dag.year}-{bid:05d}", interventie_id=iid_, tech=tech, datum=dag,
                       uren=uren, km=km, notitie=notitie, getekend=random.random() > 0.06, status=st,
                       ingegeven=ingegeven, factuur_id=None))
    for code, aantal in lijnen:
        blid += 1
        bonlijnen.append((blid, bid, art_id[code], aantal))
    return bid


def add_interventie(type_, kid, start, eind, status, oms, werf_id=None, contract_id=None):
    global iid
    iid += 1
    interventies.append((iid, type_, kid, werf_id, contract_id, start, eind, status, oms))
    return iid


# 1. Plaatsbezoeken door de werfleider
for o in offertes:
    d = o["plaatsbezoek"]
    if d < GESCHIEDENIS:
        continue
    h = random.choice([8, 10, 13, 15, 17])
    i = add_interventie("plaatsbezoek", o["klant_id"], ts(d, h), ts(d, h + 1, 30), "uitgevoerd",
                        f"Plaatsbezoek {o['onderwerp']}")
    it_rows.append((i, o["wl"]))
for a in aanvragen:
    if a[6] == "plaatsbezoek_gepland":
        d = werkdag(VANDAAG + timedelta(days=random.randint(1, 8)))
        h = random.choice([8, 10, 13, 15])
        i = add_interventie("plaatsbezoek", a[1], ts(d, h), ts(d, h + 1, 30), "gepland", f"Plaatsbezoek {a[3]}")
        it_rows.append((i, a[7]))

# 2. Installaties op werven
VAARD_VOOR = {"warmtepomp": 1, "ventilatie": 4, "sanitair": 6, "renovatie": 1}
werf_bonnen: dict[int, list[int]] = {}
for w in werven:
    dag = w["start"]
    ploeg = None
    for n in range(w["duur"]):
        if dag < GESCHIEDENIS or dag > HORIZON:
            dag = werkdag(dag + timedelta(days=1))
            continue
        if ploeg is None or random.random() < 0.15:
            ploeg = kies_tech(dag, VAARD_VOOR[w["onderwerp"]], n=2, blokken=4)
        else:
            for t in ploeg:
                bezet[(t, dag)] = 4
        status = "uitgevoerd" if dag < VANDAAG else "gepland"
        i = add_interventie("installatie", w["klant_id"], ts(dag, 7, 30), ts(dag, 16, 0), status,
                            f"{w['omschrijving']} — dag {n + 1}/{w['duur']}", werf_id=w["id"])
        for t in ploeg:
            it_rows.append((i, t))
            if status == "uitgevoerd":
                b = maak_bon(i, t, dag, random.choice([7.5, 8, 8, 8.5, 9]), random.randint(10, 60),
                             random.choice(NOTITIES_WERF), [("ARB-TECH", 8)])
                werf_bonnen.setdefault(w["id"], []).append(b)
        dag = werkdag(dag + timedelta(days=1))

# 3. Onderhoud: uitgevoerd (laatste 16 weken), gepland (komende 6 weken), achterstallig (te plannen)
VAARD_ONDERH = {"warmtepomp": 1, "ventilatie": 4, "zonneboiler": 8}
FORFAIT = {"warmtepomp": "ARB-ONDERH-WP", "ventilatie": "ARB-ONDERH-VENT", "zonneboiler": "ARB-ONDERH-ZB"}
onderhoud_bonnen = []  # (bon_id, contract)
for c in contracten:
    if c["status"] != "actief":
        continue
    # uitgevoerd onderhoud
    if c["laatste"] and c["laatste"] >= GESCHIEDENIS:
        dag = c["laatste"]
        tech = kies_tech(dag, VAARD_ONDERH[c["type"]])
        h = 8 + 2 * (bezet[(tech[0], dag)] - 1)
        i = add_interventie("onderhoud", c["klant_id"], ts(dag, h), ts(dag, h + 1, 30), "uitgevoerd",
                            f"Jaarlijks onderhoud {c['type']} {c['merk']}", contract_id=c["id"])
        it_rows.append((i, tech[0]))
        lijnen = [(FORFAIT[c["type"]], 1)]
        notitie = random.choice(NOTITIES_ONDERHOUD[c["type"]])
        if "vervangen" in notitie and c["type"] == "ventilatie":
            lijnen.append(("VENT-FILT", 1))
        if "expansievat" in notitie:
            lijnen.append(("OND-PRES", 1))
        if "sensor" in notitie:
            lijnen.append(("OND-SENS", 1))
        b = maak_bon(i, tech[0], dag, random.choice([1, 1.25, 1.5, 1.5, 2]), random.randint(4, 45), notitie, lijnen)
        onderhoud_bonnen.append((b, c))
    # volgend onderhoud
    if c["volgend"] < VANDAAG:
        add_interventie("onderhoud", c["klant_id"], None, None, "te_plannen",
                        f"Achterstallig onderhoud {c['type']} {c['merk']}", contract_id=c["id"])
    elif c["volgend"] <= HORIZON and random.random() < 0.7:
        dag = werkdag(c["volgend"])
        tech = kies_tech(dag, VAARD_ONDERH[c["type"]])
        if tech:
            h = 8 + 2 * (bezet[(tech[0], dag)] - 1)
            i = add_interventie("onderhoud", c["klant_id"], ts(dag, h), ts(dag, h + 1, 30), "gepland",
                                f"Jaarlijks onderhoud {c['type']} {c['merk']}", contract_id=c["id"])
            it_rows.append((i, tech[0]))
    elif c["volgend"] <= HORIZON:
        add_interventie("onderhoud", c["klant_id"], None, None, "te_plannen",
                        f"Jaarlijks onderhoud {c['type']} {c['merk']}", contract_id=c["id"])

# 4. Herstellingen uit aanvragen
herstel_bonnen = []
for a in aanvragen:
    if a[3] != "herstelling":
        continue
    dag = werkdag(a[5].date() + timedelta(days=random.randint(1, 4)))
    if dag < GESCHIEDENIS:
        continue
    status = "uitgevoerd" if dag < VANDAAG else "gepland"
    vaard = random.choice([1, 1, 4, 6])
    tech = kies_tech(dag, vaard)
    if not tech:
        continue
    h = 8 + 2 * (bezet[(tech[0], dag)] - 1)
    i = add_interventie("herstelling", a[1], ts(dag, h), ts(dag, h + 2), status, a[4][:80])
    it_rows.append((i, tech[0]))
    if status == "uitgevoerd":
        notitie, onderdeel = random.choice(NOTITIES_HERSTELLING)
        uren = random.choice([1, 1.5, 2, 2.5, 3])
        lijnen = [("ARB-TECH", uren), ("VERPL", 1)] + ([(onderdeel, 1)] if onderdeel else [])
        b = maak_bon(i, tech[0], dag, uren, random.randint(5, 50), notitie, lijnen)
        herstel_bonnen.append((b, a[1]))

# 5. Storingen bij contractklanten (telefonisch gemeld, rechtstreeks ingepland)
STORINGEN = {"warmtepomp": "Storing warmtepomp: verwarmt niet of geeft foutcode",
             "ventilatie": "Storing ventilatie: lawaai of werkt niet",
             "zonneboiler": "Storing zonneboiler: geen warm water"}
for _ in range(120):
    c = random.choice(contracten)
    dag = werkdag(GESCHIEDENIS + timedelta(days=random.randint(0, (VANDAAG - GESCHIEDENIS).days + 10)))
    status = "uitgevoerd" if dag < VANDAAG else "gepland"
    tech = kies_tech(dag, VAARD_ONDERH[c["type"]])
    if not tech:
        continue
    h = 8 + 2 * (bezet[(tech[0], dag)] - 1)
    i = add_interventie("herstelling", c["klant_id"], ts(dag, h), ts(dag, h + 2), status,
                        f"{STORINGEN[c['type']]} ({c['merk']} {c['model']})", contract_id=c["id"])
    it_rows.append((i, tech[0]))
    if status == "uitgevoerd":
        notitie, onderdeel = random.choice(NOTITIES_HERSTELLING)
        uren = random.choice([1, 1.5, 2, 2.5])
        lijnen = [("ARB-TECH", uren), ("VERPL", 1)] + ([(onderdeel, 1)] if onderdeel else [])
        b = maak_bon(i, tech[0], dag, uren, random.randint(5, 50), notitie, lijnen)
        herstel_bonnen.append((b, c["klant_id"]))

insert("interventies",
       ["id", "type", "klant_id", "werf_id", "contract_id", "gepland_start", "gepland_eind", "status", "omschrijving"],
       interventies)
out.append("insert into interventie_techniekers (interventie_id, medewerker_id) values\n"
           + ",\n".join(f"({a}, {b})" for a, b in sorted(set(it_rows))) + ";\n")

# ─────────────────────────────────────────────
# Facturen
# ─────────────────────────────────────────────

BON = {b["id"]: b for b in bonnen}
facturen, flijnen = [], []
fid = flid = 0


def maak_factuur(kid, basisdag, btw, lijnen, bon_ids):
    global fid, flid
    fid += 1
    fdatum = werkdag(basisdag)
    if fdatum > VANDAAG:
        fdatum = VANDAAG
    verval = fdatum + timedelta(days=30)
    totaal = euro(sum(a * p for _, a, p in lijnen))
    if verval < VANDAAG:
        status = "betaald" if random.random() < 0.88 else "vervallen"
    else:
        status = "verstuurd"
    betaald = None
    if status == "betaald":
        betaald = min(VANDAAG, fdatum + timedelta(days=random.randint(5, 40)))
    facturen.append((fid, f"FA-{fdatum.year}-{fid:05d}", kid, fdatum, verval, btw, totaal, status, betaald))
    for oms, a, p in lijnen:
        flid += 1
        flijnen.append((flid, fid, oms, a, p))
    for b in bon_ids:
        BON[b]["factuur_id"] = fid


# onderhoud: factuur per bon, 3 tot 6 weken na uitvoering (de achterstand)
for b_id, c in onderhoud_bonnen:
    b = BON[b_id]
    if b["status"] != "gefactureerd":
        continue
    btw = 6 if KLANT[c["klant_id"]]["type"] == "particulier" else 21
    lijnen = [(f"Jaarlijks onderhoud {c['type']} {c['merk']} {c['model']}", 1, c["prijs"])]
    maak_factuur(c["klant_id"], b["datum"] + timedelta(days=random.randint(22, 44)), btw, lijnen, [b_id])

# herstellingen
for b_id, kid in herstel_bonnen:
    b = BON[b_id]
    if b["status"] != "gefactureerd":
        continue
    btw = 6 if KLANT[kid]["type"] == "particulier" else 21
    lijnen = [("Arbeid technieker", b["uren"], PRIJS["ARB-TECH"]), ("Verplaatsingskosten", 1, PRIJS["VERPL"])]
    for (_, bon, art, aantal) in [l for l in bonlijnen if l[1] == b_id]:
        code = ART[art - 1][0]
        if code.startswith("OND") or code.startswith("SAN"):
            lijnen.append((ART[art - 1][1], aantal, PRIJS[code]))
    maak_factuur(kid, b["datum"] + timedelta(days=random.randint(22, 44)), btw, lijnen, [b_id])

# werven: één eindfactuur per opgeleverde werf zodra alle bonnen gefactureerd zijn
for w in werven:
    ids = werf_bonnen.get(w["id"], [])
    if not ids or w["status"] != "opgeleverd":
        continue
    if all(BON[i]["status"] == "gefactureerd" for i in ids):
        o = OFFERTE[w["offerte_id"]]
        lijnen = [(f"{w['omschrijving']} volgens offerte {o['nummer']}", 1, o["totaal"])]
        maak_factuur(w["klant_id"], w["eind"] + timedelta(days=random.randint(20, 40)), o["btw"], lijnen, ids)
    else:  # deels ingegeven: nog niet gefactureerd
        for i in ids:
            if BON[i]["status"] == "gefactureerd":
                BON[i]["status"] = "ingegeven"

# gefactureerde bonnen zonder factuur (bv. werf nog niet opgeleverd) terugzetten
for b in bonnen:
    if b["status"] == "gefactureerd" and b["factuur_id"] is None:
        b["status"] = "ingegeven"

insert("facturen",
       ["id", "nummer", "klant_id", "factuurdatum", "vervaldatum", "btw_tarief", "totaal_excl_btw", "status", "betaald_op"],
       facturen)
insert("factuur_lijnen", ["id", "factuur_id", "omschrijving", "aantal", "eenheidsprijs"], flijnen)
insert("werfbonnen",
       ["id", "nummer", "interventie_id", "technieker_id", "datum", "uren", "km", "opmerkingen",
        "getekend_door_klant", "status", "ingegeven_op", "factuur_id"],
       [(b["id"], b["nummer"], b["interventie_id"], b["tech"], b["datum"], b["uren"], b["km"], b["notitie"] or None,
         b["getekend"], b["status"], b["ingegeven"], b["factuur_id"]) for b in bonnen])
insert("werfbon_lijnen", ["id", "werfbon_id", "artikel_id", "aantal"], bonlijnen)

# ─────────────────────────────────────────────
# Kennisdocumenten (voor RAG). Fictief en vereenvoudigd.
# ─────────────────────────────────────────────

DOCS = [
    ("Werkinstructie: jaarlijks onderhoud lucht-water warmtepomp", "werkinstructie", """
1. Meld je aan bij de klant en vraag naar opgemerkte problemen of foutcodes.
2. Lees de foutcodehistoriek uit via het bedieningspaneel en noteer ze op de werfbon.
3. Controleer de waterdruk van de installatie. Normaal: 1,2 tot 2,0 bar. Bijvullen indien lager.
4. Reinig het waterfilter (vuilfilter) in de retourleiding. Sluit eerst de kranen ervoor en erna.
5. Controleer de buitenunit: lamellen vrij van bladeren en vuil, condensafvoer open, trillingsdempers intact.
6. Controleer het expansievat: voordruk meten met de installatie drukloos.
7. Koelmiddelcircuit: visuele controle op olievlekken. Lekdetectie enkel door een technieker met F-gassen certificaat.
8. Controleer de instellingen van de stooklijn en de warmwaterprogrammatie met de klant.
9. Noteer uren, kilometers en gebruikte onderdelen op de werfbon en laat de klant tekenen.
"""),
    ("Werkinstructie: onderhoud ventilatie systeem D", "werkinstructie", """
1. Schakel de unit uit en wacht tot de ventilatoren stilstaan.
2. Vervang de filters (toevoer en afvoer). Noteer het filtertype op de werfbon.
3. Reinig de warmtewisselaar volgens de handleiding van de fabrikant, enkel lauw water.
4. Controleer de condensafvoer en de sifon.
5. Reinig minstens de ventielen in keuken en badkamer. Verdraai de ventielen niet: dat verandert het debiet.
6. Bij geluidsklachten: controleer de lagers van de ventilatoren en de bevestiging van de kanalen.
7. Zet de filterteller terug op nul en noteer alles op de werfbon.
"""),
    ("Veiligheidsfiche: werken met koelmiddel R32", "veiligheidsfiche", """
R32 is licht ontvlambaar (klasse A2L). Werk enkel met gecertificeerd materiaal en in een goed verluchte ruimte.
Geen open vuur, niet roken en geen vonkend gereedschap binnen 3 meter van het werkpunt.
Bij een lek: ruimte verluchten, installatie spanningsloos zetten en de werfleider verwittigen.
Werken aan het koelcircuit enkel door techniekers met een geldig F-gassen certificaat.
Draag veiligheidsbril en handschoenen: contact met vloeibaar koelmiddel geeft bevriezingswonden.
"""),
    ("Veiligheidsfiche: werken op hoogte en op daken", "veiligheidsfiche", """
Gebruik bij het plaatsen van een buitenunit op een plat dak altijd collectieve valbeveiliging of een harnas.
Ladders enkel voor korte werken, onder een hoek van ongeveer 75 graden en minstens 1 meter boven het uitstapniveau.
Werk nooit alleen op een dak. Bij wind boven 50 km/u worden dakwerken uitgesteld.
"""),
    ("Technische fiche: foutcodes warmtepompen (intern overzicht)", "technische_fiche", """
Dit is een vereenvoudigd intern overzicht. Raadpleeg altijd de handleiding van de fabrikant.
Lage waterdruk: druk onder 0,8 bar. Bijvullen en lekken zoeken.
Debietfout: vuilfilter verstopt of circulatiepomp defect. Eerst filter reinigen.
Hogedrukstoring: te weinig afname, bijvoorbeeld alle kranen dicht of driewegklep vast.
Communicatiefout binnen-buitenunit: bekabeling en printplaat controleren.
Sensorfout: sensorwaarde meten, sensor vervangen indien buiten bereik.
"""),
    ("FAQ klantendienst: wanneer komt de technieker?", "faq", """
Onderhoud wordt ingepland rond de verjaardag van het vorige onderhoud. De klant krijgt een week vooraf een bevestiging.
Een technieker komt in een tijdsblok: voormiddag (8u–12u) of namiddag (12u–16u). Een exact uur kunnen we niet garanderen.
Bij dringende herstellingen (geen verwarming of geen warm water) proberen we binnen 2 werkdagen langs te komen.
Een afspraak verplaatsen kan tot 2 werkdagen vooraf zonder kosten.
Na het onderhoud ontvangt de klant de factuur per mail.
"""),
    ("FAQ klantendienst: onderhoudscontract", "faq", """
Een onderhoudscontract omvat één jaarlijks onderhoud aan een vaste prijs. Onderdelen worden apart aangerekend.
Het contract wordt jaarlijks stilzwijgend verlengd en kan opgezegd worden tot één maand voor de vervaldatum.
Voor warmtepompen is jaarlijks onderhoud vaak een voorwaarde voor de fabrieksgarantie.
"""),
    ("Premieregels warmtepomp en ventilatie (fictief voorbeeld)", "premieregel", """
LET OP: dit document is een vereenvoudigd en fictief voorbeeld voor demodoeleinden. Echte premiebedragen en
voorwaarden veranderen regelmatig en moeten altijd bij de officiële instanties gecontroleerd worden.
Voorbeeldregels zoals Verbeke ze intern samenvat:
- Een premie voor een warmtepomp vraagt meestal een factuur van een erkende installateur en een plaatsing in een bestaande woning.
- Een verlaagd btw-tarief van 6% kan gelden voor renovatie van woningen ouder dan 10 jaar, onder voorwaarden.
- Voor ventilatie systeem D in renovatie gelden soms aparte premievoorwaarden.
De klant vraagt de premie zelf aan; Verbeke levert de nodige documenten (factuur, attest, technische fiche).
"""),
    ("Lastenboek-sjabloon: plaatsing lucht-water warmtepomp", "lastenboek", """
Omvat: levering en plaatsing van buitenunit op console of sokkel, hydraulische module, buffervat,
aansluiting op bestaande afgifte, elektrische aansluiting vanaf de verdeelkast, inregeling en opstart.
Niet inbegrepen: breek- en herstelwerken, aanpassing van de elektrische installatie buiten de verdeelkast,
vergunningen. Garantie: volgens fabrikant, op voorwaarde van jaarlijks onderhoud.
"""),
    ("Werkinstructie: werfbon correct invullen", "werkinstructie", """
Vul per dag en per werf één werfbon in. Noteer begin- en einduur, pauze, gereden kilometers en alle gebruikte materialen
met artikelcode indien gekend. Schrijf duidelijk: de administratie typt elke bon over.
Laat de klant tekenen. Zonder handtekening kan de bon niet gefactureerd worden.
Bezorg de bonnen ten laatste op vrijdag aan de administratie.
"""),
]
doc_rows = [(i, t, ty, c.strip(), date(2026, random.randint(1, 10), random.randint(1, 28)))
            for i, (t, ty, c) in enumerate(DOCS, start=1)]
insert("documenten", ["id", "titel", "type", "inhoud", "bijgewerkt_op"], doc_rows)

# ─────────────────────────────────────────────
# Sequences na expliciete id's
# ─────────────────────────────────────────────

for t in ["medewerkers", "vaardigheden", "klanten", "artikelen", "aanvragen", "offertes", "offerte_lijnen",
          "werven", "onderhoudscontracten", "interventies", "werfbonnen", "werfbon_lijnen", "facturen",
          "factuur_lijnen", "documenten"]:
    out.append(f"select setval(pg_get_serial_sequence('{t}', 'id'), coalesce((select max(id) from {t}), 1));\n")

print("-- Gegenereerd door scripts/generate_seed.py — fictieve data, peildatum " + VANDAAG.isoformat())
print("begin;")
print("\n".join(out))
print("commit;")
