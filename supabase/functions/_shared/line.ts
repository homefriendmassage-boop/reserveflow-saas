const encoder = new TextEncoder();
const pairingPattern = /^RF ([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})$/i;

export async function verifyLineSignature(body: string, signature: string, secret: string) {
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

export function getLinePairing(event: LineEvent) {
  if (event?.type !== 'message' || event.message?.type !== 'text') return null;
  const code = pairingPattern.exec(event.message.text?.trim() || '')?.[1];
  const type = event.source?.type;
  const target = type === 'group' ? event.source?.groupId : event.source?.userId;
  if (!code || !target || (type !== 'user' && type !== 'group')) return null;
  return { p_code: code, p_target: target, p_target_type: type };
}

export function fixedTimeMatch(expected: string, supplied: string) {
  const left = encoder.encode(expected);
  const right = encoder.encode(supplied);
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index++) difference |= left[index] ^ right[index];
  return difference === 0;
}

export function lineMessage(kind: string, payload: Record<string, string>, site: string) {
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
          {type:'text',text:'ยอดรับที่ Thunder ยืนยัน',size:'sm',color:'#24634F',wrap:true},
          {type:'text',text:money(payload.verified_amount),weight:'bold',size:'xl',color:'#11523E',wrap:true},
          {type:'text',text:'ตรวจรับเงิน '+payload.verified_count+' รายการ',size:'xs',color:'#24634F'}
        ]},
        row('ยอดจองที่ยืนยันตามวันใช้บริการ',money(payload.booking_amount)),
        {type:'separator'},
        row('รายการจองทั้งหมด',payload.bookings),
        row('ยืนยัน / เข้าใช้ / เสร็จ',payload.active),
        row('รอชำระ / รอตรวจ',payload.pending),
        row('ยกเลิก',payload.cancelled),
        {type:'text',text:'ยอดรับนับตามวันโอนที่ Thunder ยืนยันพร้อมเวลาโอน',wrap:true,size:'xs',color:'#68758A'}
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
  return {
    type: 'text',
    text: [
      'ReserveFlow · มีรายการจองใหม่', payload.name, 'รายการ ' + payload.resource,
      'เวลา ' + payload.date + ' (' + payload.time_zone + ')',
      'เลขจอง ' + payload.booking_id, new URL('merchant.html', site).href
    ].join('\n')
  };
}
