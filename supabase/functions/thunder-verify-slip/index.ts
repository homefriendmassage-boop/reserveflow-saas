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
  let packageOrder: unknown;
  let creditOrder: unknown;
  try {
    const raw = await request.text();
    if (raw.length > 500) return json({state:'unavailable'},400);
    ({ booking_id: bookingId, phone, package_order_id: packageOrder, credit_order_id: creditOrder } = JSON.parse(raw));
  } catch {
    return json({state:'unavailable'},400);
  }
  if (packageOrder != null && creditOrder != null) return json({state:'unavailable'},400);
  const kind = packageOrder != null ? 'subscription' : creditOrder != null ? 'credits' : null;
  const id = packageOrder ?? creditOrder ?? bookingId;
  if (typeof id !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id) ||
      (phone != null && (typeof phone !== 'string' || !/^[0-9\s-]{9,20}$/.test(phone)))) {
    return json({state:'unavailable'},400);
  }
  const url = Deno.env.get('SUPABASE_URL')!;
  const key = Deno.env.get('THUNDER_API_KEY')?.trim();
  let staffId = null;
  if (!phone || kind) {
    const authorization = request.headers.get('Authorization');
    if (!authorization?.startsWith('Bearer ')) return json({state:'unavailable'},401);
    const client = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}
    });
    const { data, error } = await client.auth.getUser(authorization.slice(7));
    if (error || !data.user) return json({state:'unavailable'},401);
    staffId = data.user.id;
    if (kind) {
      const admin = createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
      const {data: claim,error: claimError} = await admin.rpc('claim_platform_slip',{
        p_kind:kind,p_order_id:id,p_actor:staffId
      });
      if (claimError || !claim) return json({state:'unavailable'},claimError?.code==='42501' ? 403 : 503);
      if (claim.state!=='claimed') return json(claim);
      let outcome = 'not_configured';
      let reference = null;
      let amount = null;
      let receiver = null;
      let holder = null;
      let paidAt = null;
      if (key) {
        try {
          const payload = decodeSlipQr(claim.image);
          if (payload) {
            const result = await verifySlip(payload,key);
            outcome = result.providerState || result.outcome;
            reference = result.reference || null;
            amount = result.amount ?? null;
            receiver = result.bankAccount || null;
            holder = result.bankHolder || null;
            paidAt = result.paidAt || null;
          } else outcome = 'qr_unreadable';
        } catch { outcome = 'retry'; }
      }
      const {data: result,error: finishError} = await admin.rpc('finish_platform_slip',{
        p_kind:kind,p_order_id:id,p_lease:claim.lease,p_outcome:outcome,p_reference:reference,
        p_amount:amount,p_receiver:receiver,p_paid_at:paidAt,p_holder:holder
      });
      return json(finishError ? {state:'retry'} : result);
    }
  }
  if (!key) return json({state:'not_configured'});

  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const claim = await admin.rpc('claim_thunder_booking_slip', {
    p_booking_id: bookingId, p_phone: phone || null, p_staff: staffId
  });
  if (claim.error || !claim.data) return json({state:'unavailable'});
  if (claim.data.state !== 'claimed') return json(claim.data);
  const payload = decodeSlipQr(claim.data.image);
  if (payload) {
    const debit = await admin.rpc('consume_booking_slip_credit', { p_booking_id: bookingId });
    if (debit.error || !debit.data) {
      await admin.rpc('finish_thunder_booking_slip', {
        p_booking_id: bookingId, p_outcome: 'retry', p_reference: null,
        p_amount: null, p_mobile: null, p_paid_at: null
      });
      return json({state:debit.error ? 'retry' : 'no_credit'});
    }
  }
  let result;
  try {
    result = payload ? await verifySlip(payload, key) : { outcome:'qr_unreadable' };
  } catch {
    result = {outcome:'retry'};
  }
  if (payload && result.outcome === 'retry') {
    const refund = await admin.rpc('refund_booking_slip_credit', { p_booking_id: bookingId });
    if (refund.error) console.warn('Slip credit could not be refunded', refund.error.code);
  }
  const finished = await admin.rpc('finish_thunder_booking_slip', {
    p_booking_id: bookingId, p_outcome: result.outcome, p_reference: result.reference ?? null,
    p_amount: result.amount ?? null, p_mobile: result.mobile ?? null, p_paid_at: result.paidAt ?? null
  });
  return json(finished.error ? {state:'unavailable'} : result.providerState ? {state:result.providerState} : finished.data);
});
