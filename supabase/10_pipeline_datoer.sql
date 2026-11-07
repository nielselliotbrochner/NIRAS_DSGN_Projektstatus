-- Pipeline-datoer (7. nov. 2026): spørgefrist, forventet afgørelse, revideret tilbud (2. bud)
-- og påmindelser dagen før for spørgefrist, revideret tilbud og bid/no bid-beslutning (projekt_bid.beslutningsdato, når beslutningen afventer).
alter table public.projekt_pipeline
  add column if not exists sporgefrist          date,
  add column if not exists forventet_afgoerelse date,
  add column if not exists revideret_tilbud     date,
  add column if not exists sporg_paamindet      timestamptz,
  add column if not exists rev_paamindet        timestamptz,
  add column if not exists bid_paamindet        date;          -- den beslutningsdato, der er sendt påmindelse om

create or replace function public.pipeline_nulstil_paamindelse() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.pq_frist is distinct from old.pq_frist then new.pq_paamindet := null; end if;
  if new.tilbudsfrist is distinct from old.tilbudsfrist then new.tilbud_paamindet := null; end if;
  if new.sporgefrist is distinct from old.sporgefrist then new.sporg_paamindet := null; end if;
  if new.revideret_tilbud is distinct from old.revideret_tilbud then new.rev_paamindet := null; end if;
  return new;
end $$;

create or replace function public.pipe_paamindelser(p_dato date)
returns table (id uuid, art text, nr text, navn text, kunde text, pl text, po text, fase text, frist date, honorar numeric, email text)
language sql security definer set search_path = '' as $$
  with m as (
    select m.*, coalesce(p.projektnummer, p.salgsnummer) as nr, coalesce(p.titel, p.arbejdstitel) as navn, p.kunde, p.pl, p.po, u.email::text as email
    from public.projekt_pipeline m join public.projekt p on p.id = m.projekt_id left join auth.users u on u.id = m.oprettet_af
    where m.fase in ('lead', 'pq', 'tilbud')
  ), b as (
    select distinct on (projekt_id) projekt_id, beslutning, beslutningsdato from public.projekt_bid order by projekt_id, oprettet desc
  )
  select m.id, 'pq', m.nr, m.navn, m.kunde, m.pl, m.po, m.fase, m.pq_frist, m.honorar, m.email from m
   where m.fase in ('lead', 'pq') and m.pq_frist = p_dato and m.pq_paamindet is null and m.pq_afleveret is null
  union all
  select m.id, 'tilbud', m.nr, m.navn, m.kunde, m.pl, m.po, m.fase, m.tilbudsfrist, m.honorar, m.email from m
   where m.tilbudsfrist = p_dato and m.tilbud_paamindet is null and m.tilbud_afleveret is null
  union all
  select m.id, 'spoerg', m.nr, m.navn, m.kunde, m.pl, m.po, m.fase, m.sporgefrist, m.honorar, m.email from m
   where m.sporgefrist = p_dato and m.sporg_paamindet is null
  union all
  select m.id, 'revideret', m.nr, m.navn, m.kunde, m.pl, m.po, m.fase, m.revideret_tilbud, m.honorar, m.email from m
   where m.fase = 'tilbud' and m.revideret_tilbud = p_dato and m.rev_paamindet is null
  union all
  select m.id, 'bid', m.nr, m.navn, m.kunde, m.pl, m.po, m.fase, b.beslutningsdato, m.honorar, m.email from m join b on b.projekt_id = m.projekt_id
   where b.beslutning = 'afventer' and b.beslutningsdato = p_dato and m.bid_paamindet is distinct from p_dato
$$;
revoke all on function public.pipe_paamindelser(date) from public, anon, authenticated;
grant execute on function public.pipe_paamindelser(date) to service_role;

create or replace view public.v_eksport_pipeline with (security_invoker = true) as
  select p.projektnummer, p.salgsnummer, coalesce(p.titel, p.arbejdstitel) as projektnavn, p.bu, p.pl, p.po, p.kunde,
         m.id, m.projekt_id, m.projekt, m.fase, m.kilde, m.honorar, m.vinderchance, m.pq_frist, m.tilbudsfrist, m.forventet_opstart,
         m.resultat_dato, m.pq_paamindet, m.tilbud_paamindet, m.oprettet, m.oprettet_af, m.opdateret, m.opdateret_af,
         m.type, m.ramme_id, m.ramme_vaerdi, m.antal_vindere, m.andel, m.aftale_start, m.aftale_slut, m.bemaerkning,
         rp.salgsnummer as ramme_salgsnummer, coalesce(rp.titel, rp.arbejdstitel) as ramme_navn,
         m.rolle, m.partnere, m.niras_andel, m.udbud, m.stoerrelse, m.anlaegssum, m.ansvarlige, m.pq_afleveret, m.prakvalificeret, m.tilbud_afleveret, m.tabt_i,
         m.sporgefrist, m.forventet_afgoerelse, m.revideret_tilbud,
         b.beslutning as bid_beslutning, b.beslutningsdato as bid_dato
  from public.projekt_pipeline m join public.projekt p on p.id = m.projekt_id
  left join public.projekt_pipeline r on r.id = m.ramme_id
  left join public.projekt rp on rp.id = r.projekt_id
  left join lateral (select beslutning, beslutningsdato from public.projekt_bid where projekt_id = m.projekt_id order by oprettet desc limit 1) b on true;
grant select on public.v_eksport_pipeline to authenticated;
