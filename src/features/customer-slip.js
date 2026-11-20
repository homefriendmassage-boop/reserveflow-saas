import { promptPayPayload } from './promptpay.js';

export function prepareSlipAttachment(client, booking, phone, mobile, onComplete) {
  const section = document.getElementById('bookingSlip');
  const file = document.getElementById('bookingSlipFile');
  const preview = document.getElementById('bookingSlipPreview');
  const status = document.getElementById('bookingSlipStatus');
  const submit = document.getElementById('bookingSlipSubmit');
  const skip = document.getElementById('bookingSlipSkip');
  const qr = document.getElementById('bookingPaymentQr');
  const amount = document.getElementById('bookingPaymentAmount');
  let image = '';
  let selection = 0;

  file.disabled = skip.disabled = false;
  submit.disabled = true;
  section.classList.remove('hidden');
  qr.replaceChildren();
  amount.textContent = new Intl.NumberFormat('th-TH', { style: 'currency', currency: 'THB' }).format(booking.amount);
  if (mobile) {
    try {
      new window.QRCode(qr, { text: promptPayPayload(mobile, Number(booking.amount)), width: 192, height: 192 });
    } catch {
      qr.textContent = 'เปิด QR ไม่ได้ กรุณาติดต่อร้านก่อนชำระเงิน';
    }
  } else {
    qr.textContent = 'ติดต่อร้านเพื่อขอข้อมูลชำระเงิน';
  }

  function close(message) {
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
    onComplete(message);
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
    if (!confirm('เริ่มรายการใหม่โดยยังไม่ส่งสลิป? รายการจองนี้จะยังอยู่และรอร้านยืนยัน')) return;
    close('ส่งคำขอจองแล้ว · ยังไม่ได้แนบสลิป');
  };

  submit.onclick = async () => {
    if (!image || submit.disabled) return;
    submit.disabled = file.disabled = skip.disabled = true;
    status.textContent = 'กำลังส่งสลิป…';
    try {
      const { error } = await client.rpc('attach_customer_booking_slip', {
        p_booking_id: booking.id, p_phone: phone, p_image: image
      });
      if (error) throw error;
      close('ส่งสลิปแล้ว · รอร้านตรวจ');
    } catch (error) {
      status.textContent = ({
        SLIP_BOOKING_UNAVAILABLE: 'รายการจองนี้รับสลิปไม่ได้แล้ว กรุณาติดต่อร้าน',
        SLIP_ALREADY_ATTACHED: 'รายการจองนี้มีสลิปแล้ว กรุณาติดต่อร้านหากต้องการเปลี่ยน'
      })[error.message] || (error.code === 'PGRST202' ? 'ร้านยังไม่ได้เปิดใช้การแนบสลิป' : 'ส่งรูปไม่ได้ กรุณาลองอีกครั้ง');
      submit.disabled = file.disabled = skip.disabled = false;
    }
  };

  section.focus();
}
