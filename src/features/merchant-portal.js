import { bookingTimeOptions, dateAtShop } from './booking-slots.js';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
import { createSupabaseStore, listMerchantShops } from '../data/supabase-store.js';

const byId = id => document.getElementById(id);
const login = byId('merchantLogin');
const signIn = byId('merchantSignIn');
const signOut = byId('merchantSignOut');
const dashboard = byId('merchantDashboard');
const shopMenu = byId('merchantShop');
const bookings = byId('merchantBookings');
const status = byId('merchantStatus');
const actionStatus = byId('merchantActionStatus');
const tableEditor = byId('merchantTableEditor');
const tableForm = byId('merchantTableForm');
const tableMenu = byId('merchantTable');
const tableMode = byId('merchantTableMode');
const dateField = byId('merchantTableDate');
const timeField = byId('merchantTableTime');
const guestField = byId('merchantTableGuests');
const tableSubmit = tableForm.querySelector('button[type="submit"]');
let bookingRequest = 0;
let tableCategories = new Set();
let pendingBooking;
let saving = false;

const actionErrors = {
  BOOKING_SLOT_TAKEN: 'โต๊ะนี้ถูกจองในช่วงเวลาดังกล่าวแล้ว',
  INVALID_BOOKING_DATE: 'เลือกเวลาในอนาคตและจองล่วงหน้าได้สูงสุด 90 วัน',
  INVALID_TABLE_BOOKING: 'ตรวจจำนวนคนและเบอร์โทรศัพท์',
  INVALID_BOOKING_STATUS: 'เปลี่ยนสถานะไม่ได้ กรุณาตรวจสถานะล่าสุด',
  MERCHANT_BOOKING_FORBIDDEN: 'บัญชีนี้ไม่มีสิทธิ์จัดการการจองของร้าน'
};

function toggleTableSchedule() {
  const scheduled = tableMode.value === 'scheduled';
  for (const field of [dateField, timeField]) {
    field.disabled = !scheduled;
    field.parentElement.classList.toggle('hidden', !scheduled);
  }
}

function updateTableCapacity() {
  guestField.max = tableMenu.selectedOptions[0]?.dataset.capacity || 100;
  if (Number(guestField.value) > Number(guestField.max)) guestField.value = guestField.max;
}

timeField.replaceChildren(...bookingTimeOptions());
tableMode.addEventListener('change', toggleTableSchedule);
tableMenu.addEventListener('change', updateTableCapacity);

function showLogin(message = '') {
  bookingRequest++;
  shopMenu.replaceChildren();
  tableMenu.replaceChildren();
  tableForm.reset();
  toggleTableSchedule();
  tableEditor.open = false;
  tableCategories.clear();
  pendingBooking = undefined;
  actionStatus.textContent = '';
  bookings.replaceChildren();
  dashboard.classList.add('hidden');
  login.classList.remove('hidden');
  status.textContent = message;
}

function bookingCard(booking, timezone, changeStatus) {
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
    pending_confirm: 'รอยืนยัน', confirmed: 'จองแล้ว',
    checked_in: 'เช็กอินแล้ว', completed: 'เสร็จสิ้น', cancelled: 'ยกเลิก'
  };
  details.textContent = [
    formatDate.formatRange(new Date(booking.starts_at), new Date(booking.ends_at)),
    labels[booking.status] || booking.status,
    amount.format(booking.amount)
  ].join(' · ');
  card.append(title, details);
  if (tableCategories.has(booking.category_code) && !['completed', 'cancelled'].includes(booking.status)) {
    const started = new Date(booking.starts_at) <= new Date();
    const options = [];
    if (!started && booking.status === 'pending_confirm') options.push(['confirmed', 'ยืนยันการจอง']);
    if (started && ['confirmed', 'checked_in'].includes(booking.status)) options.push(['completed', 'ใช้งานเสร็จ · คืนโต๊ะ']);
    options.push(['cancelled', 'ยกเลิกการจอง']);

    const actions = document.createElement('div');
    actions.className = 'inline-actions';
    for (const [next, label] of options) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = next === 'cancelled' ? 'btn danger small' : 'btn soft small';
      button.textContent = label;
      button.addEventListener('click', () => {
        if (next !== 'cancelled' || window.confirm('ยกเลิกการจองและคืนโต๊ะใช่ไหม?')) {
          changeStatus(booking.id, next);
        }
      });
      actions.append(button);
    }
    card.append(actions);
  }
  return card;
}

