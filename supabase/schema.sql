-- NIRAS Projektstatus: database til projekter fra tilbud til aflevering
-- Kør i Supabase: SQL Editor > New query > indsæt hele filen > Run.
-- Vælg et EU-datacenter, når projektet oprettes, og opret brugere under Authentication > Users.
-- Kan køres igen uden at skade eksisterende data.
--
-- Opbygning
--   1. projekt            Stamtabel. Ét fast id pr. projekt fra tilbud til aflevering.
--                         ERP-nummer, salgsnummer og titler er felter, der kan ændre sig.
--   2. ERP-udtræk         erp_upload, erp_ptd, erp_maaned, erp_risiko: øjebliksbilleder med dato.
--                         Kobles til projekt via projektnummer. Nye numre opretter selv et projekt.
--   3. Moduler            projekt_fokus, projekt_noter, projekt_info, projekt_bid, projekt_aendring,
--                         projekt_kvalitet, projekt_milepael, projekt_dokument.
--                         Alle har projekt_id (fremmednøgle til projekt.id) og en automatisk
--                         vedligeholdt kopi af projektnummeret i kolonnen projekt.
--   4. Funktioner         projekt_tildel_nummer: giver et tilbud sit ERP-nummer og samler data.
--   Eksport              v_eksport_<modul>: alle egne data med projektnavn, klar til CSV eller dashboardets "Mine data".
--
-- Nyt modul senere: opret tabellen med id, projekt_id, projekt (se fx projekt_aendring),
-- og tilføj navnet i listerne i afsnit 4 (eksport), 5, 6 og 7. Så får det eksport, triggere, adgang og samling gratis.
--
-- Pladsforbrug målt med rigtige udtræk (alle fem BU): ca. 0,7 MB pr. måned for PTD + måned
-- og ca. 0,6 MB pr. risk log-udtræk inkl. indeks. Gratisplanen har 500 MB, Pro 8 GB.

------------------------------------------------------------------------
-- 1. Stamtabel
------------------------------------------------------------------------

create table if not exists public.projekt (
  id             uuid primary key default gen_random_uuid(),
  projektnummer  text unique,                 -- ERP-nummer; tomt i tilbudsfasen
  salgsnummer    text unique,                 -- midlertidigt nummer eller salgsnummer i tilbudsfasen
  arbejdstitel   text,                        -- titel i tilbudsfasen; bevares når projektet får ERP-titel
  titel          text,                        -- officiel titel fra ERP (opdateres ved hvert PTD-udtræk)
  status         text not null default 'tilbud'
                 check (status in ('tilbud', 'no bid', 'tabt', 'aktiv', 'lukket')),
  bu             text,
  pl             text,                        -- projektleder (PM)
  po             text,                        -- projektansvarlig (PO)
  kunde          text,
  sidst_i_erp    date,                        -- seneste PTD-dato, hvor projektet var med
  ekstra         jsonb not null default '{}'::jsonb,   -- fleksible felter uden skemaændring
  oprettet       timestamptz not null default now(),
  opdateret      timestamptz not null default now(),
  oprettet_af    uuid default auth.uid(),
  constraint projekt_identifikation check (projektnummer is not null or salgsnummer is not null or arbejdstitel is not null)
);

------------------------------------------------------------------------
-- 2. ERP-udtræk (historik med dato)
------------------------------------------------------------------------

-- Log over uploads. Dashboardet bruger kun udtræk, der står her,
-- så et afbrudt upload aldrig vises som komplet.
create table if not exists public.erp_upload (
  id           uuid primary key default gen_random_uuid(),
  type         text not null,                 -- 'ptd', 'maaned' eller 'risiko'
  noegle       text not null,                 -- 'ÅÅÅÅ-MM-DD' for PTD og risk log, 'ÅÅÅÅ-MM' for måned
  filnavn      text,
  raekker      integer,
  afstemt      boolean,                       -- summer stemmer med udtrækkets Total-linje
  afvigelser   text,
  uploadet     timestamptz not null default now(),
  uploadet_af  uuid default auth.uid(),
  unique (type, noegle)
);
alter table public.erp_upload add column if not exists udtrukket timestamptz;  -- hentet fra ERP (tidsstempel i xlsx-filen)
alter table public.erp_upload add column if not exists noegle_kilde text;      -- filter, stempel, etc, filnavn eller filedato
alter table public.erp_upload drop constraint if exists erp_upload_type_check;
alter table public.erp_upload add constraint erp_upload_type_check check (type in ('ptd', 'maaned', 'risiko'));

