// MySpace shipment tracking (Supabase Edge Function).
// Only logged-in customers can use it. The carrier's API address, key and
// brand name live in Supabase secrets, never in the website or this code:
//   TRACKING_API_URL     tracking endpoint (the number is added as ?trackingNumber=)
//   TRACKING_API_KEY     your API key
//   TRACKING_API_HEADER  name of the header that carries the key
//   TRACKING_BRAND       carrier name(s) to replace with "MySpace", e.g. "Acme Express|Acme"
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "GET") return reply(405, { error: "method" });

  // must be a logged-in customer (not just the public anon key)
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
  const { data: auth } = await sb.auth.getUser(token);
  if (!auth?.user) return reply(401, { error: "login" });

  const id = (new URL(req.url).searchParams.get("id") || "").replace(/[\s-]/g, "").toUpperCase();
  if (!/^[A-Z0-9]{6,35}$/.test(id)) return reply(400, { error: "number" });

  const apiUrl = Deno.env.get("TRACKING_API_URL"), apiKey = Deno.env.get("TRACKING_API_KEY");
  const apiHeader = Deno.env.get("TRACKING_API_HEADER");
  if (!apiUrl || !apiKey || !apiHeader) return reply(503, { error: "config" });

  const res = await fetch(`${apiUrl}?trackingNumber=${encodeURIComponent(id)}&language=en`, {
    headers: { [apiHeader]: apiKey, Accept: "application/json" },
  });
  if (res.status === 404) return reply(404, { error: "notfound" });
  if (res.status === 429) return reply(429, { error: "busy" });
  if (!res.ok) return reply(502, { error: "upstream" });

  const s = ((await res.json()).shipments || [])[0];
  if (!s) return reply(404, { error: "notfound" });

  const brand = Deno.env.get("TRACKING_BRAND");
  const brandRe = brand ? new RegExp(`\\b(${brand})\\b`, "gi") : null;
  const clean = (t?: string) => (brandRe ? (t || "").replace(brandRe, "MySpace") : (t || "")).replace(/\s{2,}/g, " ").trim();
  // deno-lint-ignore no-explicit-any
  const place = (p: any) => clean(p?.address?.addressLocality);
  // deno-lint-ignore no-explicit-any
  const event = (e: any) => e && ({ time: e.timestamp ?? null, code: e.statusCode || "unknown", text: clean(e.description || e.status), location: place(e.location) });

  return reply(200, {
    id,
    status: event(s.status),
    origin: place(s.origin),
    destination: place(s.destination),
    estimatedDelivery: s.estimatedTimeOfDelivery ?? null,
    pieces: s.details?.totalNumberOfPieces ?? null,
    events: (s.events || []).map(event),
  });
});
