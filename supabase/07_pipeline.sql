-- Pipeline: leads, PQ, tilbud og rammeaftaler før de bliver projekter i ERP.
-- Et lead er en række i stamtabellen projekt (salgsnummer/midlertidigt nummer + arbejdstitel)
-- med én række i projekt_pipeline. Noter, bid/no bid m.m. hænger på projektets faste id og følger med, når det vindes.
-- Kun tilføjelser; kan køres igen uden at skade data.

create table if not exists public.projekt_pipeline (
  id                uuid primary key default gen_random_uuid(),
  projekt_id        uuid not null unique references public.projekt (id) on delete cascade,
  projekt           text,                                   -- kopi af projektnummer (tomt indtil vundet)
  fase              text not null default 'lead' check (fase in ('lead', 'pq', 'tilbud', 'vundet', 'tabt', 'no bid')),
  kilde             text,                                   -- netværk, udbud, rammeaftale, eksisterende kunde ...
  honorar           numeric,                                -- forventet honorar i DKK
  vinderchance      numeric check (vinderchance between 0 and 1),
  pq_frist          date,
  tilbudsfrist      date,
  forventet_opstart date,
  resultat_dato     date,                                   -- dato for vundet/tabt/no bid
  pq_paamindet      timestamptz,                            -- påmindelse sendt dagen før PQ-fristen
  tilbud_paamindet  timestamptz,                            -- påmindelse sendt dagen før tilbudsfristen
  oprettet          timestamptz not null default now(),
  oprettet_af       uuid default auth.uid(),
  opdateret         timestamptz not null default now(),
  opdateret_af      uuid default auth.uid()
);
create index if not exists projekt_pipeline_fase_idx on public.projekt_pipeline (fase);

create or replace trigger projekt_ref before insert or update of projekt_id, projekt on public.projekt_pipeline
  for each row execute function public.projekt_ref();
create or replace trigger opdateret before update on public.projekt_pipeline
  for each row execute function public.saet_opdateret();

-- Ny frist giver ny påmindelse
create or replace function public.pipeline_nulstil_paamindelse() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.pq_frist is distinct from old.pq_frist then new.pq_paamindet := null; end if;
  if new.tilbudsfrist is distinct from old.tilbudsfrist then new.tilbud_paamindet := null; end if;
  return new;
end $$;
create or replace trigger pipeline_paamindelse before update on public.projekt_pipeline
  for each row execute function public.pipeline_nulstil_paamindelse();

-- Adgang som de øvrige moduler
alter table public.projekt_pipeline enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'projekt_pipeline' and policyname = 'logget ind: læs') then
    create policy "logget ind: læs"  on public.projekt_pipeline for select to authenticated using (public.har_adgang());
    create policy "logget ind: opret" on public.projekt_pipeline for insert to authenticated with check (public.har_adgang());
    create policy "logget ind: ret"   on public.projekt_pipeline for update to authenticated using (public.har_adgang()) with check (public.har_adgang());
    create policy "logget ind: slet"  on public.projekt_pipeline for delete to authenticated using (public.har_adgang());
  end if;
end $$;

-- Projektnummer-kopien følger med i alle moduler, også pipeline
create or replace function public.projekt_nummer_skiftet() returns trigger language plpgsql set search_path = public as $$
declare t text;
begin
  foreach t in array array['projekt_fokus', 'projekt_noter', 'projekt_info', 'projekt_bid', 'projekt_aendring',
                           'projekt_kvalitet', 'projekt_milepael', 'projekt_dokument', 'projekt_pipeline'] loop
    execute format('update public.%I set projekt = $1 where projekt_id = $2', t) using new.projektnummer, new.id;
  end loop;
  return null;
end $$;

-- Vundet: sæt fase og evt. ERP-nummer. Har ERP-udtrækket allerede oprettet projektet, flyttes leadets
-- noter, bid, pipeline m.m. over på det. Det midlertidige projekt slettes ikke: det lukkes og peger på det rigtige.
create or replace function public.pipeline_vundet(p_id uuid, p_nummer text default null) returns uuid
language plpgsql security invoker set search_path = public as $$
declare v_maal uuid; v_salg text; v_titel text; v_kunde text; t text;
begin
  if not public.har_adgang() then raise exception 'Ingen adgang'; end if;
  update public.projekt_pipeline set fase = 'vundet', resultat_dato = coalesce(resultat_dato, current_date) where projekt_id = p_id;
  p_nummer := nullif(trim(coalesce(p_nummer, '')), '');
  if p_nummer is null then
    update public.projekt set status = 'aktiv' where id = p_id;
    return p_id;
  end if;
  select id into v_maal from public.projekt where projektnummer = p_nummer;
  if v_maal is null then
    update public.projekt set projektnummer = p_nummer, status = 'aktiv' where id = p_id;
    return p_id;
  end if;
  if v_maal = p_id then return p_id; end if;
  select salgsnummer, arbejdstitel, kunde into v_salg, v_titel, v_kunde from public.projekt where id = p_id;
  foreach t in array array['projekt_noter', 'projekt_bid', 'projekt_aendring', 'projekt_kvalitet', 'projekt_milepael', 'projekt_dokument'] loop
    execute format('update public.%I set projekt_id = $1 where projekt_id = $2', t) using v_maal, p_id;
  end loop;
  foreach t in array array['projekt_fokus', 'projekt_info', 'projekt_pipeline'] loop
    execute format('update public.%I set projekt_id = $1 where projekt_id = $2 and not exists (select 1 from public.%I where projekt_id = $1)', t, t)
      using v_maal, p_id;
  end loop;
  update public.projekt
     set arbejdstitel = coalesce(arbejdstitel, salgsnummer), salgsnummer = null, status = 'lukket',
         ekstra = coalesce(ekstra, '{}'::jsonb) || jsonb_build_object('flettet_til', v_maal, 'flettet', now())
   where id = p_id;
  update public.projekt
     set salgsnummer = coalesce(salgsnummer, v_salg), arbejdstitel = coalesce(arbejdstitel, v_titel), kunde = coalesce(kunde, v_kunde)
   where id = v_maal;
  return v_maal;
