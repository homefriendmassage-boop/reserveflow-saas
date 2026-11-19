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
