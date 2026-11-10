-- Personnoter (10. nov. 2026): noter på en person (initialer som i ERP: PL/PA) med dato, opfølgning,
-- koblede projekter og vedhæftede filer i den private bucket person-filer.
create table if not exists public.person_noter (
  id           uuid primary key default gen_random_uuid(),
  initialer    text not null check (initialer = upper(initialer) and initialer <> ''),
  dato         date not null default current_date,
  note         text,
  opfoelgning  text,
  frist        date,
  status       text not null default 'åben' check (status in ('åben', 'lukket')),
  projekter    uuid[] not null default '{}',              -- koblede projekter (projekt.id)
  oprettet     timestamptz not null default now(),
  oprettet_af  uuid default auth.uid(),
  redigeret    timestamptz,
  paamindet    timestamptz                                 -- påmindelse om opfølgning sendt
);
create index if not exists person_noter_initialer_idx on public.person_noter (initialer, dato desc);

create table if not exists public.note_filer (
  id             uuid primary key default gen_random_uuid(),
  person_note_id uuid not null references public.person_noter (id) on delete cascade,
  sti            text not null unique,                    -- sti i bucket person-filer
  filnavn        text not null,
  mime           text,
  stoerrelse     bigint,
  oprettet       timestamptz not null default now(),
  oprettet_af    uuid default auth.uid()
);
create index if not exists note_filer_note_idx on public.note_filer (person_note_id);

-- Ny frist giver ny påmindelse
create or replace function public.person_note_nulstil() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.frist is distinct from old.frist or new.opfoelgning is distinct from old.opfoelgning then new.paamindet := null; end if;
  return new;
end $$;
create or replace trigger person_note_nulstil before update on public.person_noter
  for each row execute function public.person_note_nulstil();

alter table public.person_noter enable row level security;
alter table public.note_filer enable row level security;
do $$ declare t text; begin
  foreach t in array array['person_noter', 'note_filer'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'logget ind: læs') then
      execute format('create policy "logget ind: læs" on public.%I for select to authenticated using (public.har_adgang())', t);
      execute format('create policy "logget ind: opret" on public.%I for insert to authenticated with check (public.har_adgang())', t);
      execute format('create policy "logget ind: ret" on public.%I for update to authenticated using (public.har_adgang()) with check (public.har_adgang())', t);
      execute format('create policy "logget ind: slet" on public.%I for delete to authenticated using (public.har_adgang())', t);
    end if;
  end loop;
end $$;

-- Privat bucket til filer (højst 25 MB pr. fil)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('person-filer', 'person-filer', false, 26214400, array[
  'application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp', 'image/gif',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/msword',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/vnd.ms-outlook', 'message/rfc822', 'text/plain', 'text/csv'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'person-filer: læs') then
    create policy "person-filer: læs"  on storage.objects for select to authenticated using (bucket_id = 'person-filer' and public.har_adgang());
    create policy "person-filer: opret" on storage.objects for insert to authenticated with check (bucket_id = 'person-filer' and public.har_adgang());
    create policy "person-filer: ret"   on storage.objects for update to authenticated using (bucket_id = 'person-filer' and public.har_adgang());
    create policy "person-filer: slet"  on storage.objects for delete to authenticated using (bucket_id = 'person-filer' and public.har_adgang());
  end if;
end $$;

-- Eksport
create or replace view public.v_eksport_personnoter with (security_invoker = true) as
  select n.initialer, n.dato, n.note, n.opfoelgning, n.frist, n.status,
         (select string_agg(coalesce(p.projektnummer, p.salgsnummer, p.arbejdstitel), ', ') from public.projekt p where p.id = any (n.projekter)) as projekter,
         (select string_agg(f.filnavn, ', ' order by f.oprettet) from public.note_filer f where f.person_note_id = n.id) as filer,
         n.oprettet, n.redigeret, n.id
  from public.person_noter n;
grant select on public.v_eksport_personnoter to authenticated;

-- Påmindelse dagen før fristen
create or replace function public.person_paamindelser(p_dato date)
returns table (id uuid, initialer text, note text, opfoelgning text, frist date, email text)
language sql security definer set search_path = '' as $$
  select n.id, n.initialer, n.note, n.opfoelgning, n.frist, u.email::text
  from public.person_noter n left join auth.users u on u.id = n.oprettet_af
  where n.status = 'åben' and n.opfoelgning is not null and n.frist = p_dato and n.paamindet is null
$$;
revoke all on function public.person_paamindelser(date) from public, anon, authenticated;
grant execute on function public.person_paamindelser(date) to service_role;

-- Koblede projekter gemmes som ERP-projektnumre (kolonnen projekter er ubrugt)
alter table public.person_noter add column if not exists projektnumre text[] not null default '{}';
comment on column public.person_noter.projektnumre is 'Koblede projekter (ERP-projektnumre)';
comment on column public.person_noter.projekter is 'Ubrugt (erstattet af projektnumre)';
create or replace view public.v_eksport_personnoter with (security_invoker = true) as
  select n.initialer, n.dato, n.note, n.opfoelgning, n.frist, n.status,
         (select string_agg(coalesce(p.projektnummer, p.salgsnummer, p.arbejdstitel), ', ') from public.projekt p where p.id = any (n.projekter)) as projekter,
         (select string_agg(f.filnavn, ', ' order by f.oprettet) from public.note_filer f where f.person_note_id = n.id) as filer,
         n.oprettet, n.redigeret, n.id,
         array_to_string(n.projektnumre, ', ') as projektnumre
  from public.person_noter n;
