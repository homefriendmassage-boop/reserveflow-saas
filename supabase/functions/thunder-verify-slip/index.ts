import { createClient } from 'npm:@supabase/supabase-js@2.98.0';
import { verifySlip } from './thunder.ts';

const cors = {
  'Access-Control-Allow-Origin': 'https://homefriendmassage-boop.github.io',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

Deno.serve(async request => {
  const reply = (result: string, status = 200) => Response.json({ result }, { headers: cors, status });
  if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (request.method !== 'POST') return reply('method_not_allowed',405);
  const authorization = request.headers.get('Authorization');
  if (!authorization?.startsWith('Bearer ')) return reply('unauthorized',401);
  const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false }
  });
  const { data: { user }, error: authError } = await client.auth.getUser(authorization.slice(7));
  if (authError || !user) return reply('unauthorized',401);

  let bookingId: unknown;
  let payload: unknown;
  try {
    const raw = await request.text();
    if (raw.length > 2400) return reply('invalid_payload',400);
    ({ booking_id: bookingId, payload } = JSON.parse(raw));
  } catch {
    return reply('invalid_payload',400);
  }
  if (typeof bookingId !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(bookingId) ||
      typeof payload !== 'string' || !/^[\x20-\x7e]{12,2048}$/.test(payload)) return reply('invalid_payload',400);

  // The attachment's RLS policy restricts this operation to payment staff for its shop.
  const slip = await client.from('booking_slip_attachments').select('booking_id').eq('booking_id', bookingId).maybeSingle();
  if (slip.error || !slip.data) return reply('unavailable',403);
  const booking = await client.from('bookings').select('amount').eq('id', bookingId).maybeSingle();
  if (booking.error || !booking.data || !Number.isFinite(Number(booking.data.amount))) return reply('unavailable',403);
  const key = Deno.env.get('THUNDER_API_KEY')?.trim();
  if (!key) return reply('not_configured');

  try {
    return Response.json(await verifySlip(payload, key, Number(booking.data.amount)), { headers: cors });
  } catch {
    return reply('provider_unavailable');
  }
});
