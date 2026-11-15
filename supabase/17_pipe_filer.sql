-- 17: Filer på leads, PQ, tilbud, rammeaftaler og miniudbud (15. nov. 2026)
--  · pipe_fil: én række pr. fil med sti i den private bucket pipe-filer
--  · bucket pipe-filer: højst 50 MB pr. fil; pdf, billeder, Office, msg, eml, txt, csv og zip
--  · ændringsloggen (pipe_log) registrerer, når en fil tilføjes eller slettes
-- Kan køres igen uden at skade data. Ingen sletninger.

create table if not exists public.pipe_fil (
  id          uuid primary key default gen_random_uuid(),
  pipeline_id uuid not null references public.projekt_pipeline(id) on delete cascade,
  sti         text not null unique,           -- sti i bucket pipe-filer
  filnavn     text not null,
  mime        text,
  stoerrelse  bigint,
  oprettet    timestamptz not null default now(),
  oprettet_af uuid default auth.uid()
);
create index if not exists pipe_fil_pipeline_idx on public.pipe_fil (pipeline_id);

alter table public.pipe_fil enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'pipe_fil' and policyname = 'logget ind: læs') then
    create policy "logget ind: læs"  on public.pipe_fil for select to authenticated using (public.har_adgang());
    create policy "logget ind: opret" on public.pipe_fil for insert to authenticated with check (public.har_adgang());
    create policy "logget ind: ret"   on public.pipe_fil for update to authenticated using (public.har_adgang()) with check (public.har_adgang());
    create policy "logget ind: slet"  on public.pipe_fil for delete to authenticated using (public.har_adgang());
  end if;
end $$;

-- Privat bucket
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pipe-filer', 'pipe-filer', false, 52428800, array[
  'application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp', 'image/gif',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/msword',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation', 'application/vnd.ms-powerpoint',
  'application/vnd.ms-outlook', 'message/rfc822', 'text/plain', 'text/csv', 'application/zip'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'pipe-filer: læs') then
    create policy "pipe-filer: læs"  on storage.objects for select to authenticated using (bucket_id = 'pipe-filer' and public.har_adgang());
    create policy "pipe-filer: opret" on storage.objects for insert to authenticated with check (bucket_id = 'pipe-filer' and public.har_adgang());
    create policy "pipe-filer: ret"   on storage.objects for update to authenticated using (bucket_id = 'pipe-filer' and public.har_adgang());
    create policy "pipe-filer: slet"  on storage.objects for delete to authenticated using (bucket_id = 'pipe-filer' and public.har_adgang());
  end if;
end $$;

-- Ændringslog (pipe_log_fn fra 14_pipeline_v3.sql finder sagen via pipeline_id)
create or replace trigger pipe_log_fil after insert or delete on public.pipe_fil
  for each row execute function public.pipe_log_fn();

-- Eksport
create or replace view public.v_eksport_pipe_fil with (security_invoker = true) as
select p.projektnummer, p.salgsnummer, coalesce(p.titel, p.arbejdstitel) as projektnavn, p.bu, p.pl, p.po,
       m.fase, f.filnavn, f.mime, f.stoerrelse, f.oprettet
from public.pipe_fil f
join public.projekt_pipeline m on m.id = f.pipeline_id
join public.projekt p on p.id = m.projekt_id;
grant select on public.v_eksport_pipe_fil to authenticated;
