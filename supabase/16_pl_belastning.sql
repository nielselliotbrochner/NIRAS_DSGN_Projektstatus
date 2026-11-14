-- 16: PL-belastning (14. nov. 2026)
--  · kollega.pl: personen vises i fanen PL-belastning
--  · kollega.ansvarlig: personen kan være ansvarlig for leads, PQ og tilbud (afløser kollega.aktiv)
--  · pl_linje: en linje pr. person og ERP-projekt eller intern aktivitet, med note
--  · pl_belastning: procent af fuld tid pr. linje og måned
--  · pl_log: ændringslog skrevet af triggere
-- Kan køres igen uden at skade data. Ingen sletninger.

alter table public.kollega add column if not exists pl boolean not null default false;
alter table public.kollega add column if not exists ansvarlig boolean not null default false;
-- De ansvarlige fra pipelinen bevares. Dashboardet holder aktiv = ansvarlig, så linjen kan køres igen.
update public.kollega set ansvarlig = true where aktiv and not ansvarlig;

create table if not exists public.pl_linje (
  id          uuid primary key default gen_random_uuid(),
  initialer   text not null references public.kollega(initialer) on update cascade on delete cascade,
  projekt     text,                   -- ERP-projektnummer
  aktivitet   text,                   -- intern aktivitet, fx Salg og tilbud
  note        text,
  skjult      boolean not null default false,
  sortering   int not null default 0,
  oprettet    timestamptz not null default now(),
  oprettet_af uuid default auth.uid(),
  constraint pl_linje_hvad check (projekt is not null or (aktivitet is not null and btrim(aktivitet) <> ''))
);
create unique index if not exists pl_linje_projekt_uq on public.pl_linje (initialer, projekt) where projekt is not null;
create index if not exists pl_linje_init_idx on public.pl_linje (initialer);

create table if not exists public.pl_belastning (
  linje_id uuid not null references public.pl_linje(id) on delete cascade,
  maaned   date not null check (extract(day from maaned) = 1),
  procent  numeric(5,1) not null check (procent >= 0 and procent <= 300),
  primary key (linje_id, maaned)
);

create table if not exists public.pl_log (
  id         bigserial primary key,
  initialer  text,
  linje_id   uuid,
  tabel      text not null,
  handling   text not null check (handling in ('oprettet', 'ændret', 'slettet')),
  aendringer jsonb not null default '{}'::jsonb,
  bruger     text,
  tid        timestamptz not null default now()
);
create index if not exists pl_log_init_idx on public.pl_log (initialer, tid desc);

do $$
declare t text;
begin
  foreach t in array array['pl_linje', 'pl_belastning'] loop
    execute format('alter table public.%I enable row level security', t);
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'logget ind: læs') then
      execute format('create policy "logget ind: læs" on public.%I for select to authenticated using (public.har_adgang())', t);
      execute format('create policy "logget ind: opret" on public.%I for insert to authenticated with check (public.har_adgang())', t);
      execute format('create policy "logget ind: ret" on public.%I for update to authenticated using (public.har_adgang()) with check (public.har_adgang())', t);
      execute format('create policy "logget ind: slet" on public.%I for delete to authenticated using (public.har_adgang())', t);
    end if;
  end loop;
end $$;
alter table public.pl_log enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'pl_log' and policyname = 'logget ind: læs') then
    create policy "logget ind: læs" on public.pl_log for select to authenticated using (public.har_adgang());
  end if;
end $$;

create or replace function public.pl_log_fn() returns trigger language plpgsql security definer set search_path = public as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb := coalesce(n, o);
  lid uuid; ini text; d jsonb;
begin
  if tg_table_name = 'pl_linje' then lid := (r ->> 'id')::uuid; ini := r ->> 'initialer';
  elsif tg_table_name = 'pl_belastning' then lid := (r ->> 'linje_id')::uuid; select initialer into ini from public.pl_linje where id = lid;
  else ini := r ->> 'initialer'; end if;
  select coalesce(jsonb_object_agg(k, jsonb_build_array(o -> k, n -> k)), '{}'::jsonb) into d
  from jsonb_object_keys(r) k
  where k not in ('id', 'oprettet', 'oprettet_af', 'sortering')
    and (tg_op <> 'UPDATE' or (o -> k) is distinct from (n -> k))
    and (tg_op = 'UPDATE' or jsonb_typeof(r -> k) <> 'null');
  if tg_op = 'UPDATE' and d = '{}'::jsonb then return null; end if;
  insert into public.pl_log (initialer, linje_id, tabel, handling, aendringer, bruger)
  values (ini, lid, tg_table_name, case tg_op when 'INSERT' then 'oprettet' when 'UPDATE' then 'ændret' else 'slettet' end,
          d, coalesce(auth.jwt() ->> 'email', current_user));
  return null;
end $$;
create or replace trigger pl_log_linje after insert or update or delete on public.pl_linje for each row execute function public.pl_log_fn();
create or replace trigger pl_log_belastning after insert or update or delete on public.pl_belastning for each row execute function public.pl_log_fn();
create or replace trigger pl_log_kollega after insert or update on public.kollega for each row execute function public.pl_log_fn();

-- Eksport
create or replace view public.v_eksport_pl_belastning with (security_invoker = true) as
select l.initialer, k.navn, l.projekt, p.titel as projektnavn, l.aktivitet, l.note, l.skjult, b.maaned, b.procent
from public.pl_linje l join public.kollega k on k.initialer = l.initialer
left join public.pl_belastning b on b.linje_id = l.id
left join public.projekt p on p.projektnummer = l.projekt;
grant select on public.v_eksport_pl_belastning to authenticated;

-- Senest opdateret pr. person: seneste ændring af personens linjer eller procenter, eller "Gennemgået i dag"
alter table public.kollega add column if not exists pl_gennemgaaet timestamptz;
create or replace view public.v_pl_opdateret with (security_invoker = true) as
select initialer, max(tid) as opdateret from public.pl_log
where tabel in ('pl_linje', 'pl_belastning') and initialer is not null
group by initialer;
grant select on public.v_pl_opdateret to authenticated;

-- Linjetyper: projekt (ERP), intern, diverse (navngiven linje uden projektnummer), pulje (flere ERP-projekter på én linje), alle (alle projekter som PL)
-- Navnet på intern, diverse, pulje og alle står i aktivitet; puljens projektnumre i projekter.
alter table public.pl_linje add column if not exists type text check (type in ('projekt', 'intern', 'diverse', 'pulje', 'alle'));
alter table public.pl_linje add column if not exists projekter text[];
update public.pl_linje set type = case when projekt is not null then 'projekt' else 'intern' end where type is null;
create unique index if not exists pl_linje_alle_uq on public.pl_linje (initialer) where type = 'alle';
create or replace view public.v_eksport_pl_belastning with (security_invoker = true) as
select l.initialer, k.navn, l.projekt, p.titel as projektnavn, l.aktivitet, l.note, l.skjult, b.maaned, b.procent, l.type, array_to_string(l.projekter, ', ') as projekter
from public.pl_linje l join public.kollega k on k.initialer = l.initialer
left join public.pl_belastning b on b.linje_id = l.id
left join public.projekt p on p.projektnummer = l.projekt;
