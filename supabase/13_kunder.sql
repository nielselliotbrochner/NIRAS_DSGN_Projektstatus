-- 13: Kundetabel med ERP-kunder og midlertidige kunder (tilbudsfasen)
--  · ERP-kunder lægges ind automatisk fra PTD og risk log.
--  · Midlertidige kunder oprettes i pipelinen, når kunden ikke findes i ERP.
--  · En midlertidig kunde kan kobles til en ERP-kunde (erp_id). Tilbuddene beholder den midlertidige kunde,
--    så historikken viser, hvad kunden hed i tilbudsfasen, men vises og tælles med ERP-navnet.
-- Kan køres igen uden at skade data.

create table if not exists public.kunde (
  id          uuid primary key default gen_random_uuid(),
  navn        text not null check (btrim(navn) <> ''),
  type        text not null default 'midlertidig' check (type in ('erp', 'midlertidig')),
  erp_id      uuid references public.kunde(id) on delete set null,   -- kun midlertidige: koblet ERP-kunde
  koblet      timestamptz,
  koblet_af   text,
  bemaerkning text,
  oprettet    timestamptz not null default now(),
  oprettet_af uuid default auth.uid(),
  constraint kunde_kobling check (erp_id is null or type = 'midlertidig')
);
create unique index if not exists kunde_navn_uq on public.kunde (lower(btrim(navn)), type);
create index if not exists kunde_erp_id_idx on public.kunde (erp_id);

alter table public.projekt add column if not exists kunde_id uuid references public.kunde(id) on delete set null;
create index if not exists projekt_kunde_id_idx on public.projekt (kunde_id);

alter table public.kunde enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'kunde' and policyname = 'logget ind: læs') then
    create policy "logget ind: læs" on public.kunde for select to authenticated using (public.har_adgang());
    create policy "logget ind: opret" on public.kunde for insert to authenticated with check (public.har_adgang());
    create policy "logget ind: ret" on public.kunde for update to authenticated using (public.har_adgang()) with check (public.har_adgang());
    create policy "logget ind: slet" on public.kunde for delete to authenticated using (public.har_adgang());
  end if;
end $$;

-- ERP-kunder fra nye udtræk; midlertidige kunder med præcis samme navn kobles automatisk
create or replace function public.kunde_fra_erp() returns trigger language plpgsql set search_path = public as $$
begin
  insert into public.kunde (navn, type, oprettet_af)
  select distinct on (lower(btrim(kunde))) btrim(kunde), 'erp', null from nye
  where kunde is not null and btrim(kunde) <> ''
  on conflict (lower(btrim(navn)), type) do nothing;
  update public.kunde m set erp_id = e.id, koblet = now(), koblet_af = 'ERP (samme navn)'
  from public.kunde e
  where m.type = 'midlertidig' and m.erp_id is null and e.type = 'erp' and lower(btrim(e.navn)) = lower(btrim(m.navn));
  return null;
end $$;
create or replace trigger erp_ptd_kunde after insert on public.erp_ptd referencing new table as nye
  for each statement execute function public.kunde_fra_erp();
create or replace trigger erp_risiko_kunde after insert on public.erp_risiko referencing new table as nye
  for each statement execute function public.kunde_fra_erp();

-- Kundenavnet på et projekt følger kunde_id (ERP-navnet, når kunden er koblet).
-- Projekter, der er kommet i ERP, får kundenavnet fra ERP og røres ikke.
create or replace function public.projekt_kunde_navn() returns trigger language plpgsql set search_path = public as $$
begin
  if new.kunde_id is not null and new.sidst_i_erp is null then
    select coalesce(e.navn, k.navn) into new.kunde
    from public.kunde k left join public.kunde e on e.id = k.erp_id where k.id = new.kunde_id;
  end if;
  return new;
end $$;
create or replace trigger projekt_kunde_navn before insert or update of kunde_id on public.projekt
  for each row execute function public.projekt_kunde_navn();

-- Kobl en midlertidig kunde til en ERP-kunde (p_erp = null fjerner koblingen)
create or replace function public.kunde_kobl(p_midl uuid, p_erp uuid) returns void language plpgsql set search_path = public as $$
begin
  if p_erp is not null and not exists (select 1 from public.kunde where id = p_erp and type = 'erp') then
    raise exception 'Der kan kun kobles til en ERP-kunde';
  end if;
  update public.kunde
     set erp_id = p_erp,
         koblet = case when p_erp is null then null else now() end,
         koblet_af = case when p_erp is null then null else coalesce(auth.jwt() ->> 'email', 'ukendt') end
   where id = p_midl and type = 'midlertidig';
  if not found then raise exception 'Kunden findes ikke eller er ikke midlertidig'; end if;
  update public.projekt
     set kunde = coalesce((select navn from public.kunde where id = p_erp), (select navn from public.kunde where id = p_midl))
   where kunde_id = p_midl and sidst_i_erp is null;
end $$;
grant execute on function public.kunde_kobl(uuid, uuid) to authenticated;

-- Eksport: kunder med kobling og antal pipeline-punkter
create or replace view public.v_eksport_kunder with (security_invoker = true) as
select k.navn, k.type, e.navn as erp_navn, k.koblet, k.koblet_af, k.bemaerkning, k.oprettet,
       (select count(*) from public.projekt p join public.projekt_pipeline pp on pp.projekt_id = p.id where p.kunde_id = k.id) as pipeline_punkter
from public.kunde k left join public.kunde e on e.id = k.erp_id
where k.type = 'midlertidig' or exists (select 1 from public.projekt p where p.kunde_id = k.id);
grant select on public.v_eksport_kunder to authenticated;

-- Første fyldning: ERP-kunder fra eksisterende udtræk og ERP-projekter
insert into public.kunde (navn, type, oprettet_af)
select distinct on (lower(btrim(kunde))) btrim(kunde), 'erp', null
from (select kunde from public.erp_ptd union all select kunde from public.erp_risiko
      union all select kunde from public.projekt where sidst_i_erp is not null) x
where kunde is not null and btrim(kunde) <> ''
on conflict (lower(btrim(navn)), type) do nothing;

-- Pipeline-punkter: præcist ERP-navn (uden hensyn til store og små bogstaver) kobles; resten bliver midlertidige kunder
insert into public.kunde (navn, type, oprettet_af)
select distinct on (lower(btrim(p.kunde))) btrim(p.kunde), 'midlertidig', null
from public.projekt p join public.projekt_pipeline pp on pp.projekt_id = p.id
where p.kunde is not null and btrim(p.kunde) <> ''
  and not exists (select 1 from public.kunde e where e.type = 'erp' and lower(btrim(e.navn)) = lower(btrim(p.kunde)))
on conflict (lower(btrim(navn)), type) do nothing;

update public.projekt p
   set kunde_id = coalesce(
     (select id from public.kunde e where e.type = 'erp' and lower(btrim(e.navn)) = lower(btrim(p.kunde))),
     (select id from public.kunde m where m.type = 'midlertidig' and lower(btrim(m.navn)) = lower(btrim(p.kunde))))
 where p.kunde_id is null and p.kunde is not null
   and exists (select 1 from public.projekt_pipeline pp where pp.projekt_id = p.id);
