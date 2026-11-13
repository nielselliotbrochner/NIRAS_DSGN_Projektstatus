-- 14: Pipeline udgave 3 (13. nov. 2026)
--  · pipe_rolle: roller for partnere og NIRAS (TE, TR, UR), kan udvides
--  · kollega: hvem der kan være ansvarlig for et lead, PQ eller tilbud
--  · pipe_partner: partnere (fra kundetabellen) med rolle og andel af honoraret
--  · deal_radar: Deal Radar-vurderinger (Pain, Power, Vision, Value, Process, Alignment, 0-5)
--  · pipe_log: ændringslog på leads, PQ og tilbud (skrives af triggere)
--  · projekt_pipeline.no_bid_aarsag
-- Kan køres igen uden at skade data. Ingen sletninger.

-- Roller
create table if not exists public.pipe_rolle (
  kode      text primary key check (btrim(kode) <> ''),
  navn      text not null,
  sortering int not null default 100,
  aktiv     boolean not null default true,
  oprettet  timestamptz not null default now()
);
insert into public.pipe_rolle (kode, navn, sortering) values
  ('TE', 'Totalentreprenør', 10), ('TR', 'Totalrådgiver', 20), ('UR', 'Underrådgiver', 30)
on conflict (kode) do nothing;

-- Ansvarlige (kolleger i NIRAS; også dem, der ikke er PL eller PA i ERP)
create table if not exists public.kollega (
  initialer text primary key check (initialer = upper(initialer) and initialer ~ '^[A-ZÆØÅ0-9]{2,8}$'),
  navn      text,
  email     text,
  aktiv     boolean not null default true,
  oprettet  timestamptz not null default now()
);
insert into public.kollega (initialer, navn) values
  ('KEH', null), ('NEBR', 'Niels Elliot Brøchner'), ('LARN', null), ('HBEI', null), ('RLP', null), ('MHJ', null)
on conflict (initialer) do nothing;

-- Udfald
alter table public.projekt_pipeline add column if not exists no_bid_aarsag text;

-- Partnere med rolle og andel af teamets honorar
create table if not exists public.pipe_partner (
  id          uuid primary key default gen_random_uuid(),
  pipeline_id uuid not null references public.projekt_pipeline(id) on delete cascade,
  kunde_id    uuid not null references public.kunde(id) on delete restrict,
  rolle       text references public.pipe_rolle(kode) on update cascade,
  andel       numeric(6,4) check (andel is null or (andel >= 0 and andel <= 1)),
  sortering   int not null default 0,
  oprettet    timestamptz not null default now()
);
create index if not exists pipe_partner_pipeline_idx on public.pipe_partner (pipeline_id);
create index if not exists pipe_partner_kunde_idx on public.pipe_partner (kunde_id);

-- Deal Radar
create table if not exists public.deal_radar (
  id              uuid primary key default gen_random_uuid(),
  pipeline_id     uuid not null references public.projekt_pipeline(id) on delete cascade,
  dato            date not null default current_date,
  pain            smallint check (pain between 0 and 5),
  power           smallint check (power between 0 and 5),
  vision          smallint check (vision between 0 and 5),
  value           smallint check (value between 0 and 5),
  process         smallint check (process between 0 and 5),
  alignment       smallint check (alignment between 0 and 5),
  note            text,
  naeste_handling text,
  oprettet        timestamptz not null default now(),
  oprettet_af     uuid default auth.uid()
);
create index if not exists deal_radar_pipeline_idx on public.deal_radar (pipeline_id, dato desc);

-- Ændringslog (ingen fremmednøgler, så loggen bevares, når et lead slettes)
create table if not exists public.pipe_log (
  id          bigserial primary key,
  pipeline_id uuid,
  projekt_id  uuid,
  tabel       text not null,
  handling    text not null check (handling in ('oprettet', 'ændret', 'slettet')),
  aendringer  jsonb not null default '{}'::jsonb,
  bruger      text,
  tid         timestamptz not null default now()
);
create index if not exists pipe_log_pipeline_idx on public.pipe_log (pipeline_id, tid desc);