if (typeof window.supabase?.createClient !== 'function') {
  status.textContent = 'โหลดระบบเข้าสู่ระบบไม่สำเร็จ กรุณารีเฟรชหน้า';
} else {
  const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: { flowType: 'pkce', storage: window.sessionStorage }
  });

  async function runAction(operation, success) {
    if (saving || !shopMenu.value) return;
    const shopId = shopMenu.value;
    const store = createSupabaseStore(client, shopId);
    saving = true;
    tableSubmit.disabled = true;
    actionStatus.textContent = 'กำลังบันทึก…';
    try {
      await operation(store);
      if (shopMenu.value !== shopId) return;
      actionStatus.textContent = success;
      await loadBookings();
    } catch (error) {
      if (shopMenu.value === shopId) {
        actionStatus.textContent = actionErrors[error.message] || 'ยืนยันผลการบันทึกไม่ได้ กรุณาลองอีกครั้ง';
        await loadBookings();
      }
    } finally {
      saving = false;
      tableSubmit.disabled = !tableMenu.value;
    }
  }

  function changeStatus(id, next) {
    const message = next === 'confirmed' ? 'ยืนยันการจองแล้ว' : 'คืนโต๊ะแล้ว';
    return runAction(store => store.changeTableStatus(id, next), message);
  }

  async function loadBookings() {
    const request = ++bookingRequest;
    const shop = shopMenu.selectedOptions[0];
    if (!shop) return;
    bookings.textContent = 'กำลังโหลดรายการจอง…';
    try {
      const rows = await createSupabaseStore(client, shop.value).getBookings();
      if (request !== bookingRequest) return;
      if (rows.length) {
        bookings.replaceChildren(...rows.map(row => bookingCard(row, shop.dataset.timezone, changeStatus)));
      } else {
        bookings.textContent = 'ยังไม่มีรายการจอง';
      }
    } catch {
      if (request === bookingRequest) bookings.textContent = 'โหลดรายการจองไม่ได้ กรุณาลองใหม่';
    }
  }

  async function loadShop() {
    const shop = shopMenu.selectedOptions[0];
    if (!shop) return;
    const request = ++bookingRequest;
    tableCategories = new Set();
    pendingBooking = undefined;
    tableMenu.replaceChildren();
    tableSubmit.disabled = true;
    tableForm.reset();
    toggleTableSchedule();
    dateField.min = dateAtShop(shop.dataset.timezone);
    dateField.value = dateField.min;
    actionStatus.textContent = '';
    bookings.textContent = 'กำลังโหลดข้อมูลร้าน…';

    try {
      const store = createSupabaseStore(client, shop.value);
      const [categories, resources] = await Promise.all([store.getCategories(), store.getResources()]);
      if (request !== bookingRequest) return;
      tableCategories = new Set(categories.filter(category => category.template === 'table').map(category => category.code));
      tableMenu.replaceChildren(...resources.filter(resource => tableCategories.has(resource.category_code)).map(resource => {
        const option = new Option(resource.name, JSON.stringify([resource.category_code, resource.code]));
        option.dataset.capacity = resource.capacity || 100;
        return option;
      }));
      updateTableCapacity();
      tableSubmit.disabled = saving || !tableMenu.value;
    } catch {
      if (request === bookingRequest) actionStatus.textContent = 'โหลดตัวเลือกโต๊ะไม่ได้';
    }
    if (request === bookingRequest) await loadBookings();
  }

  tableForm.addEventListener('submit', event => {
    event.preventDefault();
    if (saving || !tableMenu.value) return;
    const [category, resource] = JSON.parse(tableMenu.value);
    const scheduled = tableMode.value === 'scheduled';
    const [hour, minute] = timeField.value.split(':').map(Number);
    const payload = {
      p_category_code: category, p_resource_code: resource,
      p_date: scheduled ? dateField.value : null,
      p_hour: scheduled ? hour : null, p_minute: scheduled ? minute : null,
      p_guests: Number(guestField.value),
      p_name: byId('merchantTableName').value, p_phone: byId('merchantTablePhone').value
    };
    const fingerprint = JSON.stringify(payload);
    if (pendingBooking?.fingerprint !== fingerprint) {
      pendingBooking = { fingerprint, id: crypto.randomUUID() };
    }
    const id = pendingBooking.id;
    const shopId = shopMenu.value;
    void runAction(async store => {
      await store.createTableBooking({ ...payload, p_request_id: id });
      if (shopMenu.value !== shopId) return;
      pendingBooking = undefined;
      byId('merchantTableName').value = '';
      byId('merchantTablePhone').value = '';
    }, 'บันทึกการจองโต๊ะแล้ว');
  });

  client.auth.onAuthStateChange(event => {
    if (event === 'SIGNED_OUT') showLogin();
  });

  async function loadSession() {
    try {
      const { data, error } = await client.auth.getSession();
      if (error) throw error;
      if (!data.session) {
        const params = new URLSearchParams(location.search);
        if (params.has('error') || params.has('error_code') || params.has('code')) {
          showLogin('เข้าสู่ระบบด้วย LINE ไม่สำเร็จ กรุณาลองอีกครั้ง');
        }
        return;
      }
      const shops = await listMerchantShops(client);
      if (!shops.length) {
        await client.auth.signOut({ scope: 'local' });
        showLogin('บัญชี LINE นี้ยังไม่มีสิทธิ์เข้าถึงร้านค้า');
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
      await loadShop();
    } catch {
      showLogin('ตรวจสิทธิ์ร้านค้าไม่สำเร็จ กรุณาลองอีกครั้ง');
    } finally {
      signIn.disabled = false;
    }
  }

  signIn.addEventListener('click', async () => {
    signIn.disabled = true;
    status.textContent = 'กำลังเปิด LINE Login…';
    try {
      const redirectTo = new URL('./merchant.html', location.href).href;
      const { error } = await client.auth.signInWithOAuth({
        provider: 'custom:line',
        options: { redirectTo }
      });
      if (error) throw error;
    } catch {
      showLogin('เปิด LINE Login ไม่ได้ กรุณาลองอีกครั้ง');
      signIn.disabled = false;
    }
  });
  void loadSession();

  shopMenu.addEventListener('change', loadShop);
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
