import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
import { passStatus, passTokenPattern, renderPassDetails } from './booking-pass-details.js';

const get = id => document.getElementById(id);
const token = location.hash.slice(1);
const status = get('passStatus');
const showQr = get('passShowQr');
const refresh = get('passRefresh');
const qr = get('passQr');
const line = get('passLine');
const lineStatus = get('passLineStatus');
const feedback = get('passFeedback');
const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: false, detectSessionInUrl: false, autoRefreshToken: false }
});

async function copy(value, fallback) {
  try {
    await navigator.clipboard.writeText(value);
    feedback.textContent = 'คัดลอกแล้ว';
  } catch {
    fallback?.select();
    feedback.textContent = fallback ? 'เลือกข้อความแล้ว กดคัดลอกจากเบราว์เซอร์' : 'คัดลอกลิงก์จากแถบที่อยู่ได้เลย';
  }
}

async function load() {
  refresh.disabled = true;
  try {
    const { data, error } = await client.rpc('get_customer_booking_pass', { p_token: token });
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
      : '';
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
    line.classList.toggle('hidden', !data.line_code);
    get('passLineHelp').textContent = 'คัดลอกข้อความด้านล่างแล้วกดส่งในแชตส่วนตัวกับ LINE OA «'
      + (data.bot_name || data.shop) + '» จากนั้นกลับมากดอัปเดตสถานะ';
    get('passLineCode').value = data.line_code ? 'บัตร ' + data.line_code : '';
    const deliveryStatus = {
      accepted: 'LINE รับข้อความแล้ว · เปิดแชตกับ LINE OA ของร้านเพื่อดูบัตร',
      queued: 'เชื่อม LINE แล้ว · กำลังรอส่งบัตร',
      failed: 'LINE ส่งบัตรไม่สำเร็จ · กรุณาติดต่อร้าน'
    };
    lineStatus.textContent = deliveryStatus[data.line_delivery] || (data.line_linked
      ? (['confirmed','checked_in','completed'].includes(data.status)
        ? 'เชื่อม LINE แล้ว · โปรดตรวจข้อความยืนยันในแชตกับ LINE OA ของร้าน'
        : 'เชื่อม LINE แล้ว · ระบบจะส่งบัตรเมื่อร้านยืนยันการจอง')
      : data.line_code ? 'สถานะ LINE · รอเชื่อมบัตรเพื่อจัดส่ง Flex ในแชตของร้าน'
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
get('passCopyCode').onclick = () => copy(get('passLineCode').value, get('passLineCode'));
refresh.onclick = load;
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && !line.classList.contains('hidden') && !refresh.disabled) void load();
});
if (passTokenPattern.test(token)) void load();
else status.textContent = 'ลิงก์บัตรจองไม่ถูกต้อง กรุณาเปิดจากหน้าจองหรือจาก LINE';
