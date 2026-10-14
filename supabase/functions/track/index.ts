// MySpace shipment tracking (Supabase Edge Function) — automatic carrier updates.
// Only logged-in customers can use it, and only for tracking numbers MySpace has
// added to the "shipments" table (so nobody can use up the tracking quota).
//
// Secrets (Supabase -> Edge Functions -> Secrets):
//   TRACKING_PROVIDER    "17track" (recommended) or "carrier" (a carrier's own tracking API)
//   TRACKING_API_KEY     the provider's key (17TRACK: "Security Key")
//   TRACKING_CARRIER     optional carrier code for 17TRACK (e.g. 100001)
//   TRACKING_BRAND       carrier name(s) to replace with "MySpace", e.g. "Acme Express|Acme"
//   for "carrier" only:  TRACKING_API_URL, TRACKING_API_HEADER
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });

type Ev = { time: string | null; code: string; text: string; location: string };
type Result = { events: Ev[]; status: Ev | null; estimatedDelivery: string | null; pending?: boolean };

const brand = Deno.env.get("TRACKING_BRAND");
const brandRe = brand ? new RegExp(`\\b(${brand})\\b`, "gi") : null;
const clean = (t?: string | null) => (brandRe ? (t || "").replace(brandRe, "MySpace") : (t || "")).replace(/\s{2,}/g, " ").trim();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "GET") return reply(405, { error: "method" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: auth } = await createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!).auth.getUser(token);
  if (!auth?.user) return reply(401, { error: "login" });

  const id = (new URL(req.url).searchParams.get("id") || "").replace(/[\s-]/g, "").toUpperCase();
  if (!/^[A-Z0-9]{6,35}$/.test(id)) return reply(400, { error: "number" });

  // only numbers MySpace has added
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: known } = await admin.from("shipments").select("tracking_number").eq("tracking_number", id).maybeSingle();
  if (!known) return reply(404, { error: "notfound" });

  const provider = (Deno.env.get("TRACKING_PROVIDER") || "").toLowerCase();
  const key = Deno.env.get("TRACKING_API_KEY");
  if (!key || !provider) return reply(503, { error: "config" });

  try {
    const result = provider === "17track" ? await from17track(id, key) : await fromCarrier(id, key);
    if (!result) return reply(404, { error: "notfound" });
    return reply(200, { id, ...result });
  } catch (e) {
    console.error("tracking provider error", e);
    return reply(502, { error: "upstream" });
  }
});

/* ---------------- 17TRACK (api.17track.net, v2.4) ---------------- */
const API17 = "https://api.17track.net/track/v2.4";
const STAGE: Record<string, string> = {
  InfoReceived: "created", PickedUp: "picked_up", Departure: "in_transit", Arrival: "in_transit",
  AvailableForPickup: "out_for_delivery", OutForDelivery: "out_for_delivery", Delivered: "delivered",
  Returning: "problem", Returned: "problem",
};
const MAIN: Record<string, string> = {
  InfoReceived: "created", InTransit: "in_transit", AvailableForPickup: "out_for_delivery", OutForDelivery: "out_for_delivery",
  Delivered: "delivered", DeliveryFailure: "problem", Exception: "problem", Expired: "problem",
};
// deno-lint-ignore no-explicit-any
const code17 = (e: any) => STAGE[e?.stage] || MAIN[String(e?.sub_status || "").split("_")[0]] || "in_transit";

async function call17(path: string, body: unknown, key: string) {
  const r = await fetch(`${API17}/${path}`, { method: "POST", headers: { "17token": key, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`17track ${path} ${r.status}`);
  return await r.json();
}

async function from17track(id: string, key: string): Promise<Result | null> {
  const carrier = Number(Deno.env.get("TRACKING_CARRIER")) || undefined;
  const item = carrier ? { number: id, carrier } : { number: id };
  let res = await call17("gettrackinfo", [item], key);
  const rejected = res?.data?.rejected?.[0];
  if (rejected?.error?.code === -18019902) {            // not registered yet: register once (uses 1 quota)
    const reg = await call17("register", [item], key);
    const regErr = reg?.data?.rejected?.[0]?.error;
    if (regErr && regErr.code !== -18019901) throw new Error(`17track register ${regErr.code} ${regErr.message}`);
    await sleep(4000);
    res = await call17("gettrackinfo", [item], key);
  } else if (rejected) {
    throw new Error(`17track ${rejected.error?.code} ${rejected.error?.message}`);
  }
  const info = res?.data?.accepted?.[0]?.track_info;
  if (!info) return { events: [], status: null, estimatedDelivery: null, pending: true };

  // deno-lint-ignore no-explicit-any
  const evs: Ev[] = (info.tracking?.providers || []).flatMap((p: any) => p.events || []).map((e: any) => ({
    time: e.time_iso || e.time_utc || null,
    code: code17(e),
    text: clean(e.description),
    location: clean(e.location || [e.address?.city, e.address?.country].filter(Boolean).join(", ")),
  })).sort((a: Ev, b: Ev) => String(b.time).localeCompare(String(a.time)));

  const main = MAIN[info.latest_status?.status];
  const status = evs[0] ? { ...evs[0], code: main || evs[0].code } : null;
  const eta = info.time_metrics?.estimated_delivery_date?.to || info.time_metrics?.estimated_delivery_date?.from || null;
  return { events: evs, status, estimatedDelivery: eta, pending: !evs.length };
}

/* ---------------- a carrier's own tracking API (if ever available) ---------------- */
const CARRIER_CODE: Record<string, string> = { "pre-transit": "created", transit: "in_transit", delivered: "delivered", failure: "problem" };
async function fromCarrier(id: string, key: string): Promise<Result | null> {
  const apiUrl = Deno.env.get("TRACKING_API_URL"), header = Deno.env.get("TRACKING_API_HEADER");
  if (!apiUrl || !header) throw new Error("carrier settings missing");
  const r = await fetch(`${apiUrl}?trackingNumber=${encodeURIComponent(id)}&language=en`, { headers: { [header]: key, Accept: "application/json" } });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`carrier ${r.status}`);
  const s = ((await r.json()).shipments || [])[0];
  if (!s) return null;
  // deno-lint-ignore no-explicit-any
  const ev = (e: any): Ev => ({ time: e?.timestamp ?? null, code: CARRIER_CODE[e?.statusCode] || "in_transit", text: clean(e?.description || e?.status), location: clean(e?.location?.address?.addressLocality) });
  const events = (s.events || []).map(ev);
  return { events, status: s.status ? ev(s.status) : events[0] || null, estimatedDelivery: s.estimatedTimeOfDelivery ?? null };
}