-- Til dato (PTD): ét øjebliksbillede pr. udtræksdato
create table if not exists public.erp_ptd (
  pr_dato        date not null,
  projekt        text not null,               -- projektnummer
  navn           text,
  bu             text,
  pl             text,
  po             text,
  valuta         text,
  baseline       numeric(16,2),
  wip            numeric(16,2),
  faktureret     numeric(16,2),
  over_baseline  numeric(16,2),
  til_fakt       numeric(16,2),
  forfalden      numeric(16,2),
  oms            numeric(16,2),               -- Revenue Recognized
  ext            numeric(16,2),               -- External Cost
  loen           numeric(16,2),               -- Total Labour Cost (Time)
  db             numeric(16,2),               -- Gross Margin
  tfm            numeric(14,6),
  tfm_eac        numeric(14,6),
  poc            numeric(14,6),
  etc_dato       date,
  primary key (pr_dato, projekt)
);
create index if not exists erp_ptd_projekt_idx on public.erp_ptd (projekt, pr_dato);

-- Måned: bevægelser i måneden. Kun projekter med bevægelse gemmes.
create table if not exists public.erp_maaned (
  periode        date not null check (extract(day from periode) = 1),   -- første dag i måneden
  projekt        text not null,
  navn           text,
  bu             text,
  pl             text,
  po             text,
  valuta         text,
  baseline       numeric(16,2),
  wip            numeric(16,2),
  faktureret     numeric(16,2),
  over_baseline  numeric(16,2),
  til_fakt       numeric(16,2),
  forfalden      numeric(16,2),
  oms            numeric(16,2),
  ext            numeric(16,2),
  loen           numeric(16,2),
  db             numeric(16,2),
  tfm            numeric(14,6),
  tfm_eac        numeric(14,6),
  etc_dato       date,
  primary key (periode, projekt)
);
create index if not exists erp_maaned_projekt_idx on public.erp_maaned (projekt, periode);

-- Risk log: ét øjebliksbillede pr. udtræksdato. Risikofaktorer 1 (lav) til 4 (høj).
create table if not exists public.erp_risiko (
  pr_dato                   date not null,
  projekt                   text not null,
  navn                      text,
  selskab                   text,
  bu                        text,
  pl                        text,
  po                        text,
  valuta                    text,
  land                      text,         -- Beneficiary Country
  kunde                     text,         -- Customer Name
  mac_klasse                smallint,     -- Mac Risk
  klasse                    smallint,     -- Management decision
  r_konkurrence             smallint,     -- Competition
  r_lokation                smallint,     -- Project locations
  r_kunde                   smallint,     -- Customer
  r_slutbruger              smallint,     -- End user
  r_eksterne_interessenter  smallint,     -- External stakeholders
  r_eksterne_partnere       smallint,     -- External partners
  r_intern_org              smallint,     -- Internal organisation
  r_viden_kvalitet          smallint,     -- Knowledge - Quality
  r_teknisk                 smallint,     -- Technical complexity
  r_kontrakt                smallint,     -- Contract risks
  r_tidsplan                smallint,     -- Time schedule
  honorar                   text,         -- Fee (size), fx 'DKK = 0.5-10M'
  tabsrisiko                text,         -- Risk of loss, fx 'DKK < 0.1M'
  wip_tkr                   numeric(14,3),
  ar90_tkr                  numeric(14,3),
  reserve                   text,         -- Contingency Proj. Curr.
  kommentar                 text,         -- General comments
  link_pmdash               text,
  link_risklog              text,
  primary key (pr_dato, projekt)
);
create index if not exists erp_risiko_projekt_idx on public.erp_risiko (projekt, pr_dato);

------------------------------------------------------------------------
-- 3. Moduler pr. projekt
--    Fælles mønster: projekt_id er den rigtige kobling. Kolonnen projekt er en kopi af
--    projektnummeret, som databasen selv udfylder og retter. Indsætter man kun projekt
--    (projektnummer), finder eller opretter databasen selv projektet og sætter projekt_id.
------------------------------------------------------------------------

