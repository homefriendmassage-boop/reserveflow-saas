import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
import { createSupabaseStore, listMerchantShops } from '../data/supabase-store.js';

const byId = id => document.getElementById(id);
const login = byId('merchantLogin');
const form = byId('merchantForm');
const signIn = byId('merchantSignIn');
const signOut = byId('merchantSignOut');
const dashboard = byId('merchantDashboard');
const shopMenu = byId('merchantShop');
const bookings = byId('merchantBookings');
const status = byId('merchantStatus');
let bookingRequest = 0;

function showLogin(message = '') {
  bookingRequest++;
  shopMenu.replaceChildren();
  bookings.replaceChildren();
  dashboard.classList.add('hidden');
  login.classList.remove('hidden');
  status.textContent = message;
}

function bookingCard(booking, timezone) {
  const card = document.createElement('article');
  card.className = 'booking';
  const title = document.createElement('h3');
  title.textContent = booking.resource_code;
  const details = document.createElement('p');
  const formatDate = new Intl.DateTimeFormat('th-TH', {
    dateStyle: 'medium', timeStyle: 'short', timeZone: timezone
  });
  const amount = new Intl.NumberFormat('th-TH', { style: 'currency', currency: 'THB' });
  const labels = {
    pending_payment: 'จองรอชำระ', slip_review: 'รอตรวจสลิป',
    pending_confirm: 'รอลูกค้าคอนเฟิร์ม', confirmed: 'จองแล้ว',
    checked_in: 'เช็กอินแล้ว', completed: 'เสร็จสิ้น', cancelled: 'ยกเลิก'
  };
  details.textContent = [
    formatDate.formatRange(new Date(booking.starts_at), new Date(booking.ends_at)),
    labels[booking.status] || booking.status,
    amount.format(booking.amount)
  ].join(' · ');
  card.append(title, details);
  return card;
}

if (typeof window.supabase?.createClient !== 'function') {
  status.textContent = 'โหลดระบบเข้าสู่ระบบไม่สำเร็จ กรุณารีเฟรชหน้า';
} else {
  const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: { persistSession: false, detectSessionInUrl: false }
  });

  async function loadBookings() {
    const request = ++bookingRequest;
    const shop = shopMenu.selectedOptions[0];
    bookings.textContent = 'กำลังโหลดรายการจอง…';
    try {
      const rows = await createSupabaseStore(client, shop.value).getBookings();
      if (request !== bookingRequest) return;
      if (rows.length) {
        bookings.replaceChildren(...rows.map(row => bookingCard(row, shop.dataset.timezone)));
      } else {
        bookings.textContent = 'ยังไม่มีรายการจอง';
      }
    } catch {
      if (request === bookingRequest) bookings.textContent = 'โหลดรายการจองไม่ได้ กรุณาลองใหม่';
    }
  }

  client.auth.onAuthStateChange(event => {
    if (event === 'SIGNED_OUT') showLogin();
  });
  signIn.disabled = false;

  form.addEventListener('submit', async event => {
    event.preventDefault();
    signIn.disabled = true;
    status.textContent = 'กำลังเข้าสู่ระบบ…';
    try {
      const { error } = await client.auth.signInWithPassword({
        email: form.elements.email.value.trim(),
        password: form.elements.password.value
      });
      if (error) {
        showLogin('เข้าสู่ระบบไม่สำเร็จ กรุณาตรวจอีเมล รหัสผ่าน และการเชื่อมต่อแล้วลองใหม่');
        return;
      }

      const shops = await listMerchantShops(client);
      if (!shops.length) {
        await client.auth.signOut({ scope: 'local' });
        showLogin('บัญชีนี้ยังไม่มีสิทธิ์เข้าถึงร้านค้า');
        return;
      }
      shopMenu.replaceChildren(...shops.map(shop => {
        const option = new Option(shop.name, shop.id);
        option.dataset.timezone = shop.timezone;
        return option;
      }));
      login.classList.add('hidden');
      dashboard.classList.remove('hidden');
      status.textContent = '';
      await loadBookings();
    } catch {
      await client.auth.signOut({ scope: 'local' });
      showLogin('ตรวจสิทธิ์ร้านค้าไม่สำเร็จ กรุณาลองอีกครั้ง');
    } finally {
      form.elements.password.value = '';
      signIn.disabled = false;
    }
  });

  shopMenu.addEventListener('change', loadBookings);
  signOut.addEventListener('click', async () => {
    showLogin('กำลังออกจากระบบ…');
    signIn.disabled = true;
    try {
      const { error } = await client.auth.signOut({ scope: 'local' });
      if (error) throw error;
    } catch {
      window.location.reload();
    } finally {
      signIn.disabled = false;
    }
  });
}
