-- Kør denne fil i Supabase: SQL Editor > New query > indsæt > Run.
-- Funktionen bruges, når et tilbud får sit ERP-nummer (bid/no bid-modulet).
-- Den er udskilt, fordi den indeholder en sletning af det midlertidige projekt,
-- som Claudes Supabase-forbindelse ikke må køre automatisk.

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
  foreach t in array array['projekt_fokus', 'projekt_info'] loop
    execute format('update public.%I set projekt_id = $1 where projekt_id = $2 and not exists (select 1 from public.%I where projekt_id = $1)', t, t)
      using v_maal, p_id;
  end loop;
  delete from public.projekt where id = p_id;
  update public.projekt
     set salgsnummer = coalesce(salgsnummer, v_salg), arbejdstitel = coalesce(arbejdstitel, v_titel), ekstra = v_ekstra || ekstra
   where id = v_maal;
  return v_maal;
end $$;
revoke execute on function public.projekt_tildel_nummer(uuid, text) from public, anon;
grant execute on function public.projekt_tildel_nummer(uuid, text) to authenticated;
