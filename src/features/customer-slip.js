import { checkThunderSlip, thunderStatus } from './thunder-slip.js?v=team-slip-credits-1';

export function prepareSlipAttachment(client, draft, sendPayment, onComplete) {
  const section = document.getElementById('bookingSlip');
  const file = document.getElementById('bookingSlipFile');
  const preview = document.getElementById('bookingSlipPreview');
  const status = document.getElementById('bookingSlipStatus');
  const submit = document.getElementById('bookingSlipSubmit');
  const skip = document.getElementById('bookingSlipSkip');
  const qr = document.getElementById('bookingPaymentQr');
  const amount = document.getElementById('bookingPaymentAmount');
  const { booking, label, payload } = draft;
  document.getElementById('bookingPaymentSelection').textContent = label;
  let image = '';
  let selection = 0;

  file.disabled = skip.disabled = false;
  submit.disabled = true;
  section.classList.remove('hidden');
  qr.replaceChildren();
  amount.textContent = new Intl.NumberFormat('th-TH', { style: 'currency', currency: 'THB' }).format(booking.amount);
  try {
    new window.QRCode(qr, { text: booking.qr, width: 192, height: 192 });
  } catch {
    qr.textContent = 'เปิด QR ไม่ได้ กรุณาติดต่อร้านก่อนชำระเงิน';
  }

  function close(message, bookingResult) {
    selection++;
    file.onchange = submit.onclick = skip.onclick = null;
    file.value = '';
    file.disabled = false;
    submit.disabled = true;
    skip.disabled = false;
    preview.removeAttribute('src');
    preview.classList.add('hidden');
    section.classList.add('hidden');
    status.textContent = '';
    onComplete(message, bookingResult);
  }

  file.onchange = () => {
    const current = ++selection;
    image = '';
    submit.disabled = true;
    preview.classList.add('hidden');
    preview.removeAttribute('src');
    status.textContent = '';
    const chosen = file.files[0];
    if (!chosen) return;
    if (chosen.size > 1024 * 1024 || !['image/jpeg','image/png','image/webp'].includes(chosen.type)) {
      file.value = '';
      status.textContent = 'กรุณาเลือกไฟล์ JPG, PNG หรือ WebP ขนาดไม่เกิน 1 MB';
      return;
    }
    const reader = new FileReader();
    reader.onloadend = () => {
      if (current !== selection) return;
      if (reader.error) {
        status.textContent = 'อ่านรูปไม่ได้ กรุณาเลือกภาพใหม่';
        return;
      }
      image = reader.result;
      preview.src = image;
      preview.classList.remove('hidden');
      submit.disabled = false;
    };
    reader.readAsDataURL(chosen);
  };

  skip.onclick = () => {
    if (!confirm('ยกเลิกฉบับร่าง? หากโอนแล้ว ให้แนบสลิปหรือติดต่อร้านก่อน')) return;
    close('ยกเลิกฉบับร่างแล้ว');
  };

  submit.onclick = async () => {
    if (!image || submit.disabled) return;
    submit.disabled = file.disabled = skip.disabled = true;
    status.textContent = 'กำลังส่งสลิป…';
    try {
      const saved = await sendPayment(image);
      status.textContent = 'ส่งสลิปแล้ว · กำลังตรวจด้วย Thunder…';
      try {
        close(thunderStatus(await checkThunderSlip(client, saved.id, payload.p_phone)), saved);
      } catch {
        close('ส่งสลิปแล้ว · รอแอดมินตรวจ', saved);
      }
    } catch (error) {
      status.textContent = ({
        BOOKING_PAYMENT_UNAVAILABLE: 'ร้านยังรับชำระรายการนี้ไม่ได้ กรุณาติดต่อร้าน',
        BOOKING_SLOT_TAKEN: 'ช่วงเวลานี้ถูกจองแล้ว หากโอนแล้วกรุณาติดต่อร้านพร้อมสลิป',
        INVALID_BOOKING_DATE: 'เลยเวลาที่เลือกแล้ว หากโอนแล้วกรุณาติดต่อร้านพร้อมสลิป',
        BOOKING_PRICE_CHANGED: 'ยอดจองเปลี่ยนแล้ว หากโอนแล้วกรุณาติดต่อร้านพร้อมสลิป',
        SLIP_BOOKING_UNAVAILABLE: 'รายการจองนี้รับสลิปไม่ได้แล้ว กรุณาติดต่อร้าน',
        SLIP_ALREADY_ATTACHED: 'รายการจองนี้มีสลิปแล้ว กรุณาติดต่อร้านหากต้องการเปลี่ยน'
      })[error.message] || (error.code === 'PGRST202' ? 'ร้านยังไม่ได้เปิดใช้การแนบสลิป' : 'ส่งรูปไม่ได้ กรุณาลองอีกครั้ง');
      submit.disabled = file.disabled = skip.disabled = false;
    }
  };

  section.focus();
}
