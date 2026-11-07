-- Engangsoprydning (7. nov. 2026): fjerner to dubletkolonner, der blev oprettet ved en fejl.
-- Tabellen projekt_pipeline var tom, så intet går tabt. Kør i Supabase > SQL Editor.
drop view if exists public.v_eksport_pipeline;
alter table public.projekt_pipeline drop column if exists aftalesum, drop column if exists forventet_andel;
alter table public.projekt_pipeline drop constraint if exists projekt_pipeline_ramme_check;
alter table public.projekt_pipeline add constraint projekt_pipeline_ramme_check check (ramme_id is null or ramme_id <> id);
create view public.v_eksport_pipeline with (security_invoker = true) as
  select p.projektnummer, p.salgsnummer, coalesce(p.titel, p.arbejdstitel) as projektnavn, p.bu, p.pl, p.po, p.kunde, m.*,
         rp.salgsnummer as ramme_salgsnummer, coalesce(rp.titel, rp.arbejdstitel) as ramme_navn
  from public.projekt_pipeline m join public.projekt p on p.id = m.projekt_id
  left join public.projekt_pipeline r on r.id = m.ramme_id
  left join public.projekt rp on rp.id = r.projekt_id;
grant select on public.v_eksport_pipeline to authenticated;
