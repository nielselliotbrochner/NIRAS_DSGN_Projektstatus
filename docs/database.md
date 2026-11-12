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
| `erp_ptd` | (pr_dato, projekt) | PTD-øjebliksbillede |
| `erp_maaned` | (periode, projekt) | Månedens bevægelser |
| `erp_risiko` | (pr_dato, projekt) | Risk log |

Triggere: nye projektnumre i et udtræk opretter selv et projekt. PTD opdaterer titel, BU, PL, PA og kunde (kun fra nyere udtræk end det seneste). Risk log udfylder kunde.

### Detailed Main Project View (12. nov. 2026, `12_erp_detailed.sql`)

Fra november 2026 hentes PTD og valgt måned som "Detailed Main Project View". Begge tabeller har fået samme nye kolonner (tomme i ældre udtræk). `erp_maaned` har desuden fået `poc` (status ved månedens udgang).

| Kolonne | ERP-navn | Bemærkning |
|---|---|---|
| `kunde`, `kontrakttype`, `ps` | Customer, Customer Contract Type, PS | Kontrakttype vises med ERP's navne: Fixed Price, Time & Material |
| `risikoklasse` | Risk Class | Maconomy-klassen 1-4 ("Level 3 – High risk" → 3) |
| `startdato`, `oprettet_dato`, `forv_slut`, `faerdig_dato`, `lukket_dato` | Started, Creation, Expected Ending, Work Completed, Actual Closing Date | |
| `timer`, `timer_etc`, `timer_eac` | Hours QTY (ACT/ETC/EAC) | `timer_eac` kun i PTD |
| `underlev`, `overhead`, `projektresultat`, `overforbrug` | Subcontractor Cost (ACT), Overhead, Project Profit (ACT), Over-spending | |
| `rest_oms`, `backlog_brutto`, `backlog_netto`, `kostpris`, `salgspris`, `fakt_fm` | Remaning Revenue Recognized, Backlog Gross/Net, Cost/Sales Rate, Invoiced FM | kun i PTD |
| `loen_etc`, `loen_eac`, `ext_etc`, `ext_eac`, `underlev_etc`, `underlev_eac` | ETC- og EAC-omkostninger | |
| `tfm_etc`, `delta_tfm_eac` | Factor TFM (ETC), Delta Factor EAC | |
| `contingency` | Contingency | |
| `effekt_aendring` | Effect of Change | kun i måned |
| `mangler_kontrakt`, `mangler_risikoklasse`, `mangler_tjekliste`, `mangler_qa`, `mangler_survey` | Missing Contract/Risk Class/Checklist/QA/Survey | 1 i udtrækket = sand. Betydningen skal bekræftes |

Omdøbte kolonner læses ind i de eksisterende felter: Fee to be Invoiced → `til_fakt`, External Cost (ACT) → `ext`, Total Labour Costs Time (ACT) → `loen`, Gross Margin (ACT) → `db`, Factor TFM (EAC) → `tfm_eac`.

**Genkendelse af PTD og måned.** Tre uafhængige tjek skal give samme svar, ellers gemmes intet:
1. Filterlinjen ("Anvendte filtre"): månedsudtræk har "Medtaget … (Month Name, Year)". PTD har det aldrig.
2. Kolonner: måned har "Effect of Change" (nyt format) eller ingen POC (gammelt format). PTD har POC uden "Effect of Change".
3. Tal: omsætning i alt ÷ baseline i alt er ca. 0,9 i PTD og ca. 0,02 i en måned. Grænsen er 0,3.

Før noget gemmes, viser dashboardet, hvad filen er genkendt som, og hvad hvert tjek fandt.

**Risikoklasse.** Ledelsens beslutning fra risk log går forud. Uden risk log (eller for projekter uden for den) bruges `risikoklasse` fra PTD. Risk log er herefter valgfri; den giver ledelsens klasse, risikofaktorer, vurdering, honorar, tabsrisiko og AR +90 dage.

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
| `projekt_pipeline` | 0-1 | Pipeline: type (opgave, rammeaftale, miniudbud), fase (lead, PQ, tilbud, vundet, tabt, no bid, annulleret), tabt i fase, kilde, teamets honorar, NIRAS-andel, anlægssum, størrelse som oplyst, rolle (TR/UR), partnere, ansvarlige, udbud (delaftaler), vinderchance, PQ- og tilbudsfrist med afleveret-dato, prækvalificeret, forventet opstart. Rammeaftale: samlet værdi, antal vindere, andel, aftaleperiode. Miniudbud: `ramme_id` → rammeaftalens pipeline-række |

Hvert modul har også kolonnen `projekt` med en kopi af projektnummeret, som databasen selv udfylder og retter. Dashboardet kan derfor skrive med projektnummer, og tilbud uden nummer skriver med `projekt_id`.

## Pipeline og rammeaftaler

