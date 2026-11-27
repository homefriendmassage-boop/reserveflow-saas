import { createClient } from 'npm:@supabase/supabase-js@2.98.0';

// Keep this entry point self-contained for direct Dashboard deployment.
const encoder = new TextEncoder();

function fixedTimeMatch(expected: string, supplied: string) {
  const left = encoder.encode(expected);
  const right = encoder.encode(supplied);
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index++) difference |= left[index] ^ right[index];
  return difference === 0;
}

async function availableBookingQr(payload: Record<string, string>) {
  if (payload.notification_stage === 'pending') return undefined;
  const qr = new URL('/functions/v1/promotion-qr', Deno.env.get('SUPABASE_URL')!);
  if (qr.protocol !== 'https:') return undefined;
  qr.searchParams.set('booking',payload.pass_token);
  try {
    const response = await fetch(qr, { redirect:'error', signal:AbortSignal.timeout(2500) });
    const available = response.ok && response.headers.get('content-type')?.split(';')[0] === 'image/png';
    await response.body?.cancel();
    if (available) return qr.href;
    console.warn('Booking QR unavailable for Flex',{status:response.status});
  } catch {
    console.warn('Booking QR preview failed for Flex');
  }
  return undefined;
}

function lineMessage(kind: string, payload: Record<string, string>, site: string, qrUrl?: string) {
  if (kind === 'booking_pass') {
    const pending = payload.notification_stage === 'pending';
    const link = new URL('booking-pass.html', site);
    link.hash = payload.pass_token;
    const row = (label: string, value: string) => ({
      type: 'box', layout: 'horizontal', spacing: 'sm', contents: [
        { type: 'text', text: label, color: '#526277', size: 'sm', flex: 3, wrap: true },
        { type: 'text', text: value, color: '#182440', size: 'sm', weight: 'bold', flex: 4, align: 'end', wrap: true }
      ]
    });
    return { type: 'flex', altText: (pending ? 'รับรายการจองแล้ว · รอยืนยัน · ' : 'ยืนยันการจองแล้ว · ') + payload.shop, contents: {
      type: 'bubble', size: 'mega',
      header: { type: 'box', layout: 'vertical', paddingAll: '20px', spacing: 'sm', backgroundColor: '#303C80', contents: [
        { type: 'text', text: 'ReserveFlow', color: '#DBE4FF', size: 'xs', weight: 'bold' },
        { type: 'text', text: pending ? 'รับรายการจองแล้ว · รอยืนยัน' : 'บัตรจอง · ยืนยันแล้ว', color: '#FFFFFF', size: 'xl', weight: 'bold', wrap: true },
        { type: 'text', text: payload.shop, color: '#EBEFFF', size: 'sm', wrap: true }
      ] },
      body: { type: 'box', layout: 'vertical', spacing: 'md', contents: [
        row('วันที่ใช้บริการ', payload.date),
        row('รายการที่จอง', payload.item),
        row('ช่วงเวลาที่จอง', payload.period),
        row('จำนวนชั่วโมง', Number(payload.hours) + ' ชั่วโมง'),
        { type: 'separator' },
        row('รวมค่าจอง / บริการ', new Intl.NumberFormat('th-TH', {style:'currency',currency:'THB'}).format(Number(payload.amount)))
      ] },
      ...(!pending && qrUrl ? { hero: { type:'image', url:qrUrl, size:'full', aspectRatio:'1:1', aspectMode:'fit' } } : {}),
      footer: { type: 'box', layout: 'vertical', contents: [
        { type: 'button', style: 'primary', color: '#404FBA', action: {
          type: 'uri', label: pending || qrUrl ? 'เปิดบัตรจอง' : 'เปิดบัตรและ QR เข้างาน', uri: link.href
        } }
      ] }
    } };
  }
  if (kind === 'daily_report') {
    const money = (value: string) => new Intl.NumberFormat('th-TH', {style:'currency',currency:'THB'}).format(Number(value));
    const row = (label: string, value: string) => ({ type:'box',layout:'horizontal',spacing:'sm',contents:[
      {type:'text',text:label,size:'sm',flex:3,wrap:true,color:'#526277'},
      {type:'text',text:String(value),size:'sm',flex:2,align:'end',weight:'bold',color:'#162E43',wrap:true}
    ] });
    return { type:'flex', altText:'รายงานประจำวัน · '+payload.date, contents:{
      type:'bubble',
      header:{type:'box',layout:'vertical',backgroundColor:'#172C43',paddingAll:'18px',spacing:'sm',contents:[
        {type:'text',text:'รายงานประจำวัน',weight:'bold',size:'lg',color:'#FFFFFF'},
        {type:'text',text:payload.shop_name+' · '+payload.date,size:'sm',color:'#D1E5F8',wrap:true}
      ]},
      body:{type:'box',layout:'vertical',spacing:'md',contents:[
        {type:'box',layout:'vertical',backgroundColor:'#EAF8F3',cornerRadius:'12px',paddingAll:'12px',spacing:'sm',contents:[
          {type:'text',text:'ยอดรับจากสลิปที่ตรวจผ่าน',size:'sm',color:'#24634F',wrap:true},
          {type:'text',text:money(payload.verified_amount),weight:'bold',size:'xl',color:'#11523E',wrap:true},
          {type:'text',text:'ตรวจรับเงิน '+payload.verified_count+' รายการ',size:'xs',color:'#24634F'}
        ]},
        row('ยอดจองที่ยืนยันตามวันใช้บริการ',money(payload.booking_amount)),
        {type:'separator'},
        row('รายการจองทั้งหมด',payload.bookings),
        row('ยืนยัน / เข้าใช้ / เสร็จ',payload.active),
        row('รอชำระ / รอตรวจ',payload.pending),
        row('ยกเลิก',payload.cancelled),
        {type:'text',text:'รอบรายงาน 06:00 ถึงก่อน 06:00 วันถัดไป ยอดรับนับตามเวลาโอนของสลิปที่ตรวจผ่าน',wrap:true,size:'xs',color:'#68758A'}
      ]},
      footer:{type:'box',layout:'vertical',contents:[
        {type:'button',action:{type:'uri',label:'เปิดหลังบ้าน',uri:new URL('merchant.html',site).href}}
      ]}
    }};
  }
  if (kind === 'referral') {
    const signup = new URL('merchant.html', site);
    signup.searchParams.set('signup', '1');
    if (payload.ref) signup.searchParams.set('ref', payload.ref);
    return { type: 'flex', altText: 'ReserveFlow · สมัครร้านค้า', contents: {
      type: 'bubble',
      body: { type: 'box', layout: 'vertical', spacing: 'md', contents: [
        { type: 'text', text: 'เปิดร้านบน ReserveFlow', weight: 'bold', wrap: true },
        { type: 'text', text: 'แนะนำโดย ' + payload.name, wrap: true },
        { type: 'text', text: 'ทดลองใช้ฟรี 7 วัน', wrap: true }
      ] },
      footer: { type: 'box', layout: 'vertical', contents: [
        { type: 'button', action: {type:'uri',label:'เปิดใบสมัคร',uri:signup.href} }
      ] }
    } };
  }
  if (kind === 'shop') {
    return {
      type: 'flex',
      altText: 'ReserveFlow · มีร้านค้าสมัครใหม่',
      contents: {
        type: 'bubble',
        body: { type: 'box', layout: 'vertical', spacing: 'md', contents: [
          { type: 'text', text: 'มีร้านค้าสมัครใหม่', weight: 'bold', wrap: true },
          { type: 'text', text: payload.name, wrap: true },
          { type: 'text', text: 'รหัสร้าน · ' + payload.slug, wrap: true, size: 'sm' }
        ] },
        footer: { type: 'box', layout: 'vertical', contents: [{
          type: 'button', action: { type: 'uri', label: 'เปิด Superadmin', uri: new URL('merchant.html#platformAdmin', site).href }
        }] }
      }
    };
  }
  const detail = (label: string, value: string) => ({
    type: 'box', layout: 'vertical', spacing: 'xs', contents: [
      { type: 'text', text: label, color: '#55627A', size: 'xs' },
      { type: 'text', text: value, color: '#182440', size: 'sm', weight: 'bold', wrap: true }
    ]
  });
  const amount = payload.amount == null ? [] : [
    detail('ยอดจอง', new Intl.NumberFormat('th-TH', { style: 'currency', currency: 'THB' }).format(Number(payload.amount)))
  ];
  return {
    type: 'flex',
    altText: 'ReserveFlow · มีรายการจองใหม่',
    contents: {
      type: 'bubble', size: 'mega',
      header: { type: 'box', layout: 'vertical', spacing: 'sm', paddingAll: '20px', backgroundColor: '#303C80', contents: [
        { type: 'text', text: 'ReserveFlow', size: 'xs', weight: 'bold', color: '#DBE4FF' },
        { type: 'text', text: 'มีรายการจองใหม่', size: 'xl', weight: 'bold', color: '#FFFFFF', wrap: true },
        { type: 'text', text: payload.name || 'ร้านค้า', size: 'sm', color: '#EBEFFF', wrap: true }
      ] },
      body: { type: 'box', layout: 'vertical', spacing: 'lg', contents: [
        detail(payload.category || 'รายการ', payload.resource || '—'),
        detail('วันและเวลาใช้บริการ', payload.date || '—'),
        ...amount,
        { type: 'separator', color: '#E1E6F3' },
        detail('เลขจอง', payload.booking_id || '—')
      ] },
      footer: { type: 'box', layout: 'vertical', contents: [
        { type: 'button', style: 'primary', color: '#404FBA', action: {
          type: 'uri', label: 'เปิดหลังบ้าน', uri: new URL('merchant.html', site).href
        } }
      ] }
    }
  };
}

