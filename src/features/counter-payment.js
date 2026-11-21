import { bindSlipImage } from './slip-image-picker.js';

export async function counterPaymentRpc(client, method, args) {
  const { data, error } = await client.rpc(method, args);
  if (error) throw error;
  return data;
}

export function renderCounterPayment(client, panel, payment, token, submitted) {
  panel.replaceChildren();
  panel.classList.toggle('hidden', !payment || (!payment.can_pay && !payment.has_slip));
  if (!payment || panel.classList.contains('hidden')) return;
  const text = (tag, content) => {
    const item = document.createElement(tag);
    item.textContent = content;
    return item;
  };
  panel.append(text('h3','ชำระค่าจอง'),
    text('p',new Intl.NumberFormat('th-TH',{style:'currency',currency:'THB'}).format(payment.amount)));
  if (payment.has_slip) {
    panel.append(text('p','แนบสลิปแล้ว · ตรวจสถานะได้จากบัตรจอง'));
    return;
  }
  if (payment.qr) {
    const qr = text('div','');
    qr.className = 'booking-pass-qr';
    qr.setAttribute('aria-label','QR พร้อมเพย์สำหรับชำระเงิน');
    new window.QRCode(qr,{text:payment.qr,width:192,height:192});
    qr.removeAttribute('title');
    panel.append(qr);
    const canvas = qr.querySelector('canvas');
    if (canvas) {
      const save = text('a','บันทึกรูป QR เพื่อเปิดในแอปธนาคาร');
      save.className = 'btn soft small';
      save.download = 'reserveflow-payment.png';
      save.href = canvas.toDataURL('image/png');
      panel.append(save);
    }
  }
  const bank = payment.bank_account;
  if (bank) {
    const number = text('input','');
    number.value = bank.account_number;
    number.readOnly = true;
    const label = text('label',bank.bank_name+' · '+bank.holder_name);
    label.className='field';
    label.append(number);
    const copy = text('button','คัดลอกเลขบัญชี');
    copy.type = 'button';
    copy.className = 'btn soft small';
    copy.onclick = async () => {
      try { await navigator.clipboard.writeText(number.value); copy.textContent = 'คัดลอกแล้ว'; }
      catch { number.focus(); number.select(); }
    };
    panel.append(label,copy);
  }
  if (!payment.qr && !bank) {
    panel.append(text('p','ร้านยังไม่มีช่องทางรับเงิน กรุณาติดต่อร้านก่อนโอน'));
    return;
  }
  const input = text('input','');
  input.type = 'file';
  input.accept = 'image/jpeg,image/png,image/webp';
  input.hidden = true;
  const choose = text('button','เลือกรูปสลิป');
  const send = text('button','ส่งสลิป');
  choose.type = send.type = 'button';
  choose.className = 'btn soft small';
  send.className = 'btn primary small';
  send.disabled = true;
  const preview = text('img','');
  preview.className = 'booking-slip-image hidden';
  preview.alt = 'ตัวอย่างสลิปที่จะส่ง';
  const status = text('p','');
  status.setAttribute('role','status');
  let image = '';
  bindSlipImage(input,choose,preview,(value,error = '') => {
    image = value;
    status.textContent = error;
    send.disabled = !image;
  });
  send.onclick = async () => {
    if (!image || send.disabled) return;
    send.disabled = choose.disabled = true;
    status.textContent = 'กำลังส่งสลิป…';
    try {
      await counterPaymentRpc(client,'attach_counter_booking_slip',{p_token:token,p_image:image});
      await submitted();
    } catch (error) {
      status.textContent = ({
        SLIP_ALREADY_ATTACHED:'รายการนี้มีสลิปแล้ว กรุณาตรวจสถานะ',
        SLIP_BOOKING_UNAVAILABLE:'รายการนี้หมดเวลารับสลิป กรุณาติดต่อร้าน'
      })[error.message] || 'ส่งสลิปไม่สำเร็จ กรุณาลองอีกครั้ง';
      send.disabled = choose.disabled = false;
    }
  };
  const actions = text('div','');
  actions.className = 'inline-actions';
  actions.append(choose,send);
  panel.append(input,preview,actions,status);
}

export async function openMerchantCounterPayment(client, panel, token) {
  const payment = await counterPaymentRpc(client,'counter_booking_payment_details',{p_token:token});
  if (!payment || (!payment.can_pay && !payment.has_slip)) throw new Error('SLIP_BOOKING_UNAVAILABLE');
  const link = new URL('./booking-pass.html',location.href);
  link.hash = token;
  const title = document.createElement('h3');
  title.textContent = 'ให้ลูกค้าสแกน QR เปิดหน้าชำระเงิน';
  const qr = document.createElement('div');
  qr.className = 'booking-pass-qr';
  qr.setAttribute('aria-label','QR เปิดหน้าชำระเงินบนเครื่องลูกค้า');
  new window.QRCode(qr,{text:link.href,width:192,height:192});
  qr.removeAttribute('title');
  const help = document.createElement('p');
  help.textContent = payment.has_slip
    ? 'ลูกค้าแนบสลิปแล้ว สแกน QR เพื่อตรวจสถานะบนเครื่องลูกค้าได้'
    : 'ลูกค้าชำระเงินและแนบสลิปจากหน้าที่เปิดบนเครื่องตัวเอง';
  panel.replaceChildren(title,qr,help);
  panel.classList.remove('hidden');
  panel.scrollIntoView({block:'nearest'});
}
