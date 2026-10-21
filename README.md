# NIRAS DSGN Projektstatus

Dashboard til månedsluk: projektstatus pr. måned og til dato, flag, risk log, kort og rapporter til projektansvarlige. Én HTML-fil, der kører i browseren.

**Åbnes fra GitHub Pages:** https://nielselliotbrochner.github.io/NIRAS_DSGN_Projektstatus/

Siden indeholder ingen data. Alle tal og noter hentes fra Supabase efter login, og kun e-mails i tabellen `adgang` har adgang.

## Indhold

| Fil | Formål |
|---|---|
| `index.html` | Dashboardet. Køres fra GitHub Pages (se nedenfor) eller som lokal fil i Chrome eller Edge. |
| `supabase/schema.sql` | Databasen i Supabase: tabeller, visninger, triggere og adgang. Kan køres igen uden at skade data. |
| `docs/database.md` | Overblik over databasen og relationerne. |

## Data og fortrolighed

- Repositoryet indeholder **ingen projektdata**. ERP-udtræk, risk log, eksporter og rapporter er udelukket i `.gitignore`.
- Excel-filerne læses kun i browseren. Uden Supabase gemmes udtræk, noter og fokus i browseren på din egen computer.
- Med Supabase gemmes udtræk og egne registreringer i databasen (EU-region). Kun godkendte brugere (tabellen `adgang`) har adgang.

## Brug hver måned

1. Træk de tre udtræk ind i dashboardet: `data_26_PTD_ÅÅÅÅMMDD.xlsx`, `data_26_Monthly_ÅÅÅÅMM.xlsx` og `data_26_risklog_ÅÅÅÅMMDD.xlsx`.
2. Dashboardet afstemmer mod udtrækkenes Total-linje og gemmer dem med dato.
3. Gennemgå flag, skriv noter og opfølgninger, og lav rapporter til hver PA under fanen Rapport.
4. Eksportér dine egne data når som helst under "Mine data" (Excel eller JSON).

## Supabase

Projektet **NIRAS Projektstatus** (region eu-north-1, Stockholm) er oprettet, og skemaet er kørt.
URL og publishable key er udfyldt i dashboardet, så der kun skal logges ind.

- `supabase/schema.sql`: hele skemaet. Kan køres igen i SQL Editor uden at skade data.
- `supabase/05_projekt_tildel_nummer.sql`: funktionen, der giver et tilbud sit ERP-nummer. Køres manuelt i SQL Editor, før bid/no bid tages i brug.

Ny bruger: opret brugeren under Authentication > Users > Add user (e-mail og adgangskode), og tilføj e-mailen i tabellen `adgang`:
`insert into public.adgang (email) values ('navn@niras.dk');`
Kun e-mails i `adgang` kan læse og skrive data, også selv om andre skulle oprette en bruger.
Har du noter eller udtræk i browseren, så flyt dem med knapperne under Indstillinger.

## Kort

Fra GitHub Pages bruges OpenStreetMap uden nøgle. Som lokal fil kræver kortbaggrunden en gratis CARTO-nøgle (Indstillinger > Kort).
