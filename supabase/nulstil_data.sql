-- Sletter alle udtræk, projekter og egne registreringer (noter, fokus, info, bid m.m.).
-- Tabellen adgang bevares, så godkendte brugere stadig kan logge ind.
-- Kør i Supabase > SQL Editor. Kan ikke fortrydes.
truncate table
  public.erp_ptd, public.erp_maaned, public.erp_risiko, public.erp_upload,
  public.projekt_noter, public.projekt_fokus, public.projekt_info, public.projekt_bid,
  public.projekt_aendring, public.projekt_kvalitet, public.projekt_milepael, public.projekt_dokument,
  public.projekt
restart identity cascade;