const site = 'https://homefriendmassage-boop.github.io/reserveflow-saas/';

type Delivery = {
  id: string;
  target: string;
  kind: string;
  payload: Record<string, string>;
  lease_id: string;
  owner_scope: string;
  access_token: string | null;
};

Deno.serve(async request => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const workerSecret = Deno.env.get('LINE_WORKER_SECRET');
  const platformToken = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN');
  if (!workerSecret) return new Response('Not configured', { status: 503 });
  if (!fixedTimeMatch(workerSecret, request.headers.get('x-rf-worker-secret') || '')) {
    return new Response('Forbidden', { status: 403 });
  }
  const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data, error } = await client.rpc('claim_line_notifications_scoped', { p_platform_enabled: Boolean(platformToken) });
  if (error) return new Response('Could not claim jobs', { status: 500 });
  const results = await Promise.allSettled((data as Delivery[]).map(async job => {
    const accessToken = job.owner_scope === 'platform' ? platformToken : job.access_token;
    let status = accessToken ? 0 : 503;
    let delivered = false;
    try {
      if (accessToken) {
        const qrUrl = job.kind === 'booking_pass' ? await availableBookingQr(job.payload) : undefined;
        const response = await fetch('https://api.line.me/v2/bot/message/push', {
          method: 'POST',
          headers: {
            Authorization: 'Bearer ' + accessToken,
            'Content-Type': 'application/json',
            'X-Line-Retry-Key': job.id
          },
          body: JSON.stringify({ to: job.target, messages: [lineMessage(job.kind, job.payload, site, qrUrl)] }),
          signal: AbortSignal.timeout(10000)
        });
        status = response.status;
        delivered = response.ok || (status === 409 && response.headers.has('x-line-accepted-request-id'));
        await response.body?.cancel();
      }
    } catch {
      // A retry uses the same LINE retry key, even if the prior response was lost.
    }
    const result = await client.rpc('finish_line_notification', {
      p_id: job.id, p_lease_id: job.lease_id, p_status: status,
      p_delivered: delivered, p_retry: !status || status === 429 || status >= 500
    });
    if (result.error) throw result.error;
    return delivered;
  }));
  const failed = results.filter(result => result.status === 'rejected').length;
  return Response.json({
    handled: results.length,
    accepted: results.filter(result => result.status === 'fulfilled' && result.value).length,
    update_failures: failed
  }, { status: failed ? 500 : 200 });
});
