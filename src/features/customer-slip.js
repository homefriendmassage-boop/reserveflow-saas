import { bindSlipImage } from './slip-image-picker.js';
import { checkThunderSlip, thunderStatus } from './thunder-slip.js?v=recipient-check';

export function prepareSlipAttachment(client, draft, sendPayment, onComplete) {
  const section = document.getElementById('bookingSlip');
  const file = document.getElementById('bookingSlipFile');
  const choose = document.getElementById('bookingSlipChoose');
  const preview = document.getElementById('bookingSlipPreview');
  const status = document.getElementById('bookingSlipStatus');
  const submit = document.getElementById('bookingSlipSubmit');
  const skip = document.getElementById('bookingSlipSkip');
  const qr = document.getElementById('bookingPaymentQr');
  const amount = document.getElementById('bookingPaymentAmount');
  const { booking, label, payload } = draft;
  const offer = booking.promotion;
  document.getElementById('bookingPaymentSelection').textContent = label
    + (offer?.gift ? ' · ของแถม ' + offer.gift + ' (1 สิทธิ์)' : '')
    + (offer?.held_until ? ' · ส่งสลิปก่อน '+new Date(offer.held_until).toLocaleString('th-TH',{
      timeZone:'Asia/Bangkok',hour:'2-digit',minute:'2-digit'
    })+' น.' : '');
  let image = '';
  const resetPicker = bindSlipImage(file, choose, preview, (selected, error = '') => {
    image = selected;
    status.textContent = error;
    submit.disabled = !image;
  });

  file.disabled = choose.disabled = skip.disabled = false;
  submit.disabled = true;
  section.classList.remove('hidden');
  qr.replaceChildren();
  amount.textContent = new Intl.NumberFormat('th-TH', { style: 'currency', currency: 'THB' }).format(booking.amount);
  qr.classList.toggle('hidden', !booking.qr);
  if (booking.qr) {
    try {
      new window.QRCode(qr, { text: booking.qr, width: 192, height: 192 });
      qr.removeAttribute('title');
    } catch {
      qr.textContent = 'เปิด QR ไม่ได้ กรุณาติดต่อร้านก่อนชำระเงิน';
    }
  }
  const bank = booking.bank_account;
  const bankDetails = document.getElementById('bookingPaymentBank');
  const bankNumber = document.getElementById('bookingPaymentBankNumber');
  const bankStatus = document.getElementById('bookingPaymentBankStatus');
  bankDetails.classList.toggle('hidden', !bank);
  bankStatus.textContent = '';
  if (bank) {
    document.getElementById('bookingPaymentBankHolder').textContent = bank.bank_name + ' · ' + bank.holder_name;
    bankNumber.value = bank.account_number;
    document.getElementById('bookingPaymentBankCopy').onclick = async () => {
      try {
        await navigator.clipboard.writeText(bankNumber.value);
        bankStatus.textContent = 'คัดลอกเลขบัญชีแล้ว';
      } catch {
        bankNumber.select();
        bankStatus.textContent = 'เลือกเลขบัญชีแล้ว กดคัดลอกจากเบราว์เซอร์';
      }
    };
  }

  function close(message, bookingResult) {
    resetPicker();
    file.onchange = choose.onclick = submit.onclick = skip.onclick = null;
    file.disabled = choose.disabled = false;
    submit.disabled = true;
    skip.disabled = false;
    section.classList.add('hidden');
    status.textContent = '';
    onComplete(message, bookingResult);
  }

  skip.onclick = () => {
    if (!confirm('ยกเลิกฉบับร่าง? หากโอนแล้ว ให้แนบสลิปหรือติดต่อร้านก่อน')) return;
    close('ยกเลิกฉบับร่างแล้ว');
  };

  submit.onclick = async () => {
    if (!image || submit.disabled) return;
    submit.disabled = file.disabled = choose.disabled = skip.disabled = true;
    status.textContent = 'กำลังส่งสลิป…';
    try {
      const saved = await sendPayment(image);
      status.textContent = 'ส่งสลิปแล้ว · กำลังตรวจสลิป…';
      try {
        close(thunderStatus(await checkThunderSlip(client, saved.id, payload.p_phone)), saved);
      } catch {
        close('ส่งสลิปแล้ว · รอแอดมินตรวจ', saved);
      }
    } catch (error) {
      status.textContent = ({
        PROMOTION_QUOTE_EXPIRED: 'หมดเวลาจองสิทธิ์ หากโอนแล้ว กรุณาติดต่อร้านพร้อมสลิป',
        PROMOTION_QUOTE_MISMATCH: 'ข้อมูลโปรโมชั่นเปลี่ยน หากโอนแล้ว กรุณาติดต่อร้านพร้อมสลิป',
        BOOKING_LINE_FRIEND_REQUIRED: 'กรุณาเพิ่มเพื่อน LINE OA ของร้าน แล้วกลับมาแนบสลิปเดิมอีกครั้ง',
        BOOKING_LINE_EXPIRED: 'การเชื่อม LINE หมดอายุ เปิดหน้าจองใหม่จากเมนู LINE แล้วแนบสลิปเดิมอีกครั้ง',
        BOOKING_LINE_UNAVAILABLE: 'เชื่อม LINE ไม่สำเร็จ กรุณาลองส่งอีกครั้งโดยใช้สลิปเดิม',
        BOOKING_LINE_ALREADY_LINKED: 'รายการนี้เชื่อมกับ LINE บัญชีอื่นแล้ว กรุณาติดต่อร้าน',
        BOOKING_PAYMENT_UNAVAILABLE: 'ร้านยังรับชำระรายการนี้ไม่ได้ กรุณาติดต่อร้าน',
        BOOKING_QUOTE_MISMATCH: 'ฉบับร่างหมดอายุหรือข้อมูลเปลี่ยน หากโอนแล้วกรุณาติดต่อร้านพร้อมสลิป',
        BOOKING_RESOURCE_IN_USE: 'จุดนี้ยังมีผู้ใช้บริการ หากโอนแล้วกรุณาติดต่อร้านพร้อมสลิป',
        BOOKING_SLOT_TAKEN: 'ช่วงเวลานี้ถูกจองแล้ว หากโอนแล้วกรุณาติดต่อร้านพร้อมสลิป',
        INVALID_BOOKING_DATE: 'เลยเวลาที่เลือกแล้ว หากโอนแล้วกรุณาติดต่อร้านพร้อมสลิป',
        BOOKING_PRICE_CHANGED: 'ยอดจองเปลี่ยนแล้ว หากโอนแล้วกรุณาติดต่อร้านพร้อมสลิป',
        SLIP_BOOKING_UNAVAILABLE: 'รายการจองนี้รับสลิปไม่ได้แล้ว กรุณาติดต่อร้าน',
        SLIP_ALREADY_ATTACHED: 'รายการจองนี้มีสลิปแล้ว กรุณาติดต่อร้านหากต้องการเปลี่ยน'
      })[error.message] || (error.code === 'PGRST202' ? 'ร้านยังไม่ได้เปิดใช้การแนบสลิป' : 'ส่งรูปไม่ได้ กรุณาลองอีกครั้ง');
      submit.disabled = file.disabled = choose.disabled = skip.disabled = false;
    }
  };

  section.focus();
}