-- Adgang
do $$
declare t text;
begin
  foreach t in array array['pipe_rolle', 'kollega', 'pipe_partner', 'deal_radar'] loop
    execute format('alter table public.%I enable row level security', t);
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'logget ind: læs') then
      execute format('create policy "logget ind: læs" on public.%I for select to authenticated using (public.har_adgang())', t);
      execute format('create policy "logget ind: opret" on public.%I for insert to authenticated with check (public.har_adgang())', t);
      execute format('create policy "logget ind: ret" on public.%I for update to authenticated using (public.har_adgang()) with check (public.har_adgang())', t);
      execute format('create policy "logget ind: slet" on public.%I for delete to authenticated using (public.har_adgang())', t);
    end if;
  end loop;
end $$;
alter table public.pipe_log enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'pipe_log' and policyname = 'logget ind: læs') then
    create policy "logget ind: læs" on public.pipe_log for select to authenticated using (public.har_adgang());
  end if;
end $$;

-- Ændringslog: én række pr. ændring med de felter, der er ændret ({felt: [før, efter]})
create or replace function public.pipe_log_fn() returns trigger language plpgsql security definer set search_path = public as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb := coalesce(n, o);
  skip text[] := array['id', 'projekt', 'oprettet', 'oprettet_af', 'opdateret', 'opdateret_af', 'pq_paamindet', 'tilbud_paamindet',
                       'sporg_paamindet', 'rev_paamindet', 'bid_paamindet', 'pipeline_id', 'sortering'];
  keep text[];
  pid uuid; prj uuid; d jsonb;
begin
  if tg_table_name = 'projekt' then
    keep := array['arbejdstitel', 'salgsnummer', 'projektnummer', 'kunde_id', 'bu'];
    prj := (r ->> 'id')::uuid;
    select id into pid from public.projekt_pipeline where projekt_id = prj limit 1;
    if pid is null then return null; end if;
  elsif tg_table_name = 'projekt_pipeline' then
    pid := (r ->> 'id')::uuid; prj := (r ->> 'projekt_id')::uuid;
  else
    pid := (r ->> 'pipeline_id')::uuid;
    select projekt_id into prj from public.projekt_pipeline where id = pid;
  end if;
  select coalesce(jsonb_object_agg(k, jsonb_build_array(o -> k, n -> k)), '{}'::jsonb) into d
  from jsonb_object_keys(r) k
  where not (k = any (skip)) and (keep is null or k = any (keep))
    and (tg_op <> 'UPDATE' or (o -> k) is distinct from (n -> k))
    and (tg_op = 'UPDATE' or jsonb_typeof(r -> k) <> 'null');
  if tg_op = 'UPDATE' and d = '{}'::jsonb then return null; end if;
  if tg_table_name = 'projekt' and tg_op <> 'UPDATE' then return null; end if;
  insert into public.pipe_log (pipeline_id, projekt_id, tabel, handling, aendringer, bruger)
  values (pid, prj, tg_table_name, case tg_op when 'INSERT' then 'oprettet' when 'UPDATE' then 'ændret' else 'slettet' end,
          d, coalesce(auth.jwt() ->> 'email', current_user));
  return null;
end $$;

create or replace trigger pipe_log_pipeline after insert or update or delete on public.projekt_pipeline
  for each row execute function public.pipe_log_fn();
create or replace trigger pipe_log_partner after insert or update or delete on public.pipe_partner
  for each row execute function public.pipe_log_fn();
create or replace trigger pipe_log_radar after insert or update or delete on public.deal_radar
  for each row execute function public.pipe_log_fn();
create or replace trigger pipe_log_projekt after update on public.projekt
  for each row execute function public.pipe_log_fn();