- Et lead er en række i `projekt` (salgsnummer eller midlertidigt nummer og arbejdstitel) med én række i `projekt_pipeline`. Fanen Pipeline i dashboardet opretter begge.
- **NIRAS-værdi** = teamets honorar × NIRAS-andel (tom = 100 %). Rammeaftale: aftalens værdi × teamets andel (tom = 1 ÷ antal vindere) × NIRAS-andel.
- **Vægtet pipeline** = NIRAS-værdi × vinderchance for åbne punkter (lead, PQ, tilbud).
- **Afleveret:** en PQ eller et tilbud med afleveret-dato står som "afventer svar" i stedet for overskredet frist og får ingen påmindelse. Over 60 dage markeres kortet.
- **Udfald:** vundet, tabt, no bid og annulleret. `tabt_i` husker, om det skete i PQ eller tilbud. Hitraten tæller vundet og tabt de seneste 12 måneder.
- **Delaftaler:** hver delaftale er sin egen rammeaftale med samme `udbud`.
- **Liste og PowerPoint:** fanen Pipeline > Liste viser "Tilbud og PQ'er pr. dato" og kan hentes som .pptx.
- **Datoer:** spørgefrist, PQ-frist, PQ afleveret, prækvalificeret, tilbudsfrist, tilbud afleveret, revideret tilbud (2. bud), forventet afgørelse, bid/no bid-dato (i `projekt_bid`), resultat, forventet opstart og aftaleperiode. Kortet viser næste handling; efter aflevering styrer forventet afgørelse markeringen (ellers 60 dage). Tabel har valgbare datokolonner. Påmindelse dagen før for spørgefrist, PQ, tilbud, revideret tilbud og bid/no bid-beslutning. SQL: `supabase/10_pipeline_datoer.sql`.
- **Rammeaftale før vundet:** værdien er vores forventede andel = samlet værdi × andel. Står andelen tom, bruges 1 ÷ antal vindere. Vinderchancen er chancen for at komme på aftalen.
- **Rammeaftale vundet:** tæller ikke i pipelinen. Resten (andel minus vundne miniudbud) står som **rammepotentiale**, så længe aftalen ikke er udløbet.
- **Miniudbud:** tæller som en almindelig opgave (honorar × chance) og trækkes fra rammens rest, når det er vundet.
- `pipeline_vundet(projekt_id, ERP-nummer)` sætter fasen til vundet og giver evt. ERP-nummer. Findes nummeret allerede fra ERP-udtrækket, flyttes leadets noter, bid og pipeline over, og leadet lukkes.
- `pipe_paamindelser(dato)` giver PQ- og tilbudsfrister til påmindelsesmailen kl. 07 dagen før.
- SQL: `supabase/07_pipeline.sql` og `supabase/09_pipeline_felter.sql`.

## Personnoter (10. nov. 2026)

- `person_noter`: initialer (som PL/PA i ERP), dato, note, opfølgning, frist, status, koblede projekter (`projektnumre`), oprettet, redigeret. Kolonnen `projekter` (uuid[]) er ubrugt.
- `note_filer`: filer til en personnote (filnavn, type, størrelse, sti). Filerne ligger i den private bucket `person-filer` (højst 25 MB pr. fil; pdf, billeder, Office, msg, eml, txt, csv) og åbnes med et link, der virker i 5 minutter.
- Fanen Personer viser panelet, når en eller flere personer er valgt i PL eller PA øverst: nøgletal, ny personnote med filer, og en tidslinje med personnoter og projektnoter fra projekter, hvor personen er PL eller PA i det valgte PTD-udtræk.
- Opfølgninger fra personnoter står også i fanen Opfølgning og får påmindelse kl. 07 dagen før (`person_paamindelser`).
- Eksport: `v_eksport_personnoter` og arket Personnoter i "Mine data". SQL: `supabase/11_person_noter.sql`.

## Kunder (12. nov. 2026, `13_kunder.sql`)

Én kundetabel med to slags kunder, så leads, PQ og tilbud kan få en kunde fra ERP, også før opgaven findes i ERP.

| Felt | Betydning |
|---|---|
| `navn` | Kundens navn (unikt pr. type uden hensyn til store og små bogstaver) |
| `type` | `erp` (lagt ind automatisk fra PTD og risk log) eller `midlertidig` (oprettet i tilbudsfasen) |
| `erp_id` | Kun midlertidige: den ERP-kunde, kunden er koblet til |
| `koblet`, `koblet_af` | Hvornår og af hvem koblingen er lavet ("ERP (samme navn)", når den sker automatisk) |
| `projekt.kunde_id` | Kunden på et lead, PQ eller tilbud |

- **Synk fra ERP:** triggerne `erp_ptd_kunde` og `erp_risiko_kunde` lægger nye kundenavne ind som ERP-kunder. Får en midlertidig kunde præcis samme navn i ERP, kobles den automatisk.
- **Kundenavnet på projektet** (`projekt.kunde`) følger `kunde_id`: ERP-navnet, når en midlertidig kunde er koblet. Projekter, der er kommet i ERP, beholder ERP's kundenavn.
- **`kunde_kobl(midlertidig, erp)`** kobler (eller fjerner koblingen med null). Tilbuddene beholder den midlertidige kunde som historik ("tilbudt som") og vises og tælles med ERP-navnet.
- **I dashboardet:** kundefeltet i pipeline-formularen foreslår kunder mærket ERP eller Midlertidig. Et nyt navn oprettes som midlertidig kunde efter bekræftelse. Fanen Kunder viser kunder fra PTD og pipeline, kundens leads, PQ og tilbud med hitrate, og en liste over midlertidige kunder med forslag til kobling: kunden på en vundet opgave, der er kommet i ERP, og ERP-navne, der begynder med eller indeholder det midlertidige navn.
- **Eksport:** `v_eksport_kunder` (midlertidige kunder og kunder i brug, med ERP-navn og antal pipeline-punkter) og arket Kunder i "Mine data".
- **Første fyldning:** 814 ERP-kunder. De 30 kundenavne i pipelinen: 13 koblet til ERP-kunder med samme navn, 17 oprettet som midlertidige kunder.

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

Row Level Security på alle tabeller. Det er ikke nok at være logget ind: brugerens e-mail skal stå i tabellen `adgang` (tjekkes af funktionen `har_adgang()`).
