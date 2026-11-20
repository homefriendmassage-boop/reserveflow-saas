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

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const cors = {
  'Access-Control-Allow-Origin': 'https://homefriendmassage-boop.github.io',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function serviceClient(url: string) {
  return createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
}

async function configure(request: Request, admin: ReturnType<typeof serviceClient>, url: string) {
  const reply = (result: string) => Response.json({ result }, { headers: cors });
  const authorization = request.headers.get('Authorization');
  if (!authorization?.startsWith('Bearer ')) return reply('unauthorized');
  try {
    const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false }
    });
    const { data: session, error: authError } = await caller.auth.getUser(authorization.slice(7));
    if (authError || !session.user) return reply('unauthorized');
    const { shop_id, secret, token } = await request.json();
    if (typeof shop_id !== 'string' || !uuid.test(shop_id) ||
      typeof secret !== 'string' || !/^[0-9a-f]{32}$/i.test(secret) ||
      typeof token !== 'string' || !/^[!-~]{20,4096}$/.test(token)) return reply('invalid_credentials');
    const { error: scopeError } = await caller.rpc('shop_line_channel_status', { p_shop_id: shop_id });
    if (scopeError) return reply('unauthorized');

    const response = await fetch('https://api.line.me/v2/bot/info', {
      headers: { Authorization: 'Bearer ' + token }, redirect: 'error', signal: AbortSignal.timeout(10000)
    });
    if (response.status === 401 || response.status === 403) return reply('invalid_token');
    if (!response.ok) return reply('line_unavailable');
    const bot = await response.json();
    const { error } = await admin.rpc('save_shop_line_channel', {
      p_shop_id: shop_id, p_owner: session.user.id, p_secret: secret, p_token: token,
      p_bot_id: bot.userId, p_bot_name: bot.displayName
    });
    return reply(error?.code === '23505' ? 'bot_already_linked' : error ? 'save_failed' : 'saved');
  } catch {
    return reply('save_failed');
  }
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const params = new URL(request.url).searchParams;
  const url = Deno.env.get('SUPABASE_URL')!;
  const client = serviceClient(url);
  if (params.get('configure') === '1') return configure(request, client, url);

  let shopId: string | null = null;
  let botId: string | null = null;
  let secret = Deno.env.get('LINE_CHANNEL_SECRET');
  if (params.has('shop')) {
    shopId = params.get('shop');
    if (!shopId || !uuid.test(shopId)) return new Response('Not found', { status: 404 });
    const { data, error } = await client.rpc('shop_line_webhook_credentials', { p_shop_id: shopId }).maybeSingle();
    if (error) return new Response('Unable to load channel', { status: 500 });
    if (!data) return new Response('Channel not configured', { status: 404 });
    const credentials = data as {bot_id: string; channel_secret: string};
    botId = credentials.bot_id;
    secret = credentials.channel_secret;
  }
  if (!secret) return new Response('Not configured', { status: 503 });
  const body = await request.text();
  if (!await verifyLineSignature(body, request.headers.get('x-line-signature') || '', secret)) {
    return new Response('Invalid signature', { status: 401 });
  }
  try {
    const { destination, events } = JSON.parse(body);
    if (!Array.isArray(events)) return new Response('Invalid events', { status: 400 });
    if (botId && botId !== destination) return new Response('Invalid LINE destination', { status: 403 });
    for (const event of events) {
      const pairing = getLinePairing(event);
      if (!pairing) continue;
      const result = shopId
        ? await client.rpc('redeem_scoped_line_pairing', { ...pairing, p_shop_id: shopId, p_bot_id: botId })
        : await client.rpc('redeem_line_pairing', pairing);
      if (result.error) throw result.error;
    }
    return new Response('OK');
  } catch {
    return new Response('Unable to process events', { status: 500 });
  }
});
