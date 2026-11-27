import { createClient } from 'npm:@supabase/supabase-js@2.98.0';
import { decodeSlipQr } from './decode.ts';
import { verifySlip } from './thunder.ts';

const cors = {
  'Access-Control-Allow-Origin': 'https://homefriendmassage-boop.github.io',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store'
};
const json = (body: unknown, status = 200) => Response.json(body, { headers: cors, status });

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (request.method !== 'POST') return json({state:'unavailable'},405);
  let bookingId: unknown;
  let phone: unknown;
  let packageOrder: unknown;
  try {
    const raw = await request.text();
    if (raw.length > 500) return json({state:'unavailable'},400);
    ({ booking_id: bookingId, phone, package_order_id: packageOrder } = JSON.parse(raw));
  } catch {
    return json({state:'unavailable'},400);
  }
  const id = packageOrder ?? bookingId;
  if (typeof id !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id) ||
      (phone != null && (typeof phone !== 'string' || !/^[0-9\s-]{9,20}$/.test(phone)))) {
    return json({state:'unavailable'},400);
  }
  const url = Deno.env.get('SUPABASE_URL')!;
  const key = Deno.env.get('THUNDER_API_KEY')?.trim();
  let staffId = null;
  if (!phone || packageOrder) {
    const authorization = request.headers.get('Authorization');
    if (!authorization?.startsWith('Bearer ')) return json({state:'unavailable'},401);
    const client = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}
    });
    const { data, error } = await client.auth.getUser(authorization.slice(7));
    if (error || !data.user) return json({state:'unavailable'},401);
    staffId = data.user.id;
    if (packageOrder) {
      const {data: order,error: orderError}=await client.rpc('platform_package_verification_input',{p_order_id:id});
      if (orderError || !order) return json({state:'unavailable'},403);
      if (!key) return json({state:'not_configured'});
      const payload = decodeSlipQr(order.image);
      if (!payload) return json({state:'qr_unreadable'});
      try {
        const result = await verifySlip(payload,key);
        if (result.outcome !== 'provider_verified') return json({state:result.providerState || result.outcome});
        if (result.amount !== Number(order.amount)) return json({state:'amount_review',amount:result.amount});
        if (result.mobile !== order.mobile || !result.paidAt || Date.parse(result.paidAt)<Date.parse(order.created_at)
          || Date.parse(result.paidAt)>Date.now()+120000) return json({state:'receiver_review',amount:result.amount});
        return json({state:'package_match',amount:result.amount,reference:result.reference});
      } catch { return json({state:'retry'}); }
    }
  }
  if (!key) return json({state:'not_configured'});

  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const claim = await admin.rpc('claim_thunder_booking_slip', {
    p_booking_id: bookingId, p_phone: phone || null, p_staff: staffId
  });
  if (claim.error) {
    console.warn('Slip verification claim failed',{code:claim.error.code});
    return json({state:'verification_save_unavailable'});
  }
  if (!claim.data) return json({state:'unavailable'});
  if (claim.data.state !== 'claimed') return json(claim.data);
  const payload = decodeSlipQr(claim.data.image);
  if (payload) {
    const debit = await admin.rpc('consume_booking_slip_credit', { p_booking_id: bookingId });
    if (debit.error || !debit.data) {
      await admin.rpc('finish_booking_slip_checked', {
        p_booking_id: bookingId, p_outcome: 'retry', p_reference: null,
        p_amount: null, p_account: null, p_receiver_names: null, p_paid_at: null, p_promptpay: null
      });
      if (debit.error) console.warn('Slip verification credit check failed',{code:debit.error.code});
      return json({state:debit.error ? 'verification_save_unavailable' : 'no_credit'});
    }
  }
  let result;
  try {
    result = payload ? await verifySlip(payload, key, fetch, true) : { outcome:'qr_unreadable' };
  } catch (error) {
    result = {outcome:'retry',providerState:error instanceof Error && error.name === 'TimeoutError'
      ? 'provider_timeout' : 'provider_unavailable'};
  }
  if (payload && result.outcome === 'retry') {
    const refund = await admin.rpc('refund_booking_slip_credit', { p_booking_id: bookingId });
    if (refund.error) console.warn('Slip credit could not be refunded', refund.error.code);
  }
  const finished = await admin.rpc('finish_booking_slip_checked', {
    p_booking_id: bookingId, p_outcome: result.outcome, p_reference: result.reference ?? null,
    p_amount: result.amount ?? null, p_account: result.receiverAccount ?? null,
    p_receiver_names: result.receiverNames ?? null, p_paid_at: result.paidAt ?? null,
    p_promptpay: result.receiverPromptPay ?? null
  });
  if (finished.error) {
    console.warn('Slip verification save failed',{code:finished.error.code});
    return json({state:'verification_save_unavailable'});
  }
  if (result.providerState) {
    console.warn('Slip verification provider response',{state:result.providerState});
    return json({state:result.providerState});
  }
  if (finished.data?.state === 'receiver_review') {
    if (staffId && finished.data.reason === 'receiver_name_mismatch' && result.receiverNames?.length) {
      return json({...finished.data,receiver_names:result.receiverNames.slice(0,2).map(name=>name.slice(0,160))});
    }
    if (!result.receiverAccount && !result.receiverPromptPay && !finished.data.reason) return json({...finished.data,state:'receiver_account_unavailable'});
    if (!result.receiverNames?.length) return json({...finished.data,state:'receiver_name_unavailable'});
  }
  return json(finished.data);
});
