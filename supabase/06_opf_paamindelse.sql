-- E-mail-påmindelse om opfølgninger dagen før fristen kl. 07 dansk tid (via Brevo).
-- Er allerede kørt i projektet. Kan køres igen uden at skade data.
-- Edge-funktionen ligger i supabase/functions/opf-paamindelse (verify_jwt = false; den tjekker selv x-cron-secret).
-- Hemmeligheder under Edge Functions > Secrets: BREVO_API_KEY, BREVO_SENDER, valgfri BREVO_SENDER_NAME.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

alter table public.projekt_noter add column if not exists paamindet timestamptz;

create or replace function public.noter_nulstil_paamindelse() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.frist is distinct from old.frist or (old.status = 'lukket' and new.status = 'åben') then
    new.paamindet := null;
  end if;
  return new;
end $$;
create or replace trigger noter_paamindelse before update on public.projekt_noter
  for each row execute function public.noter_nulstil_paamindelse();

select vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'opf_cron_secret', 'Delt hemmelighed mellem pg_cron og edge-funktionen opf-paamindelse')
where not exists (select 1 from vault.secrets where name = 'opf_cron_secret');

create or replace function public.opf_cron_ok(s text) returns boolean
language sql security definer set search_path = '' as $$
  select exists (select 1 from vault.decrypted_secrets where name = 'opf_cron_secret' and decrypted_secret = s)
$$;

create or replace function public.opf_paamindelser(p_dato date)
returns table (id uuid, projekt text, navn text, pl text, po text, opfoelgning text, note text, frist date, email text)
language sql security definer set search_path = '' as $$
  select n.id, n.projekt, coalesce(p.titel, p.arbejdstitel), p.pl, p.po, n.opfoelgning, n.note, n.frist, u.email::text
  from public.projekt_noter n
  join public.projekt p on p.id = n.projekt_id
  left join auth.users u on u.id = n.oprettet_af
  where n.status = 'åben' and n.opfoelgning is not null and n.frist = p_dato and n.paamindet is null
  order by n.projekt
$$;

revoke all on function public.opf_cron_ok(text) from public, anon, authenticated;
revoke all on function public.opf_paamindelser(date) from public, anon, authenticated;
grant execute on function public.opf_cron_ok(text) to service_role;
grant execute on function public.opf_paamindelser(date) to service_role;

-- Kl. 05 og 06 UTC = kl. 07 dansk tid i sommer- og vintertid
select cron.schedule('opf-paamindelse', '0 5,6 * * *', $job$
  select net.http_post(
    url := 'https://afwhyejitlhlghugmplv.supabase.co/functions/v1/opf-paamindelse',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'opf_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 30000);
$job$);

-- Test uden at sende: select net.http_post(url := '…/functions/v1/opf-paamindelse', headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='opf_cron_secret')), body := '{"force":true,"dry":true}'::jsonb);
-- Svaret læses i: select * from net._http_response order by id desc limit 1;
