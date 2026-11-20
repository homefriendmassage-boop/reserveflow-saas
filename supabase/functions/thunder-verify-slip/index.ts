import { createClient } from 'npm:@supabase/supabase-js@2.98.0';
import { decodeSlipQr } from './decode.ts';
import { verifySlip } from './thunder.ts';

const cors = {
  'Access-Control-Allow-Origin': 'https://homefriendmassage-boop.github.io',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const json = (body: unknown, status = 200) => Response.json(body, { headers: cors, status });

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (request.method !== 'POST') return json({state:'unavailable'},405);
  let bookingId: unknown;
  let phone: unknown;
  try {
    const raw = await request.text();
    if (raw.length > 500) return json({state:'unavailable'},400);
    ({ booking_id: bookingId, phone } = JSON.parse(raw));
  } catch {
    return json({state:'unavailable'},400);
  }
  if (typeof bookingId !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(bookingId) ||
      (phone != null && (typeof phone !== 'string' || !/^[0-9\s-]{9,20}$/.test(phone)))) {
    return json({state:'unavailable'},400);
  }
  const url = Deno.env.get('SUPABASE_URL')!;
  let staffId = null;
  if (!phone) {
    const authorization = request.headers.get('Authorization');
    if (!authorization?.startsWith('Bearer ')) return json({state:'unavailable'},401);
    const client = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!);
    const { data, error } = await client.auth.getUser(authorization.slice(7));
    if (error || !data.user) return json({state:'unavailable'},401);
    staffId = data.user.id;
  }
  const key = Deno.env.get('THUNDER_API_KEY')?.trim();
  if (!key) return json({state:'not_configured'});

  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const claim = await admin.rpc('claim_thunder_booking_slip', {
    p_booking_id: bookingId, p_phone: phone || null, p_staff: staffId
  });
  if (claim.error || !claim.data) return json({state:'unavailable'});
  if (claim.data.state !== 'claimed') return json(claim.data);
  const payload = decodeSlipQr(claim.data.image);
  let result;
  try {
    result = payload ? await verifySlip(payload, key) : { outcome:'qr_unreadable' };
  } catch {
    result = {outcome:'retry'};
  }
  const finished = await admin.rpc('finish_thunder_booking_slip', {
    p_booking_id: bookingId, p_outcome: result.outcome, p_reference: result.reference ?? null,
    p_amount: result.amount ?? null, p_mobile: result.mobile ?? null, p_paid_at: result.paidAt ?? null
  });
  return json(finished.error ? {state:'unavailable'} : finished.data);
});
