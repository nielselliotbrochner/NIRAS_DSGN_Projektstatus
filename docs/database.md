# Database: NIRAS Projektstatus (Supabase)

Oprettes med `supabase/schema.sql` (kan køres igen uden at skade data).

## Princip

Stamtabellen `projekt` giver hvert projekt ét fast id (`id`, uuid) fra tilbud til aflevering. Projektnummer, salgsnummer og titler er felter, der kan ændre sig. Alle moduler kobles på `projekt_id` med fremmednøgle. ERP-udtrækkene kobles via projektnummer.

```
                    erp_upload (log over uploads)
                         │ registrerer
        ┌────────────────┼────────────────┐
     erp_ptd         erp_maaned       erp_risiko        ← øjebliksbilleder med dato
        └────────────────┼────────────────┘
                         │ projektnummer
                      projekt  (id = fast nøgle, projektnummer, salgsnummer, arbejdstitel, titel, status)
                         │ projekt_id
   ┌──────────┬──────────┼──────────┬───────────┬────────────┬────────────┬────────────┐
 fokus      noter      info        bid      aendring    kvalitet     milepael    dokument
 (0-1)    (0-mange)   (0-1)    (0-mange)   (0-mange)   (0-mange)   (0-mange)   (0-mange)
```

## Stamtabel: `projekt`

| Felt | Betydning |
|---|---|
| `id` | Fast id, aldrig ændret |
| `projektnummer` | ERP-nummer, unikt, tomt i tilbudsfasen |
| `salgsnummer` | Midlertidigt nummer eller salgsnummer, unikt |
| `arbejdstitel` | Titel i tilbudsfasen, bevares efter vundet opgave |
| `titel` | Officiel titel fra seneste PTD |
| `status` | tilbud, no bid, tabt, aktiv, lukket |
| `bu`, `pl`, `po`, `kunde` | Organisation og kunde (opdateres fra ERP og risk log) |
| `sidst_i_erp` | Seneste PTD-dato med projektet |
| `ekstra` | jsonb til nye felter uden skemaændring |

Mindst ét af projektnummer, salgsnummer eller arbejdstitel skal være udfyldt.

## ERP-udtræk (historik med dato)

| Tabel | Nøgle | Indhold |
|---|---|---|
| `erp_upload` | unik (type, noegle) | Log over uploads; dashboardet bruger kun udtræk, der står her |
| `erp_ptd` | (pr_dato, projekt) | Til dato-øjebliksbillede |
| `erp_maaned` | (periode, projekt) | Månedens bevægelser |
| `erp_risiko` | (pr_dato, projekt) | Risk log |

Triggere: nye projektnumre i et udtræk opretter selv et projekt. PTD opdaterer titel, BU, PL og PA (kun fra nyere udtræk end det seneste). Risk log udfylder kunde.

## Moduler (alle med `projekt_id` → `projekt.id`)

| Tabel | Pr. projekt | Indhold |
|---|---|---|
| `projekt_fokus` | 0-1 | Fokusmarkering |
| `projekt_noter` | 0-mange | Noter og opfølgning pr. månedsluk |
| `projekt_info` | 0-1 | Beskrivelse, Google Maps-link, lat/lng |
| `projekt_bid` | 0-mange | Bid/no bid: beslutning, vinderchance, honorarestimat, scorecard (jsonb), resultat |
| `projekt_aendring` | 0-mange | Ændringslog (udgave 1): nr, titel, beløb, timer, status |
| `projekt_kvalitet` | 0-mange | Kvalitetsplan (udgave 1): emne, krav, ansvarlig, frist, status |
| `projekt_milepael` | 0-mange | Projektplan (udgave 1): planlagt, prognose, faktisk dato |
| `projekt_dokument` | 0-mange | Links til dokumenter, fx i SharePoint |

Hvert modul har også kolonnen `projekt` med en kopi af projektnummeret, som databasen selv udfylder og retter. Dashboardet kan derfor skrive med projektnummer, og tilbud uden nummer skriver med `projekt_id`.

## Fra tilbud til projekt

1. Tilbuddet oprettes i `projekt` med salgsnummer og arbejdstitel (status tilbud). Bid/no bid, noter m.m. kobles på dets id.
2. Når opgaven er vundet: `select projekt_tildel_nummer('<id>', '<ERP-nummer>');`
   - Kender ERP ikke nummeret endnu: nummeret sættes på tilbuddet.
   - Har ERP-udtrækket allerede oprettet projektet: tilbuddets data flyttes over, salgsnummer og arbejdstitel bevares, og det midlertidige projekt slettes.

## Visninger

- `v_projekt`: projekter med visningsnavn (titel eller arbejdstitel) og beregnet status (aktivt projekt, der ikke er i seneste PTD = lukket).
- `v_maaned_trend`, `v_risiko_trend`: udvikling samlet i databasen.
- `v_eksport_<modul>` (noter, fokus, info, bid, aendring, kvalitet, milepael, dokument): hvert modul med projektnummer, salgsnummer, projektnavn, BU, PL og PA.

## Eksport af egne data

- **Dashboardet, "Mine data"**: Excel med ét ark pr. type eller fuld JSON-backup. Kan begrænses til det nuværende udvalg (BU, PL, PA).
- **Direkte i Supabase**: åbn en `v_eksport_*`-visning i Table Editor og eksportér som CSV.
- JSON-backuppen kan indlæses igen i dashboardet (noter, fokus og projektinfo).

## Nyt modul senere

Opret tabellen med `id`, `projekt_id` (fremmednøgle, on delete cascade) og `projekt`, og tilføj navnet i listerne i afsnit 4 (eksport), 5, 6 og 7 i `supabase/schema.sql`. I dashboardet tilføjes et ark i `EX_SHEETS` og navnet i `EX_MODULES`.

## Adgang

Row Level Security på alle tabeller: kun brugere, der er logget ind.
