import { createClient } from 'npm:@supabase/supabase-js@2.98.0';

const cors = {
  'Access-Control-Allow-Origin': 'https://homefriendmassage-boop.github.io',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
};
const message = (error: string) => Response.json({ error }, { headers: cors });
const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (request.method !== 'POST') return new Response(null, { status: 405, headers: cors });
  try {
    const { id_token, payment } = await request.json();
    const slug = payment?.p_request?.p_shop_slug;
    if (typeof slug !== 'string' || !/^[a-z0-9-]{1,100}$/.test(slug) ||
      typeof id_token !== 'string' || !id_token || id_token.length > 4096 ||
      typeof payment.p_image !== 'string' || payment.p_image.length > 1450000 ||
      typeof payment.p_amount !== 'number' || !Number.isFinite(payment.p_amount)) return message('BOOKING_LINE_UNAVAILABLE');

    const { data: liffId, error: configError } = await client.rpc('shop_booking_liff', { p_shop_slug: slug });
    if (configError || typeof liffId !== 'string') return message('BOOKING_LINE_UNAVAILABLE');
    const channelId = liffId.split('-')[0];
    const verification = await fetch('https://api.line.me/oauth2/v2.1/verify', {
      method: 'POST',
      body: new URLSearchParams({ id_token, client_id: channelId }),
      signal: AbortSignal.timeout(8000), redirect: 'error',
    });
    if (!verification.ok) return message('BOOKING_LINE_EXPIRED');
    const identity = await verification.json();
    if (identity.iss !== 'https://access.line.me' || identity.aud !== channelId ||
      typeof identity.sub !== 'string' || !/^U[0-9a-f]{32}$/.test(identity.sub)) return message('BOOKING_LINE_EXPIRED');

    const { data, error } = await client.rpc('submit_verified_liff_booking', {
      p_request: payment.p_request,p_amount: payment.p_amount,p_image: payment.p_image,
      p_liff_id:liffId,p_line_user:identity.sub,
    });
    if (error) return message(error.message);
    return Response.json({ booking:data }, { headers:cors });
  } catch {
    return message('BOOKING_LINE_UNAVAILABLE');
  }
});
