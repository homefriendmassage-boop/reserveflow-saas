import { createClient } from 'npm:@supabase/supabase-js@2.98.0';
import { getLinePairing, verifyLineSignature } from '../_shared/line.ts';

Deno.serve(async request => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const secret = Deno.env.get('LINE_CHANNEL_SECRET');
  if (!secret) return new Response('Not configured', { status: 503 });
  const body = await request.text();
  if (!await verifyLineSignature(body, request.headers.get('x-line-signature') || '', secret)) {
    return new Response('Invalid signature', { status: 401 });
  }
  try {
    const { events } = JSON.parse(body);
    if (!Array.isArray(events)) return new Response('Invalid events', { status: 400 });
    const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    for (const event of events) {
      const pairing = getLinePairing(event);
      if (!pairing) continue;
      const { error } = await client.rpc('redeem_line_pairing', pairing);
      if (error) throw error;
    }
    return new Response('OK');
  } catch {
    return new Response('Unable to process events', { status: 500 });
  }
});
