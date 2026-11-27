import { counterPaymentRpc, renderCounterPayment } from './counter-payment.js';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
import { passStatus, passTokenPattern, renderPassDetails } from './booking-pass-details.js';

const get = id => document.getElementById(id);
const token = location.hash.slice(1);
const status = get('passStatus');
const showQr = get('passShowQr');
const refresh = get('passRefresh');
const qr = get('passQr');
const lineStatus = get('passLineStatus');
const feedback = get('passFeedback');
const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: false, detectSessionInUrl: false, autoRefreshToken: false }
});

async function copy(value) {
  try {
    await navigator.clipboard.writeText(value);
    feedback.textContent = 'คัดลอกแล้ว';
  } catch {
    feedback.textContent = 'คัดลอกลิงก์จากแถบที่อยู่ได้เลย';
  }
}

async function load() {
  refresh.disabled = true;
  try {
    const [{ data, error }, payment, voucher] = await Promise.all([
      client.rpc('get_customer_booking_pass',{p_token:token}),
      counterPaymentRpc(client,'counter_booking_payment_details',{p_token:token}).catch(() => null),
      counterPaymentRpc(client,'rf_booking_voucher',{p_pass:token}).catch(() => null)
    ]);
    if (error) throw error;
    if (!data) {
      status.textContent = 'เปิดบัตรไม่ได้ กรุณาตรวจลิงก์หรือติดต่อร้าน';
      return;
    }
    get('passShop').textContent = data.shop;
    status.textContent = passStatus(data);
    renderPassDetails(get('passDetails'), data);
    get('passCopyLink').classList.remove('hidden');
    const pending = ['pending_payment','pending_confirm','slip_review'].includes(data.status) && !data.expired;
    showQr.classList.toggle('hidden', !data.scan_token);
    showQr.textContent = pending ? 'แสดง QR ให้ร้านตรวจสอบ' : 'แสดง QR เข้างาน';
    get('passQrHelp').textContent = pending
      ? (data.scan_token ? 'พนักงานสแกนเพื่อเปิดดูรายการได้ เช็กอินได้หลังยืนยันการจอง'
        : 'QR เข้างานจะแสดงหลังร้านยืนยันการจอง')
      : data.status === 'confirmed' && data.scan_token
        ? 'หากจองโปรของแถม คูปองจะขึ้นหลังร้านยืนยันเช็กอิน' : '';
    if (!data.scan_token) {
      qr.replaceChildren();
      qr.classList.add('hidden');
    }
    showQr.onclick = () => {
      const link = new URL('./merchant.html', location.href);
      link.hash = 'scan=' + data.scan_token;
      qr.replaceChildren();
      new window.QRCode(qr, { text: link.href, width: 240, height: 240 });
      qr.classList.remove('hidden');
    };
    const giftPass = get('bookingGiftPass');
    giftPass.classList.toggle('hidden',!voucher);
    if (voucher) giftPass.href = './promotion-pass.html#' + encodeURIComponent(voucher);
    const couponStatus = {
      check_in_required: 'คูปองของแถมจะขึ้นหลังร้านยืนยันเช็กอิน',
      payment_review: 'เช็กอินแล้ว · คูปองยังรอตรวจยืนยันยอดชำระ กรุณาติดต่อร้าน',
      queued: 'คูปองพร้อมใช้ในบัตรแล้ว · กำลังรอส่งทาง LINE',
      failed: 'ส่งคูปองทาง LINE ไม่สำเร็จ · กดเปิดคูปองจากบัตรนี้ได้',
      not_linked: 'คูปองพร้อมในบัตรนี้ · รายการยังไม่ได้เชื่อม LINE',
      redeemed: 'รับของแถมแล้ว',
      expired: 'คูปองของแถมหมดอายุแล้ว',
      void: 'คูปองของแถมถูกยกเลิกแล้ว'
    };
    get('passCouponStatus').textContent = couponStatus[data.gift_coupon_status] || '';
    renderCounterPayment(client,get('counterPayment'),payment,token,load);
    const deliveryStatus = {
      accepted: 'LINE รับข้อความแล้ว · เปิดแชตกับ LINE OA ของร้านเพื่อดูบัตร',
      queued: 'เชื่อม LINE แล้ว · กำลังรอส่งบัตร',
      failed: 'LINE ส่งบัตรไม่สำเร็จ · กรุณาติดต่อร้าน'
    };
    lineStatus.textContent = deliveryStatus[data.line_delivery] || (data.line_linked
      ? (['confirmed','checked_in','completed'].includes(data.status)
        ? 'เชื่อม LINE แล้ว · โปรดตรวจข้อความยืนยันในแชตกับ LINE OA ของร้าน'
        : 'เชื่อม LINE แล้ว · ระบบจะแจ้งสถานะทางแชตของร้าน')
      : data.line_code ? 'รายการนี้ยังไม่ได้เชื่อม LINE หากต้องการให้ร้านตรวจสอบ กรุณาเปิดบัตรนี้ให้ร้านดู'
        : !data.expired && ['pending_payment','pending_confirm','slip_review','confirmed'].includes(data.status)
          ? 'ร้านยังไม่เปิดรับบัตรผ่าน LINE คุณเปิดบัตรจากหน้านี้ได้' : '');

  } catch {
    status.textContent = 'โหลดสถานะบัตรไม่ได้ กรุณากดอัปเดตสถานะอีกครั้ง';
  } finally {
    refresh.disabled = false;
    refresh.classList.remove('hidden');
  }
}

get('passCopyLink').onclick = () => copy(location.href);
refresh.onclick = load;
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && passTokenPattern.test(token) && !refresh.disabled) void load();
});
if (passTokenPattern.test(token)) {
  void load();
  setInterval(() => {
    if (!document.hidden && !qr.classList.contains('hidden') && !refresh.disabled) void load();
  },10000);
}
else status.textContent = 'ลิงก์บัตรจองไม่ถูกต้อง กรุณาเปิดจากหน้าจองหรือจาก LINE';
