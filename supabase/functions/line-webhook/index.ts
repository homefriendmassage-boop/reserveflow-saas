import { createClient } from 'npm:@supabase/supabase-js@2.98.0';
// Keep this entry point self-contained for direct Dashboard deployment.
const encoder = new TextEncoder();
const pairingPattern = /^RF ([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})$/i;

async function verifyLineSignature(body: string, signature: string, secret: string) {
  try {
    const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
    const bytes = Uint8Array.from(atob(signature), character => character.charCodeAt(0));
    return await crypto.subtle.verify('HMAC', key, bytes, encoder.encode(body));
  } catch {
    return false;
  }
}

type LineEvent = {
  type?: string;
  message?: { type?: string; text?: string };
  source?: { type?: string; userId?: string; groupId?: string };
};

function getLinePairing(event: LineEvent) {
  if (event?.type !== 'message' || event.message?.type !== 'text') return null;
  const code = pairingPattern.exec(event.message.text?.trim() || '')?.[1];
  const type = event.source?.type;
  const target = type === 'group' ? event.source?.groupId : event.source?.userId;
  if (!code || !target || (type !== 'user' && type !== 'group')) return null;
  return { p_code: code, p_target: target, p_target_type: type };
}

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