-- Fokus: højst én pr. projekt
create table if not exists public.projekt_fokus (
  id           uuid primary key default gen_random_uuid(),
  projekt_id   uuid not null unique references public.projekt (id) on delete cascade,
  projekt      text unique,
  fokus        boolean not null default false,
  opdateret    timestamptz not null default now(),
  opdateret_af uuid default auth.uid()
);

-- Noter og opfølgning: log pr. månedsluk
create table if not exists public.projekt_noter (
  id           uuid primary key default gen_random_uuid(),
  projekt_id   uuid not null references public.projekt (id) on delete cascade,
  projekt      text,
  periode      text,                          -- månedsluk, fx '2026-09'
  note         text,
  opfoelgning  text,
  frist        date,
  status       text not null default 'åben' check (status in ('åben', 'lukket')),
  oprettet     timestamptz not null default now(),
  oprettet_af  uuid default auth.uid()
);
create index if not exists projekt_noter_projekt_id_idx on public.projekt_noter (projekt_id);
create index if not exists projekt_noter_projekt_idx on public.projekt_noter (projekt);

-- Beskrivelse og lokation: højst én pr. projekt. lat/lng bruges af kortet.
create table if not exists public.projekt_info (
  id           uuid primary key default gen_random_uuid(),
  projekt_id   uuid not null unique references public.projekt (id) on delete cascade,
  projekt      text unique,
  beskrivelse  text,
  lokation_url text,
  adresse      text,
  lat          double precision,
  lng          double precision,
  opdateret    timestamptz not null default now(),
  opdateret_af uuid default auth.uid()
);

-- Bid/no bid: kan have flere vurderinger over tid pr. projekt
create table if not exists public.projekt_bid (
  id               uuid primary key default gen_random_uuid(),
  projekt_id       uuid not null references public.projekt (id) on delete cascade,
  projekt          text,
  beslutning       text not null default 'afventer' check (beslutning in ('afventer', 'bid', 'no bid')),
  beslutningsdato  date,
  besluttet_af     text,
  tilbudsfrist     date,
  honorar_estimat  numeric(14,0),             -- forventet honorar i kr.
  vinderchance     numeric(4,3) check (vinderchance between 0 and 1),
  score            numeric(6,2),              -- samlet score fra kriterierne
  kriterier        jsonb not null default '{}'::jsonb,   -- scorecard, fx {"strategisk_vaerdi": 4, "kunde": 3}
  begrundelse      text,
  resultat         text not null default 'afventer' check (resultat in ('afventer', 'vundet', 'tabt', 'trukket')),
  oprettet         timestamptz not null default now(),
  oprettet_af      uuid default auth.uid()
);
create index if not exists projekt_bid_projekt_id_idx on public.projekt_bid (projekt_id);

-- Ændringslog (udgave 1): ekstraarbejde og ændringer i omfang, tid eller honorar
create table if not exists public.projekt_aendring (
  id           uuid primary key default gen_random_uuid(),
  projekt_id   uuid not null references public.projekt (id) on delete cascade,
  projekt      text,
  nr           integer,                       -- løbenummer i projektet
  titel        text not null,
  beskrivelse  text,
  aarsag       text,                          -- fx kunde, myndighed, intern, uforudset
  beloeb       numeric(14,2),
  timer        numeric(10,1),
  status       text not null default 'registreret' check (status in ('registreret', 'sendt', 'godkendt', 'afvist', 'annulleret')),
  registreret  date not null default current_date,
  besluttet    date,
  oprettet     timestamptz not null default now(),
  oprettet_af  uuid default auth.uid(),
  unique (projekt_id, nr)
);
create index if not exists projekt_aendring_projekt_id_idx on public.projekt_aendring (projekt_id);

-- Kvalitetsplan (udgave 1): punkter med ansvar og status
create table if not exists public.projekt_kvalitet (
  id           uuid primary key default gen_random_uuid(),
  projekt_id   uuid not null references public.projekt (id) on delete cascade,
  projekt      text,
  emne         text not null,                 -- fx projektgennemgang, kontrol, tegningsrevision
  krav         text,
  ansvarlig    text,
  frist        date,
  status       text not null default 'åben' check (status in ('åben', 'udført', 'ikke relevant')),
  dokument_url text,
  oprettet     timestamptz not null default now(),
  oprettet_af  uuid default auth.uid()
);
create index if not exists projekt_kvalitet_projekt_id_idx on public.projekt_kvalitet (projekt_id);

