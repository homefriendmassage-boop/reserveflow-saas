import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
import { passStatus, passTokenPattern, renderPassDetails } from './booking-pass-details.js';

const get = id => document.getElementById(id);
const token = location.hash.slice(1);
const status = get('passStatus');
const showQr = get('passShowQr');
const refresh = get('passRefresh');
const qr = get('passQr');
const line = get('passLine');
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
    showQr.classList.toggle('hidden', !data.scan_token);
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
    get('passLineHelp').textContent = 'ส่งข้อความนี้ในแชตส่วนตัวกับ LINE OA ' + (data.bot_name || data.shop)
      + ' เพื่อรับ Flex เมื่อรายการยืนยันแล้ว';
    get('passLineCode').value = data.line_code ? 'บัตร ' + data.line_code : '';
    if (data.line_linked) feedback.textContent = 'เชื่อม LINE สำหรับบัตรนี้แล้ว';
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
if (passTokenPattern.test(token)) void load();
else status.textContent = 'ลิงก์บัตรจองไม่ถูกต้อง กรุณาเปิดจากหน้าจองหรือจาก LINE';
