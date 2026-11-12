-- 12: Felter fra de nye ERP-udtræk "Detailed Main Project View" (PTD og valgt måned)
-- Kun nye kolonner (nullable) og en opdateret trigger. Gamle udtræk har tomme felter.

do $$
declare t text;
begin
  foreach t in array array['erp_ptd', 'erp_maaned'] loop
    execute format($f$
      alter table public.%I
        add column if not exists kunde               text,           -- Customer
        add column if not exists kontrakttype        text,           -- Customer Contract Type (Fixed Price / Time & Material)
        add column if not exists risikoklasse        smallint,       -- Risk Class (Maconomy), Level 1-4
        add column if not exists ps                  text,           -- PS
        add column if not exists startdato           date,           -- Started Date
        add column if not exists oprettet_dato       date,           -- Creation Date
        add column if not exists forv_slut           date,           -- Expected Ending Date
        add column if not exists faerdig_dato        date,           -- Work Completed Date
        add column if not exists lukket_dato         date,           -- Actual Closing Date
        add column if not exists underlev            numeric(16,2),  -- Subcontractor Cost (ACT)
        add column if not exists overhead            numeric(16,2),  -- Overhead
        add column if not exists projektresultat     numeric(16,2),  -- Project Profit (ACT)
        add column if not exists overforbrug         numeric(16,2),  -- Over-spending
        add column if not exists rest_oms            numeric(16,2),  -- Remaning Revenue Recognized (kun PTD)
        add column if not exists backlog_brutto      numeric(16,2),  -- Backlog Gross (kun PTD)
        add column if not exists backlog_netto       numeric(16,2),  -- Backlog Net (kun PTD)
        add column if not exists kostpris            numeric(14,4),  -- Cost Rate (kun PTD)
        add column if not exists salgspris           numeric(14,4),  -- Sales Rate (kun PTD)
        add column if not exists fakt_fm             numeric(14,6),  -- Invoiced FM (kun PTD)
        add column if not exists delta_tfm_eac       numeric(14,6),  -- Delta Factor EAC
        add column if not exists tfm_etc             numeric(14,6),  -- Factor TFM (ETC)
        add column if not exists timer               numeric(14,2),  -- Hours QTY (ACT)
        add column if not exists timer_etc           numeric(14,2),  -- Hours QTY (ETC)
        add column if not exists timer_eac           numeric(14,2),  -- Hours QTY (EAC) (kun PTD)
        add column if not exists loen_etc            numeric(16,2),  -- Labour Cost Total Time (ETC)
        add column if not exists loen_eac            numeric(16,2),  -- Total Labour Costs Time (EAC)
        add column if not exists ext_etc             numeric(16,2),  -- External Cost (ETC)
        add column if not exists ext_eac             numeric(16,2),  -- External Cost (EAC)
        add column if not exists underlev_etc        numeric(16,2),  -- Subcontractor Costs (ETC)
        add column if not exists underlev_eac        numeric(16,2),  -- Subcontractor Costs (EAC)
        add column if not exists contingency         numeric(16,2),  -- Contingency
        add column if not exists effekt_aendring     numeric(16,2),  -- Effect of Change (kun måned)
        add column if not exists mangler_kontrakt    boolean,        -- Missing Contract
        add column if not exists mangler_risikoklasse boolean,       -- Missing Risk Class
        add column if not exists mangler_tjekliste   boolean,        -- Missing Checklist
        add column if not exists mangler_qa          boolean,        -- Missing QA
        add column if not exists mangler_survey      boolean         -- Missing Survey
    $f$, t);
  end loop;
end $$;

-- Det nye månedsudtræk har også POC (status ved månedens udgang)
alter table public.erp_maaned add column if not exists poc numeric(14,6);

create index if not exists erp_ptd_kunde_idx on public.erp_ptd (pr_dato, kunde);

-- PTD udfylder nu også kunden på projektet
create or replace function public.erp_ptd_til_projekt() returns trigger language plpgsql set search_path = public as $$
begin
  insert into public.projekt (projektnummer, titel, bu, pl, po, kunde, status, sidst_i_erp)
  select projekt, navn, bu, pl, po, kunde, 'aktiv', pr_dato from nye
  on conflict (projektnummer) do update
    set titel = excluded.titel, bu = excluded.bu, pl = excluded.pl, po = excluded.po,
        kunde = coalesce(excluded.kunde, public.projekt.kunde),
        sidst_i_erp = excluded.sidst_i_erp,
        status = case when public.projekt.status in ('tilbud', 'lukket') then 'aktiv' else public.projekt.status end
    where public.projekt.sidst_i_erp is null or excluded.sidst_i_erp >= public.projekt.sidst_i_erp;
  return null;
end $$;
