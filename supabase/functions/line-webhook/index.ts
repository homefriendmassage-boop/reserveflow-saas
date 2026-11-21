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

async function configure(request: Request, admin: ReturnType<typeof serviceClient>, url: string, linkKind: 'group' | 'user' | null) {
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
    const { shop_id, secret, token, group_id, user_id } = await request.json();
    if (typeof shop_id !== 'string' || !uuid.test(shop_id)) return reply('invalid_credentials');
    const { error: scopeError } = await caller.rpc('shop_line_channel_status', { p_shop_id: shop_id });
    if (scopeError) return reply('unauthorized');
    if (linkKind) {
      const group = linkKind === 'group';
      const target = group ? group_id : user_id;
      const pattern = group ? /^C[0-9a-f]{32}$/ : /^U[0-9a-f]{32}$/;
      if (typeof target !== 'string' || !pattern.test(target)) return reply('invalid_target');
      const { data, error } = await admin.rpc('shop_line_group_credentials', {
        p_shop_id: shop_id, p_owner: session.user.id
      }).maybeSingle();
      const credentials = data as { bot_id: string; access_token: string } | null;
      if (error || !credentials?.access_token) return reply('group_not_configured');
      const path = group ? '/group/' + target + '/summary' : '/profile/' + target;
      const response = await fetch('https://api.line.me/v2/bot' + path, {
        headers: { Authorization: 'Bearer ' + credentials.access_token },
        redirect: 'error', signal: AbortSignal.timeout(10000)
      });
      if (!response.ok) return reply(response.status === 404 ? 'group_not_found'
        : [401,403].includes(response.status) ? 'group_access_denied' : 'line_unavailable');
      const result = await response.json();
      if ((group ? result.groupId : result.userId) !== target) return reply('group_not_found');
      const args = { p_shop_id: shop_id, p_owner: session.user.id, p_bot_id: credentials.bot_id };
      const linked = group
        ? await admin.rpc('link_verified_shop_line_group', { ...args, p_group_id: target })
        : await admin.rpc('link_verified_shop_line_user', { ...args, p_user_id: target });
      return reply(linked.error ? 'save_failed' : 'linked');
    }
    if (typeof secret !== 'string' || !/^[0-9a-f]{32}$/i.test(secret) ||
      typeof token !== 'string' || !/^[!-~]{20,4096}$/.test(token)) return reply('invalid_credentials');

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

async function saveCustomerProfile(
  client: ReturnType<typeof serviceClient>, shop: string, bot: string, user: string
) {
  if (!/^U[0-9a-f]{32}$/.test(user)) return;
  const credentials = await client.rpc('shop_customer_profile_token', { p_shop_id: shop, p_bot: bot });
  if (credentials.error || !credentials.data) return;
  const response = await fetch('https://api.line.me/v2/bot/profile/' + user, {
    headers: { Authorization: 'Bearer ' + credentials.data },
    redirect: 'error', signal: AbortSignal.timeout(3500)
  });
  if (!response.ok) { await response.body?.cancel(); return; }
  const profile = await response.json();
  if (profile.userId !== user) return;
  await client.rpc('save_shop_line_customer', {
    p_shop_id: shop, p_bot: bot, p_user: user,
    p_name: typeof profile.displayName === 'string' ? profile.displayName : null,
    p_picture: typeof profile.pictureUrl === 'string' ? profile.pictureUrl : null
  });
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const params = new URL(request.url).searchParams;
  const url = Deno.env.get('SUPABASE_URL')!;
  const client = serviceClient(url);
  const linkKind = params.get('link-group') === '1' ? 'group' : params.get('link-user') === '1' ? 'user' : null;
  if (linkKind || params.get('configure') === '1') return configure(request, client, url, linkKind);

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
      const incoming = event as LineEvent;
      const command = shopId && incoming?.type === 'message' && incoming.message?.type === 'text'
        && incoming.source?.type === 'user' ? incoming.message.text?.trim() : null;
      if (command === 'ลงทะเบียนลูกค้า' && shopId && botId && incoming.source?.userId) {
        await saveCustomerProfile(client, shopId, botId, incoming.source.userId);
        continue;
      }
      if (command?.startsWith('บัตร ')) {
        const code = command.slice('บัตร '.length);
        if (uuid.test(code)) {
          const linked = await client.rpc('link_customer_booking_pass', {
            p_token: code, p_shop_id: shopId, p_bot: botId, p_user: incoming.source?.userId
          });
          if (linked.error) throw linked.error;
          if (shopId && botId && incoming.source?.userId) {
            await saveCustomerProfile(client, shopId, botId, incoming.source.userId).catch(() => {});
          }
        }
        continue;
      }
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