end $$;
grant execute on function public.pipeline_vundet(uuid, text) to authenticated;

-- Påmindelser: PQ- og tilbudsfrister i morgen for åbne leads; modtager = den, der oprettede leadet
create or replace function public.pipe_paamindelser(p_dato date)
returns table (id uuid, art text, nr text, navn text, kunde text, pl text, po text, fase text, frist date, honorar numeric, email text)
language sql security definer set search_path = '' as $$
  select m.id, 'pq', coalesce(p.projektnummer, p.salgsnummer), coalesce(p.titel, p.arbejdstitel), p.kunde, p.pl, p.po, m.fase, m.pq_frist, m.honorar, u.email::text
  from public.projekt_pipeline m join public.projekt p on p.id = m.projekt_id left join auth.users u on u.id = m.oprettet_af
  where m.fase in ('lead', 'pq') and m.pq_frist = p_dato and m.pq_paamindet is null
  union all
  select m.id, 'tilbud', coalesce(p.projektnummer, p.salgsnummer), coalesce(p.titel, p.arbejdstitel), p.kunde, p.pl, p.po, m.fase, m.tilbudsfrist, m.honorar, u.email::text
  from public.projekt_pipeline m join public.projekt p on p.id = m.projekt_id left join auth.users u on u.id = m.oprettet_af
  where m.fase in ('lead', 'pq', 'tilbud') and m.tilbudsfrist = p_dato and m.tilbud_paamindet is null
$$;
revoke all on function public.pipe_paamindelser(date) from public, anon, authenticated;
grant execute on function public.pipe_paamindelser(date) to service_role;

------------------------------------------------------------------------
-- Rammeaftaler og miniudbud
--   type 'rammeaftale': aftalesum, antal_vindere, forventet_andel (tom = aftalesum / antal_vindere), aftale_start/slut.
--     Før vundet tæller forventet andel × vinderchance i den vægtede pipeline.
--     Efter vundet tæller den ikke med; resten (andel minus vundne miniudbud) vises som rammepotentiale.
--   type 'miniudbud': ramme_id peger på rammeaftalens projekt; tæller som et almindeligt tilbud (honorar × chance).
------------------------------------------------------------------------
alter table public.projekt_pipeline
  add column if not exists type            text not null default 'tilbud',
  add column if not exists ramme_id        uuid references public.projekt (id) on delete set null,
  add column if not exists aftalesum       numeric,
  add column if not exists antal_vindere   integer,
  add column if not exists forventet_andel numeric,
  add column if not exists aftale_start    date,
  add column if not exists aftale_slut     date,
  add column if not exists bemaerkning     text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'projekt_pipeline_type_check') then
    alter table public.projekt_pipeline add constraint projekt_pipeline_type_check check (type in ('tilbud', 'rammeaftale', 'miniudbud'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'projekt_pipeline_vindere_check') then
    alter table public.projekt_pipeline add constraint projekt_pipeline_vindere_check check (antal_vindere is null or antal_vindere >= 1);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'projekt_pipeline_ramme_check') then
    alter table public.projekt_pipeline add constraint projekt_pipeline_ramme_check check (ramme_id is null or ramme_id <> projekt_id);
  end if;
end $$;
create index if not exists projekt_pipeline_ramme_idx on public.projekt_pipeline (ramme_id);

-- Leadets status i stamtabellen følger fasen, så længe det ikke har ERP-nummer
create or replace function public.pipeline_status() returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.projekt
     set status = case new.fase when 'tabt' then 'tabt' when 'no bid' then 'no bid' when 'vundet' then 'aktiv' else 'tilbud' end
   where id = new.projekt_id and projektnummer is null;
  return null;
end $$;
create or replace trigger pipeline_status after insert or update of fase on public.projekt_pipeline
  for each row execute function public.pipeline_status();

-- Eksport som de øvrige moduler, med rammeaftalens navn
drop view if exists public.v_eksport_pipeline;
create view public.v_eksport_pipeline with (security_invoker = true) as
  select p.projektnummer, p.salgsnummer, coalesce(p.titel, p.arbejdstitel) as projektnavn, p.bu, p.pl, p.po, p.kunde,
         r.salgsnummer as ramme_salgsnummer, coalesce(r.titel, r.arbejdstitel) as ramme_navn, m.*
  from public.projekt_pipeline m join public.projekt p on p.id = m.projekt_id
  left join public.projekt r on r.id = m.ramme_id;
grant select on public.v_eksport_pipeline to authenticated;
