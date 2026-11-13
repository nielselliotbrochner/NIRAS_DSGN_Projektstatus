-- 15: Nulstil pipelinen (13. nov. 2026)
-- Sletter alle leads, PQ, tilbud, rammeaftaler og miniudbud og alt, der hænger på dem:
-- pipeline-felter, partnere, Deal Radar, bid/no bid, de midlertidige kunder og ændringsloggen.
-- ERP-projekter, ERP-kunder, roller og ansvarlige røres ikke.
-- Kør hele scriptet i Supabase › SQL Editor. Det kan ikke fortrydes.

begin;

-- 1. Leads uden ERP-nummer: hele projektet slettes (noter, info, bid og pipeline følger med)
delete from public.projekt p
 where p.projektnummer is null and p.sidst_i_erp is null
   and exists (select 1 from public.projekt_pipeline m where m.projekt_id = p.id);

-- 2. Pipeline-data på projekter, der findes i ERP (de vundne)
delete from public.projekt_pipeline;
delete from public.projekt_bid;
update public.projekt set kunde_id = null where kunde_id is not null;

-- 3. Midlertidige kunder og partnere (ERP-kunderne bliver)
delete from public.kunde where type = 'midlertidig';

-- 4. Ændringsloggen starter forfra
truncate public.pipe_log;

commit;

-- Kontrol: alle tal skal være 0
select (select count(*) from public.projekt_pipeline) as pipeline,
       (select count(*) from public.projekt_bid) as bid,
       (select count(*) from public.kunde where type = 'midlertidig') as midlertidige_kunder,
       (select count(*) from public.pipe_log) as log;
