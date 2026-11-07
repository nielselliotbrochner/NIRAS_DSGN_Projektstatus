// Påmindelse om opfølgninger og om PQ- og tilbudsfrister i pipelinen dagen før fristen, kl. 07 dansk tid.
// Kaldes af pg_cron kl. 05 og 06 UTC; funktionen sender kun, når klokken er 7 i København (dækker sommer- og vintertid).
// Hemmeligheder (Supabase > Edge Functions > Secrets): BREVO_API_KEY, BREVO_SENDER (afsenderadresse godkendt i Brevo), valgfri BREVO_SENDER_NAME.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DASH = "https://nielselliotbrochner.github.io/NIRAS_DSGN_Projektstatus/#opf";
const TZ = "Europe/Copenhagen";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const db = async (path: string, init: RequestInit = {}) => {
  const r = await fetch(URL_ + path, { ...init, headers: { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json", ...(init.headers || {}) } });
  const t = await r.text();
  if (!r.ok) throw new Error(`Database ${r.status}: ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
};
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const cphParts = (d = new Date()) => Object.fromEntries(new Intl.DateTimeFormat("sv-SE", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23" }).formatToParts(d).map((p) => [p.type, p.value]));
// fx "fredag 13/11/2026"
const daLong = (iso: string) => new Date(iso + "T12:00:00Z").toLocaleDateString("da-DK", { weekday: "long", timeZone: "UTC" }) + " " + iso.slice(8, 10) + "/" + iso.slice(5, 7) + "/" + iso.slice(0, 4);

type Row = { id: string; projekt: string; navn: string | null; pl: string | null; po: string | null; opfoelgning: string; note: string | null; frist: string; email: string | null };

function mail(rows: Row[], frist: string) {
  const n = rows.length;
  // Én opfølgning pr. mail: emnet starter med projektnummer og -navn
  const subject = n === 1 ? `${rows[0].projekt} ${rows[0].navn || ""}`.trim() + " · Opfølgning i morgen" : `Opfølgning i morgen: ${n} projekter`;
  const items = rows.map((r) => `
    <tr>
      <td style="padding:10px 12px;border-bottom:1px solid #EFE6DE;vertical-align:top;white-space:nowrap;font-weight:600;color:#700B15">${esc(r.projekt)}</td>
      <td style="padding:10px 12px;border-bottom:1px solid #EFE6DE;vertical-align:top">
        <div style="font-weight:600">${esc(r.opfoelgning)}</div>
        <div style="color:#6F6560;font-size:13px;margin-top:2px">${esc(r.navn || "")}${r.pl ? " · PL " + esc(r.pl) : ""}${r.po ? " · PA " + esc(r.po) : ""}</div>
        ${r.note ? `<div style="color:#6F6560;font-size:13px;margin-top:6px;white-space:pre-wrap">${esc(r.note.length > 300 ? r.note.slice(0, 300) + " …" : r.note)}</div>` : ""}
      </td>
    </tr>`).join("");
  const html = `<!doctype html><html><body style="margin:0;background:#F2E2D5;font-family:Aptos,'Segoe UI',Arial,sans-serif;color:#221B18">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F2E2D5;padding:24px 12px"><tr><td align="center">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;background:#ffffff;border-radius:8px;overflow:hidden">
      <tr><td style="background:#700B15;color:#fff;padding:16px 20px"><span style="font-weight:700;letter-spacing:.18em">NIRAS</span>&nbsp;&nbsp;<span style="font-family:'Aptos Serif',Georgia,serif">Projektstatus · opfølgning</span></td></tr>
      <tr><td style="padding:20px 20px 8px">
        <p style="margin:0 0 4px;font-size:18px;font-weight:600">${n} ${n === 1 ? "opfølgning har" : "opfølgninger har"} frist i morgen</p>
        <p style="margin:0;color:#6F6560;font-size:14px">${esc(daLong(frist))}</p>
      </td></tr>
      <tr><td style="padding:8px 8px 4px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px">${items}</table></td></tr>
      <tr><td style="padding:16px 20px 22px"><a href="${DASH}" style="display:inline-block;background:#BA1223;color:#fff;text-decoration:none;padding:10px 16px;border-radius:6px;font-weight:600">Åbn Opfølgning i dashboardet</a></td></tr>
    </table>
    <p style="color:#6F6560;font-size:12px;margin:12px 0 0">Sendt automatisk kl. 07 dagen før fristen.</p>
  </td></tr></table></body></html>`;
  const text = `${n} ${n === 1 ? "opfølgning har" : "opfølgninger har"} frist i morgen (${daLong(frist)}):\n\n` +
    rows.map((r) => `${r.projekt} ${r.navn || ""}\n  Opfølgning: ${r.opfoelgning}${r.pl ? "\n  PL " + r.pl : ""}${r.po ? " · PA " + r.po : ""}`).join("\n\n") + `\n\nDashboard: ${DASH}\n`;
  return { subject, html, text };
}

type Pipe = { id: string; art: "pq" | "tilbud"; nr: string | null; navn: string | null; kunde: string | null; pl: string | null; po: string | null; fase: string; frist: string; honorar: number | null; email: string | null };

// Pipeline: én mail pr. frist, fx "S-100 Rammeaftale Testby · Tilbudsfrist i morgen"
function pipeMail(r: Pipe, frist: string) {
  const hvad = r.art === "pq" ? "PQ-frist" : "Tilbudsfrist";
  const subject = `${r.nr || ""} ${r.navn || ""}`.trim() + ` · ${hvad} i morgen`;
  const link = DASH.replace("#opf", "#pipe");
  const html = `<!doctype html><html><body style="margin:0;background:#F2E2D5;font-family:Aptos,'Segoe UI',Arial,sans-serif;color:#221B18">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F2E2D5;padding:24px 12px"><tr><td align="center">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;background:#ffffff;border-radius:8px;overflow:hidden">
      <tr><td style="background:#700B15;color:#fff;padding:16px 20px"><span style="font-weight:700;letter-spacing:.18em">NIRAS</span>&nbsp;&nbsp;<span style="font-family:'Aptos Serif',Georgia,serif">Projektstatus · pipeline</span></td></tr>
      <tr><td style="padding:20px 20px 8px">
        <p style="margin:0 0 4px;font-size:18px;font-weight:600">${esc(hvad)} i morgen</p>
        <p style="margin:0;color:#6F6560;font-size:14px">${esc(daLong(frist))}</p>
      </td></tr>
      <tr><td style="padding:8px 20px 4px;font-size:14px">
        <div style="font-weight:600;color:#700B15">${esc(r.nr || "Uden nummer")} ${esc(r.navn || "")}</div>
        <div style="color:#6F6560;font-size:13px;margin-top:2px">${esc(r.kunde || "")}${r.pl ? " · PL " + esc(r.pl) : ""}${r.po ? " · PA " + esc(r.po) : ""}${r.honorar ? " · honorar " + esc(new Intl.NumberFormat("da-DK").format(Math.round(r.honorar / 1000))) + " tDKK" : ""}</div>
      </td></tr>
      <tr><td style="padding:16px 20px 22px"><a href="${link}" style="display:inline-block;background:#BA1223;color:#fff;text-decoration:none;padding:10px 16px;border-radius:6px;font-weight:600">Åbn Pipeline i dashboardet</a></td></tr>
    </table>
    <p style="color:#6F6560;font-size:12px;margin:12px 0 0">Sendt automatisk kl. 07 dagen før fristen.</p>
  </td></tr></table></body></html>`;
  const text = `${hvad} i morgen (${daLong(frist)}):\n\n${r.nr || ""} ${r.navn || ""}\n${[r.kunde, r.pl ? "PL " + r.pl : "", r.po ? "PA " + r.po : ""].filter(Boolean).join(" · ")}\n\nDashboard: ${link}\n`;
  return { subject, html, text };
}

Deno.serve(async (req) => {
  try {
    const ok = await db("/rest/v1/rpc/opf_cron_ok", { method: "POST", body: JSON.stringify({ s: req.headers.get("x-cron-secret") || "" }) });
    if (ok !== true) return json({ fejl: "Ikke tilladt" }, 401);
    const body = await req.json().catch(() => ({}));
    const force = !!body.force, dry = !!body.dry, test = !!body.test; // test: sender, men markerer ikke som påmindet
    const now = cphParts();
    if (!force && now.hour !== "07") return json({ sprunget_over: true, klokken_i_kbh: now.hour });
    const today = `${now.year}-${now.month}-${now.day}`;
    const tomorrow = body.dato || new Date(Date.parse(today + "T12:00:00Z") + 864e5).toISOString().slice(0, 10);
    const rows: Row[] = await db("/rest/v1/rpc/opf_paamindelser", { method: "POST", body: JSON.stringify({ p_dato: tomorrow }) });
    const pipe: Pipe[] = await db("/rest/v1/rpc/pipe_paamindelser", { method: "POST", body: JSON.stringify({ p_dato: tomorrow }) }).catch(() => []);
    if (!rows.length && !pipe.length) return json({ frist: tomorrow, sendt: 0, besked: "Ingen opfølgninger eller pipeline-frister i morgen" });
    // Uden forfatter går mailen til alle godkendte brugere
    let fallback: string[] | null = null;
    const modtagere = async (email: string | null) => email ? [email] : (fallback ??= ((await db("/rest/v1/adgang?select=email")) as { email: string }[]).map((x) => x.email));
    type Job = { email: string; kind: "opf" | "pq" | "tilbud"; id: string; m: { subject: string; html: string; text: string } };
    const jobs: Job[] = [];
    for (const r of rows) for (const e of await modtagere(r.email)) jobs.push({ email: e, kind: "opf", id: r.id, m: mail([r], tomorrow) });
    for (const r of pipe) for (const e of await modtagere(r.email)) jobs.push({ email: e, kind: r.art, id: r.id, m: pipeMail(r, tomorrow) });
    if (dry) return json({ frist: tomorrow, test: true, mails: jobs.map((j) => ({ email: j.email, emne: j.m.subject })) });
    const apiKey = Deno.env.get("BREVO_API_KEY"), sender = Deno.env.get("BREVO_SENDER");
    if (!apiKey || !sender) return json({ fejl: "BREVO_API_KEY og BREVO_SENDER mangler under Edge Functions > Secrets" }, 500);
    const result: unknown[] = [];
    const sent = { opf: new Set<string>(), pq: new Set<string>(), tilbud: new Set<string>() };
    for (const j of jobs) {
      const r = await fetch("https://api.brevo.com/v3/smtp/email", {
        method: "POST",
        headers: { "api-key": apiKey, "Content-Type": "application/json", accept: "application/json" },
        body: JSON.stringify({ sender: { email: sender, name: Deno.env.get("BREVO_SENDER_NAME") || "NIRAS Projektstatus" }, to: [{ email: j.email }], subject: (test ? "[Test] " : "") + j.m.subject, htmlContent: j.m.html, textContent: j.m.text, tags: [j.kind === "opf" ? "opfoelgning" : "pipeline"] }),
      });
      const t = await r.text();
      result.push({ email: j.email, emne: j.m.subject, status: r.status, svar: t.slice(0, 200) });
      if (r.ok) sent[j.kind].add(j.id);
    }
    if (!test) {
      const stamp = JSON.stringify({ paamindet: new Date().toISOString() });
      const min = { method: "PATCH", headers: { Prefer: "return=minimal" } };
      if (sent.opf.size) await db(`/rest/v1/projekt_noter?id=in.(${[...sent.opf].join(",")})`, { ...min, body: stamp });
      if (sent.pq.size) await db(`/rest/v1/projekt_pipeline?id=in.(${[...sent.pq].join(",")})`, { ...min, body: JSON.stringify({ pq_paamindet: new Date().toISOString() }) });
      if (sent.tilbud.size) await db(`/rest/v1/projekt_pipeline?id=in.(${[...sent.tilbud].join(",")})`, { ...min, body: JSON.stringify({ tilbud_paamindet: new Date().toISOString() }) });
    }
    return json({ frist: tomorrow, sendt: sent.opf.size + sent.pq.size + sent.tilbud.size, test, mails: result });
  } catch (e) {
    return json({ fejl: String((e as Error).message || e) }, 500);
  }
});