-- Projektplan (udgave 1): milepæle med plan, prognose og faktisk dato
create table if not exists public.projekt_milepael (
  id           uuid primary key default gen_random_uuid(),
  projekt_id   uuid not null references public.projekt (id) on delete cascade,
  projekt      text,
  navn         text not null,
  planlagt     date,
  prognose     date,
  faktisk      date,
  status       text not null default 'planlagt' check (status in ('planlagt', 'i gang', 'nået', 'forsinket', 'udgået')),
  oprettet     timestamptz not null default now(),
  oprettet_af  uuid default auth.uid()
);
create index if not exists projekt_milepael_projekt_id_idx on public.projekt_milepael (projekt_id);

-- Dokumenter: links til fx kontrakt, tilbud og kvalitetsplan i SharePoint
create table if not exists public.projekt_dokument (
  id           uuid primary key default gen_random_uuid(),
  projekt_id   uuid not null references public.projekt (id) on delete cascade,
  projekt      text,
  type         text,                          -- fx kontrakt, tilbud, kvalitetsplan, referat
  titel        text not null,
  url          text not null,
  oprettet     timestamptz not null default now(),
  oprettet_af  uuid default auth.uid()
);
create index if not exists projekt_dokument_projekt_id_idx on public.projekt_dokument (projekt_id);

------------------------------------------------------------------------
-- 4. Visninger
------------------------------------------------------------------------

-- Projekter med beregnet status: aktive projekter, der ikke er med i seneste PTD, regnes som lukket
create or replace view public.v_projekt with (security_invoker = true) as
select p.*,
       coalesce(p.titel, p.arbejdstitel) as navn,
       case when p.status = 'aktiv' and p.sidst_i_erp < (select max(pr_dato) from public.erp_ptd) then 'lukket'
            else p.status end as status_nu
from public.projekt p;

-- Udvikling pr. måned, samlet i databasen
create or replace view public.v_maaned_trend with (security_invoker = true) as
select periode, bu, coalesce(pl, '?') as pl, coalesce(po, '?') as po,
       sum(oms) as oms, sum(db) as db, sum(loen) as loen,
       count(*) filter (where loen > 0) as aktive
from public.erp_maaned
group by 1, 2, 3, 4;

-- Udvikling i risikoklasser pr. udtræk
create or replace view public.v_risiko_trend with (security_invoker = true) as
select pr_dato, bu, coalesce(pl, '?') as pl, coalesce(po, '?') as po, klasse,
       count(*) as n,
       count(*) filter (where num_nonnulls(r_konkurrence, r_lokation, r_kunde, r_slutbruger, r_eksterne_interessenter,
                                           r_eksterne_partnere, r_intern_org, r_viden_kvalitet, r_teknisk, r_kontrakt, r_tidsplan) > 0) as vurderet
from public.erp_risiko
group by 1, 2, 3, 4, 5;

