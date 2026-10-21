# NIRAS DSGN Projektstatus

Dashboard til månedsluk: projektstatus pr. måned og til dato, flag, risk log, kort og rapporter til projektansvarlige. Én HTML-fil, der kører i browseren.

## Indhold

| Fil | Formål |
|---|---|
| `NIRAS_Projektstatus.html` | Dashboardet. Åbn filen i Chrome eller Edge. |
| `supabase/schema.sql` | Databasen i Supabase: tabeller, visninger, triggere og adgang. Kan køres igen uden at skade data. |
| `docs/database.md` | Overblik over databasen og relationerne. |

## Data og fortrolighed

- Repositoryet indeholder **ingen projektdata**. ERP-udtræk, risk log, eksporter og rapporter er udelukket i `.gitignore`.
- Excel-filerne læses kun i browseren. Uden Supabase gemmes udtræk, noter og fokus i browseren på din egen computer.
- Med Supabase gemmes udtræk og egne registreringer i databasen (EU-region). Kun brugere, der er logget ind, har adgang.

## Brug hver måned

1. Træk de tre udtræk ind i dashboardet: `data_26_PTD_ÅÅÅÅMMDD.xlsx`, `data_26_Monthly_ÅÅÅÅMM.xlsx` og `data_26_risklog_ÅÅÅÅMMDD.xlsx`.
2. Dashboardet afstemmer mod udtrækkenes Total-linje og gemmer dem med dato.
3. Gennemgå flag, skriv noter og opfølgninger, og lav rapporter til hver PA under fanen Rapport.
4. Eksportér dine egne data når som helst under "Mine data" (Excel eller JSON).

## Opsætning af Supabase

1. Kør `supabase/schema.sql` i SQL Editor.
2. Opret brugere under Authentication > Users.
3. I dashboardet: Indstillinger > Supabase. Indtast projekt-URL, publishable key og login.
4. Har du noter eller udtræk i browseren, så flyt dem med knapperne under Indstillinger.

## Kort

Kortbaggrunden kommer fra CARTO og kræver en gratis nøgle (Indstillinger > Kort).
