-- Pipeline, udgave 2 (7. nov. 2026): felter fra DSGN's liste over tilbud og PQ'er.
--   rolle (TR, UR, Eneste rådgiver, Partner), partnere (fri tekst), niras_andel (0-1, tom = 100 %),
--   udbud (fælles navn for delaftaler), stoerrelse (som oplyst, fx "H > 30 mio"), anlaegssum,
--   ansvarlige (initialer), pq_afleveret, prakvalificeret, tilbud_afleveret, tabt_i (fase ved tabt/no bid/annulleret).
--   Fasen annulleret (kunden aflyste). Påmindelser springer afleverede PQ'er og tilbud over.
-- Værdi: opgave/miniudbud = honorar × niras_andel. Rammeaftale = ramme_vaerdi × andel (tom = 1/antal_vindere) × niras_andel.
alter table public.projekt_pipeline
  add column if not exists rolle            text,
  add column if not exists partnere         text,
  add column if not exists niras_andel      numeric,
  add column if not exists udbud            text,
  add column if not exists stoerrelse       text,
  add column if not exists anlaegssum       numeric,
  add column if not exists ansvarlige       text,
  add column if not exists pq_afleveret     date,
  add column if not exists prakvalificeret  date,
  add column if not exists tilbud_afleveret date,
  add column if not exists tabt_i           text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'projekt_pipeline_niras_andel_check') then
    alter table public.projekt_pipeline add constraint projekt_pipeline_niras_andel_check check (niras_andel is null or niras_andel between 0 and 1);
  end if;
end $$;
alter table public.projekt_pipeline drop constraint if exists projekt_pipeline_fase_check;
alter table public.projekt_pipeline add constraint projekt_pipeline_fase_check
  check (fase in ('lead', 'pq', 'tilbud', 'vundet', 'tabt', 'no bid', 'annulleret'));

create or replace function public.pipeline_status() returns trigger
language plpgsql set search_path = '' as $$
begin
  update public.projekt
     set status = case new.fase when 'tabt' then 'tabt' when 'no bid' then 'no bid' when 'annulleret' then 'lukket' when 'vundet' then 'aktiv' else 'tilbud' end
   where id = new.projekt_id and projektnummer is null;
  return null;
end $$;

create or replace function public.pipe_paamindelser(p_dato date)
returns table (id uuid, art text, nr text, navn text, kunde text, pl text, po text, fase text, frist date, honorar numeric, email text)
language sql security definer set search_path = '' as $$
  select m.id, 'pq', coalesce(p.projektnummer, p.salgsnummer), coalesce(p.titel, p.arbejdstitel), p.kunde, p.pl, p.po, m.fase, m.pq_frist, m.honorar, u.email::text
  from public.projekt_pipeline m join public.projekt p on p.id = m.projekt_id left join auth.users u on u.id = m.oprettet_af
  where m.fase in ('lead', 'pq') and m.pq_frist = p_dato and m.pq_paamindet is null and m.pq_afleveret is null
  union all
  select m.id, 'tilbud', coalesce(p.projektnummer, p.salgsnummer), coalesce(p.titel, p.arbejdstitel), p.kunde, p.pl, p.po, m.fase, m.tilbudsfrist, m.honorar, u.email::text
  from public.projekt_pipeline m join public.projekt p on p.id = m.projekt_id left join auth.users u on u.id = m.oprettet_af
  where m.fase in ('lead', 'pq', 'tilbud') and m.tilbudsfrist = p_dato and m.tilbud_paamindet is null and m.tilbud_afleveret is null
$$;
revoke all on function public.pipe_paamindelser(date) from public, anon, authenticated;
grant execute on function public.pipe_paamindelser(date) to service_role;

create or replace view public.v_eksport_pipeline with (security_invoker = true) as
  select p.projektnummer, p.salgsnummer, coalesce(p.titel, p.arbejdstitel) as projektnavn, p.bu, p.pl, p.po, p.kunde,
         m.id, m.projekt_id, m.projekt, m.fase, m.kilde, m.honorar, m.vinderchance, m.pq_frist, m.tilbudsfrist, m.forventet_opstart,
         m.resultat_dato, m.pq_paamindet, m.tilbud_paamindet, m.oprettet, m.oprettet_af, m.opdateret, m.opdateret_af,
         m.type, m.ramme_id, m.ramme_vaerdi, m.antal_vindere, m.andel, m.aftale_start, m.aftale_slut, m.bemaerkning,
         rp.salgsnummer as ramme_salgsnummer, coalesce(rp.titel, rp.arbejdstitel) as ramme_navn,
         m.rolle, m.partnere, m.niras_andel, m.udbud, m.stoerrelse, m.anlaegssum, m.ansvarlige, m.pq_afleveret, m.prakvalificeret, m.tilbud_afleveret, m.tabt_i
  from public.projekt_pipeline m join public.projekt p on p.id = m.projekt_id
  left join public.projekt_pipeline r on r.id = m.ramme_id
  left join public.projekt rp on rp.id = r.projekt_id;
grant select on public.v_eksport_pipeline to authenticated;