-- Eksport: partnere og seneste Deal Radar
create or replace view public.v_eksport_deal_radar with (security_invoker = true) as
select p.projektnummer, p.salgsnummer, coalesce(p.titel, p.arbejdstitel) as projektnavn, p.bu, p.pl, p.po,
       d.dato, d.pain, d.power, d.vision, d.value, d.process, d.alignment,
       coalesce(d.pain, 0) + coalesce(d.power, 0) + coalesce(d.vision, 0) + coalesce(d.value, 0) + coalesce(d.process, 0) + coalesce(d.alignment, 0) as score,
       d.note, d.naeste_handling, d.oprettet
from public.deal_radar d join public.projekt_pipeline m on m.id = d.pipeline_id join public.projekt p on p.id = m.projekt_id;
grant select on public.v_eksport_deal_radar to authenticated;

create or replace view public.v_eksport_pipe_partner with (security_invoker = true) as
select p.projektnummer, p.salgsnummer, coalesce(p.titel, p.arbejdstitel) as projektnavn, p.bu, p.pl, p.po,
       k.navn as partner, e.navn as partner_erp_navn, pp.rolle, r.navn as rolle_navn, pp.andel, pp.oprettet
from public.pipe_partner pp
join public.projekt_pipeline m on m.id = pp.pipeline_id join public.projekt p on p.id = m.projekt_id
join public.kunde k on k.id = pp.kunde_id left join public.kunde e on e.id = k.erp_id
left join public.pipe_rolle r on r.kode = pp.rolle;
grant select on public.v_eksport_pipe_partner to authenticated;

-- Pipeline-eksporten får årsag til no bid, partnere og seneste Deal Radar-score (kolonner tilføjet til sidst)
create or replace view public.v_eksport_pipeline with (security_invoker = true) as
 SELECT p.projektnummer, p.salgsnummer, COALESCE(p.titel, p.arbejdstitel) AS projektnavn, p.bu, p.pl, p.po, p.kunde,
    m.id, m.projekt_id, m.projekt, m.fase, m.kilde, m.honorar, m.vinderchance, m.pq_frist, m.tilbudsfrist, m.forventet_opstart, m.resultat_dato,
    m.pq_paamindet, m.tilbud_paamindet, m.oprettet, m.oprettet_af, m.opdateret, m.opdateret_af, m.type, m.ramme_id, m.ramme_vaerdi, m.antal_vindere,
    m.andel, m.aftale_start, m.aftale_slut, m.bemaerkning, rp.salgsnummer AS ramme_salgsnummer, COALESCE(rp.titel, rp.arbejdstitel) AS ramme_navn,
    m.rolle, m.partnere, m.niras_andel, m.udbud, m.stoerrelse, m.anlaegssum, m.ansvarlige, m.pq_afleveret, m.prakvalificeret, m.tilbud_afleveret,
    m.tabt_i, m.sporgefrist, m.forventet_afgoerelse, m.revideret_tilbud, b.beslutning AS bid_beslutning, b.beslutningsdato AS bid_dato,
    m.no_bid_aarsag,
    (select string_agg(k.navn || coalesce(' (' || pp.rolle || coalesce(', ' || round(pp.andel * 100, 1) || ' %', '') || ')', ''), ', ' order by pp.sortering)
       from public.pipe_partner pp join public.kunde k on k.id = pp.kunde_id where pp.pipeline_id = m.id) as partner_liste,
    (select coalesce(d.pain,0)+coalesce(d.power,0)+coalesce(d.vision,0)+coalesce(d.value,0)+coalesce(d.process,0)+coalesce(d.alignment,0)
       from public.deal_radar d where d.pipeline_id = m.id order by d.dato desc, d.oprettet desc limit 1) as deal_radar_score
   FROM projekt_pipeline m
     JOIN projekt p ON p.id = m.projekt_id
     LEFT JOIN projekt_pipeline r ON r.id = m.ramme_id
     LEFT JOIN projekt rp ON rp.id = r.projekt_id
     LEFT JOIN LATERAL ( SELECT projekt_bid.beslutning, projekt_bid.beslutningsdato FROM projekt_bid
          WHERE projekt_bid.projekt_id = m.projekt_id ORDER BY projekt_bid.oprettet DESC LIMIT 1) b ON true;