-- Eksport af egne data: hvert modul med projektnummer, salgsnummer, navn, BU, PL og PA.
-- Hentes af dashboardets "Mine data" og kan også eksporteres som CSV direkte i Supabase (Table Editor).
do $$
declare t text;
begin
  foreach t in array array['noter', 'fokus', 'info', 'bid', 'aendring', 'kvalitet', 'milepael', 'dokument'] loop
    execute format('create or replace view public.v_eksport_%s with (security_invoker = true) as
      select p.projektnummer, p.salgsnummer, coalesce(p.titel, p.arbejdstitel) as projektnavn, p.bu, p.pl, p.po, m.*
      from public.projekt_%s m join public.projekt p on p.id = m.projekt_id', t, t);
    execute format('grant select on public.v_eksport_%s to authenticated', t);
  end loop;
end $$;

------------------------------------------------------------------------
-- 5. Triggere
------------------------------------------------------------------------

-- Moduler: find eller opret projekt ud fra projektnummer, og hold kopien af nummeret ajour
create or replace function public.projekt_ref() returns trigger language plpgsql set search_path = public as $$
begin
  if new.projekt_id is null then
    if new.projekt is null or new.projekt = '' then
      raise exception 'Angiv projekt_id eller projekt (projektnummer)';
    end if;
    insert into public.projekt (projektnummer, status) values (new.projekt, 'aktiv')
      on conflict (projektnummer) do nothing;
    select id into new.projekt_id from public.projekt where projektnummer = new.projekt;
  else
    select projektnummer into new.projekt from public.projekt where id = new.projekt_id;
  end if;
  return new;
end $$;

-- Opdateret-tidsstempel
create or replace function public.saet_opdateret() returns trigger language plpgsql set search_path = public as $$
begin new.opdateret = now(); return new; end $$;

-- Når et projekt får eller skifter projektnummer, rettes kopien i alle moduler
create or replace function public.projekt_nummer_skiftet() returns trigger language plpgsql set search_path = public as $$
declare t text;
begin
  foreach t in array array['projekt_fokus', 'projekt_noter', 'projekt_info', 'projekt_bid', 'projekt_aendring',
                           'projekt_kvalitet', 'projekt_milepael', 'projekt_dokument'] loop
    execute format('update public.%I set projekt = $1 where projekt_id = $2', t) using new.projektnummer, new.id;
  end loop;
  return null;
end $$;

-- ERP: nye projektnumre i PTD opretter projektet; titel, BU, PL og PA følger seneste PTD
create or replace function public.erp_ptd_til_projekt() returns trigger language plpgsql set search_path = public as $$
begin
  insert into public.projekt (projektnummer, titel, bu, pl, po, status, sidst_i_erp)
  select projekt, navn, bu, pl, po, 'aktiv', pr_dato from nye
  on conflict (projektnummer) do update
    set titel = excluded.titel, bu = excluded.bu, pl = excluded.pl, po = excluded.po,
        sidst_i_erp = excluded.sidst_i_erp,
        status = case when public.projekt.status in ('tilbud', 'lukket') then 'aktiv' else public.projekt.status end
    where public.projekt.sidst_i_erp is null or excluded.sidst_i_erp >= public.projekt.sidst_i_erp;
  return null;
end $$;

-- ERP: risk log og måned sikrer, at projektet findes; risk log udfylder kunden
create or replace function public.erp_andet_til_projekt() returns trigger language plpgsql set search_path = public as $$
begin
  if tg_table_name = 'erp_risiko' then
    insert into public.projekt (projektnummer, titel, bu, pl, po, kunde, status)
    select projekt, navn, bu, pl, po, kunde, 'aktiv' from nye
    on conflict (projektnummer) do update set kunde = coalesce(excluded.kunde, public.projekt.kunde);
  else
    insert into public.projekt (projektnummer, titel, bu, pl, po, status)
    select projekt, navn, bu, pl, po, 'aktiv' from nye
    on conflict (projektnummer) do nothing;
  end if;
  return null;
end $$;

drop trigger if exists projekt_opdateret on public.projekt;
create trigger projekt_opdateret before update on public.projekt for each row execute function public.saet_opdateret();
drop trigger if exists projekt_nummer on public.projekt;
create trigger projekt_nummer after update of projektnummer on public.projekt
  for each row when (old.projektnummer is distinct from new.projektnummer) execute function public.projekt_nummer_skiftet();

drop trigger if exists erp_ptd_projekt on public.erp_ptd;
create trigger erp_ptd_projekt after insert on public.erp_ptd referencing new table as nye
  for each statement execute function public.erp_ptd_til_projekt();
drop trigger if exists erp_maaned_projekt on public.erp_maaned;
create trigger erp_maaned_projekt after insert on public.erp_maaned referencing new table as nye
  for each statement execute function public.erp_andet_til_projekt();
drop trigger if exists erp_risiko_projekt on public.erp_risiko;
create trigger erp_risiko_projekt after insert on public.erp_risiko referencing new table as nye
  for each statement execute function public.erp_andet_til_projekt();

do $$
declare t text;
begin
  foreach t in array array['projekt_fokus', 'projekt_noter', 'projekt_info', 'projekt_bid', 'projekt_aendring',
                           'projekt_kvalitet', 'projekt_milepael', 'projekt_dokument'] loop
    execute format('drop trigger if exists projekt_ref on public.%I', t);
    execute format('create trigger projekt_ref before insert or update of projekt_id, projekt on public.%I for each row execute function public.projekt_ref()', t);
  end loop;
  foreach t in array array['projekt_fokus', 'projekt_info'] loop
    execute format('drop trigger if exists opdateret on public.%I', t);
    execute format('create trigger opdateret before update on public.%I for each row execute function public.saet_opdateret()', t);
  end loop;
end $$;

------------------------------------------------------------------------
-- 6. Funktion: et tilbud får sit ERP-nummer
--    select public.projekt_tildel_nummer('<projektets id>', '10431234');
--    Findes nummeret ikke endnu, sættes det på tilbuddet. Har ERP-udtrækket allerede
--    oprettet projektet, flyttes tilbuddets noter, bid, ændringer osv. over på det,
--    salgsnummer og arbejdstitel bevares, og det midlertidige projekt slettes.
------------------------------------------------------------------------

create or replace function public.projekt_tildel_nummer(p_id uuid, p_nummer text) returns uuid
language plpgsql set search_path = public as $$
declare
  v_maal uuid; v_salg text; v_titel text; v_ekstra jsonb; t text;
begin
  select id into v_maal from public.projekt where projektnummer = p_nummer;
  if v_maal is null then
    update public.projekt set projektnummer = p_nummer, status = case when status = 'tilbud' then 'aktiv' else status end
     where id = p_id;
    return p_id;
  end if;
  if v_maal = p_id then return p_id; end if;

  select salgsnummer, arbejdstitel, ekstra into v_salg, v_titel, v_ekstra from public.projekt where id = p_id;
  foreach t in array array['projekt_noter', 'projekt_bid', 'projekt_aendring', 'projekt_kvalitet', 'projekt_milepael', 'projekt_dokument'] loop
    execute format('update public.%I set projekt_id = $1 where projekt_id = $2', t) using v_maal, p_id;
  end loop;
  foreach t in array array['projekt_fokus', 'projekt_info'] loop      -- én pr. projekt: flyttes kun hvis målet ikke har en
    execute format('update public.%I set projekt_id = $1 where projekt_id = $2 and not exists (select 1 from public.%I where projekt_id = $1)', t, t)
      using v_maal, p_id;
  end loop;
  delete from public.projekt where id = p_id;
  update public.projekt
     set salgsnummer = coalesce(salgsnummer, v_salg), arbejdstitel = coalesce(arbejdstitel, v_titel), ekstra = v_ekstra || ekstra
   where id = v_maal;
  return v_maal;
end $$;

------------------------------------------------------------------------
-- 7. Adgang: kun godkendte brugere
--    Det er ikke nok at være logget ind: e-mailen skal stå i tabellen adgang.
--    Ny bruger: opret brugeren under Authentication > Users, og kør
--      insert into public.adgang (email) values ('navn@niras.dk');
------------------------------------------------------------------------

create table if not exists public.adgang (
  email     text primary key,
  oprettet  timestamptz not null default now()
);
alter table public.adgang enable row level security;
drop policy if exists "egen adgang" on public.adgang;
create policy "egen adgang" on public.adgang for select to authenticated using (lower(email) = lower(auth.jwt() ->> 'email'));

create or replace function public.har_adgang() returns boolean
language sql stable security invoker set search_path = public as $$
  select exists (select 1 from public.adgang where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;
grant execute on function public.har_adgang() to authenticated;

do $$
declare t text;
begin
  foreach t in array array['projekt', 'erp_upload', 'erp_ptd', 'erp_maaned', 'erp_risiko',
                           'projekt_fokus', 'projekt_noter', 'projekt_info', 'projekt_bid', 'projekt_aendring',
                           'projekt_kvalitet', 'projekt_milepael', 'projekt_dokument'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "logget ind: læs" on public.%I', t);
    execute format('drop policy if exists "logget ind: opret" on public.%I', t);
    execute format('drop policy if exists "logget ind: ret" on public.%I', t);
    execute format('drop policy if exists "logget ind: slet" on public.%I', t);
    execute format('create policy "logget ind: læs"  on public.%I for select to authenticated using (public.har_adgang())', t);
    execute format('create policy "logget ind: opret" on public.%I for insert to authenticated with check (public.har_adgang())', t);
    execute format('create policy "logget ind: ret"   on public.%I for update to authenticated using (public.har_adgang()) with check (public.har_adgang())', t);
    execute format('create policy "logget ind: slet"  on public.%I for delete to authenticated using (public.har_adgang())', t);
  end loop;
end $$;

grant select on public.v_projekt, public.v_maaned_trend, public.v_risiko_trend to authenticated;
revoke execute on function public.projekt_tildel_nummer(uuid, text) from public, anon;
grant execute on function public.projekt_tildel_nummer(uuid, text) to authenticated;
