-- 18: Filer på projektnoter (20. nov. 2026)
--  · projekt_note_fil: én række pr. fil på en note i projektets detalje (projekt_noter)
--  · bucket projekt-filer: privat, højst 50 MB pr. fil; pdf, billeder, Office, msg, eml, txt, csv og zip
-- Kan køres igen uden at skade data. Ingen sletninger.

create table if not exists public.projekt_note_fil (
  id              uuid primary key default gen_random_uuid(),
  projekt_note_id uuid not null references public.projekt_noter(id) on delete cascade,
  sti             text not null unique,           -- sti i bucket projekt-filer
  filnavn         text not null,
  mime            text,
  stoerrelse      bigint,
  oprettet        timestamptz not null default now(),
  oprettet_af     uuid default auth.uid()
);
create index if not exists projekt_note_fil_note_idx on public.projekt_note_fil (projekt_note_id);

alter table public.projekt_note_fil enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'projekt_note_fil' and policyname = 'logget ind: læs') then
    create policy "logget ind: læs"  on public.projekt_note_fil for select to authenticated using (public.har_adgang());
    create policy "logget ind: opret" on public.projekt_note_fil for insert to authenticated with check (public.har_adgang());
    create policy "logget ind: ret"   on public.projekt_note_fil for update to authenticated using (public.har_adgang()) with check (public.har_adgang());
    create policy "logget ind: slet"  on public.projekt_note_fil for delete to authenticated using (public.har_adgang());
  end if;
end $$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('projekt-filer', 'projekt-filer', false, 52428800, array[
  'application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp', 'image/gif',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/msword',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation', 'application/vnd.ms-powerpoint',
  'application/vnd.ms-outlook', 'message/rfc822', 'text/plain', 'text/csv', 'application/zip'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'projekt-filer: læs') then
    create policy "projekt-filer: læs"  on storage.objects for select to authenticated using (bucket_id = 'projekt-filer' and public.har_adgang());
    create policy "projekt-filer: opret" on storage.objects for insert to authenticated with check (bucket_id = 'projekt-filer' and public.har_adgang());
    create policy "projekt-filer: ret"   on storage.objects for update to authenticated using (bucket_id = 'projekt-filer' and public.har_adgang());
    create policy "projekt-filer: slet"  on storage.objects for delete to authenticated using (bucket_id = 'projekt-filer' and public.har_adgang());
  end if;
end $$;

-- Eksport
create or replace view public.v_eksport_projekt_note_fil with (security_invoker = true) as
select p.projektnummer, coalesce(p.titel, p.arbejdstitel) as projektnavn, p.bu, p.pl, p.po,
       n.periode, n.oprettet as note_oprettet, f.filnavn, f.mime, f.stoerrelse, f.oprettet
from public.projekt_note_fil f
join public.projekt_noter n on n.id = f.projekt_note_id
join public.projekt p on p.id = n.projekt_id;
grant select on public.v_eksport_projekt_note_fil to authenticated;
