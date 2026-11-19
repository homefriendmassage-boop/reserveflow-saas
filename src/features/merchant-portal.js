import { loadPlatformAdmin, renderLineSettings } from './line-settings.js';
import { renderMerchantTeam } from './merchant-team.js';
import { renderMerchantSettings } from './merchant-settings.js';
import { bookingTimeOptions, dateAtShop } from './booking-slots.js';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
import { createSupabaseStore, listMerchantShops } from '../data/supabase-store.js';

const byId = id => document.getElementById(id);
const login = byId('merchantLogin');
const registration = byId('merchantRegister');
const registerForm = byId('merchantRegisterForm');
const registerSubmit = byId('merchantRegisterSubmit');
const joinForm = byId('merchantJoinForm');
const joinStatus = byId('merchantJoinStatus');
const teamList = byId('merchantTeamList');
const teamStatus = byId('merchantTeamStatus');
const teamSearch = byId('merchantTeamSearch');
let teamRows = [];
let teamRequest = 0;
let teamBusy = false;
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
const settings = byId('merchantShopSettings');
const advancedSettings = byId('merchantAdvancedSettings');
const search = byId('merchantBookingSearch');
const publicLink = byId('merchantPublicLink');
const emailForm = byId('merchantEmailForm');
const emailSignIn = byId('merchantEmailSignIn');
const roleLabel = { owner: 'เจ้าของร้าน', admin: 'แคชเชียร์ (แอดมินเดิม)', cashier: 'แคชเชียร์', staff: 'พนักงาน' };
let currentRole;
let displayedBookings = [];
let bookingTimezone;
const canManageTables = () => ['owner', 'admin', 'cashier'].includes(currentRole);

let bookingRequest = 0;
let tableCategories = new Set();
let pendingBooking;
let saving = false;

const actionErrors = {
  BOOKING_SLOT_TAKEN: 'โต๊ะนี้ถูกจองในช่วงเวลาดังกล่าวแล้ว',
  INVALID_BOOKING_DATE: 'เลือกเวลาในอนาคตและจองล่วงหน้าได้สูงสุด 90 วัน',
  INVALID_TABLE_BOOKING: 'ตรวจจำนวนคนและเบอร์โทรศัพท์',
  INVALID_BOOKING_STATUS: 'เปลี่ยนสถานะไม่ได้ กรุณาตรวจสถานะล่าสุด',
  INVALID_CHECK_IN: 'เช็กอินได้ตั้งแต่ 30 นาทีก่อนเริ่มจนถึงก่อนหมดเวลาของรายการที่ยืนยันแล้ว',
  INVALID_TABLE_POSITION: 'ตำแหน่งโต๊ะต้องอยู่ระหว่าง 5 ถึง 95%',
  INVALID_STAFF_ROLE: 'ตรวจ UID และสิทธิ์ที่เลือก หรือบัญชีนี้อาจเป็นเจ้าของร้าน',
  INVALID_SHOP_SETTINGS: 'กรุณาตรวจชื่อร้าน',
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
  byId('platformAdmin').classList.add('hidden');
  byId('platformShopList').replaceChildren();
  byId('platformLineSettings').replaceChildren();
  byId('merchantLineSettings').replaceChildren();
  registration.classList.add('hidden');
  registerForm.reset();
  joinForm.reset();
  joinStatus.textContent = '';
  byId('merchantJoinPanel').open = false;
  byId('merchantRegistrationUid').textContent = '';
  byId('merchantAccountUid').textContent = '';
  ++teamRequest;
  teamRows = [];
  teamList.replaceChildren();
  teamSearch.value = '';
  teamStatus.textContent = '';
  bookingRequest++;
  shopMenu.replaceChildren();
  publicLink.classList.add('hidden');
  tableMenu.replaceChildren();
  tableForm.reset();
  toggleTableSchedule();
  tableEditor.open = false;
  tableCategories.clear();
  pendingBooking = undefined;
  actionStatus.textContent = '';
  bookings.replaceChildren();
  currentRole = undefined;
  displayedBookings = [];
  advancedSettings.replaceChildren();
  search.value = '';
  settings.open = false;
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
  const reference = document.createElement('small');
  reference.textContent = booking.id;
  card.append(title, details, reference);
  const start = new Date(booking.starts_at).getTime();
  const now = Date.now();
  const options = [];
  if (booking.status === 'confirmed' && now >= start - 1800000 && now < new Date(booking.ends_at).getTime()) {
    options.push(['checked_in', 'เช็กอิน']);
  }
  if (canManageTables() && tableCategories.has(booking.category_code) && !['completed', 'cancelled'].includes(booking.status)) {
    const started = start <= now;
    if (!started && booking.status === 'pending_confirm') options.push(['confirmed', 'ยืนยันการจอง']);
    if (started && ['confirmed', 'checked_in'].includes(booking.status)) options.push(['completed', 'ใช้งานเสร็จ · คืนโต๊ะ']);
    options.push(['cancelled', 'ยกเลิกการจอง']);
  }

  if (options.length) {
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
    if (next === 'checked_in') return runAction(store => store.checkIn(id), 'เช็กอินแล้ว');
    const message = next === 'confirmed' ? 'ยืนยันการจองแล้ว' : 'คืนโต๊ะแล้ว';
    return runAction(store => store.changeTableStatus(id, next), message);
  }

  function renderBookingList() {
    const term = search.value.trim().toLowerCase();
    const rows = displayedBookings.filter(row => !term ||
      [row.id, row.resource_code].some(value => value.toLowerCase().includes(term)));
    if (rows.length) {
      bookings.replaceChildren(...rows.map(row => bookingCard(row, bookingTimezone, changeStatus)));
    } else {
      bookings.textContent = term ? 'ไม่พบรายการจองที่ค้นหา' : 'ยังไม่มีรายการจอง';
    }
  }
  search.addEventListener('input', renderBookingList);

  async function loadBookings() {
    const request = ++bookingRequest;
    const shop = shopMenu.selectedOptions[0];
    if (!shop) return;
    bookings.textContent = 'กำลังโหลดรายการจอง…';
    try {
      const rows = await createSupabaseStore(client, shop.value).getBookings();
      if (request !== bookingRequest) return;
      displayedBookings = rows;
      bookingTimezone = shop.dataset.timezone;
      renderBookingList();
    } catch {
      if (request === bookingRequest) bookings.textContent = 'โหลดรายการจองไม่ได้ กรุณาลองใหม่';
    }
  }

  function renderTeam() {
    if (currentRole === 'owner') renderMerchantTeam(teamList, teamRows, teamSearch.value, applyTeamAction);
  }

  async function loadTeam() {
    const request = ++teamRequest;
    const shopId = shopMenu.value;
    teamRows = [];
    teamList.replaceChildren();
    if (currentRole !== 'owner') return;
    teamList.textContent = 'กำลังโหลดรายชื่อทีมงาน…';
    try {
      const { data, error } = await client.rpc('list_merchant_team', { p_shop_id: shopId });
      if (error) throw error;
      if (request !== teamRequest) return;
      teamRows = data;
      renderTeam();
    } catch {
      if (request === teamRequest) teamList.textContent = 'โหลดรายชื่อทีมงานไม่ได้';
    }
  }

  async function applyTeamAction(member, role) {
    if (teamBusy || currentRole !== 'owner') return;
    const shopId = shopMenu.value;
    teamBusy = true;
    try {
      if (member.role === 'pending') {
        const { error } = await client.rpc('review_merchant_team_request', {
          p_shop_id: shopId, p_user_id: member.user_id, p_action: role
        });
        if (error) throw error;
      } else {
        await createSupabaseStore(client, shopId).setStaffRole(member.user_id, role);
      }
      if (shopMenu.value !== shopId) return;
      teamStatus.textContent = 'อัปเดตสิทธิ์ทีมงานแล้ว';
      await loadTeam();
    } catch {
      if (shopMenu.value === shopId) teamStatus.textContent = 'อัปเดตสิทธิ์ไม่สำเร็จ กรุณาตรวจรายชื่อแล้วลองอีกครั้ง';
    } finally {
      teamBusy = false;
    }
  }

  teamSearch.addEventListener('input', renderTeam);

  async function loadShop() {
    const shop = shopMenu.selectedOptions[0];
    if (!shop) return;
    const request = ++bookingRequest;
    currentRole = shop.dataset.role;
    publicLink.classList.toggle('hidden', !shop.dataset.slug);
    publicLink.href = './book.html?' + new URLSearchParams({ shop: shop.dataset.slug || '' });
    byId('merchantRole').textContent = roleLabel[currentRole] || '';
    settings.classList.toggle('hidden', currentRole !== 'owner');
    tableEditor.classList.toggle('hidden', !canManageTables());
    byId('merchantShopName').value = shop.textContent;
    byId('merchantShopOpen').checked = shop.dataset.open === 'true';
    displayedBookings = [];
    advancedSettings.replaceChildren();
    search.value = '';
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
    teamSearch.value = '';
    teamStatus.textContent = '';
    void loadTeam();
    const lineSettings = byId('merchantLineSettings');
    lineSettings.replaceChildren();
    if (currentRole === 'owner') renderLineSettings(client, lineSettings, shop.value);

    try {
      const store = createSupabaseStore(client, shop.value);
      if (!canManageTables()) {
        await loadBookings();
        return;
      }
      const [categories, resources, layouts] = await Promise.all([store.getCategories(), store.getResources(), store.getLayouts()]);
      if (request !== bookingRequest) return;
      tableCategories = new Set(categories.filter(category => category.template === 'table').map(category => category.code));
      const tableResources = resources.filter(resource => tableCategories.has(resource.category_code)).map(resource => ({
        ...resource, key: JSON.stringify([resource.category_code, resource.code])
      }));
      tableMenu.replaceChildren(...tableResources.map(resource => {
        const option = new Option(resource.name, resource.key);
        option.dataset.capacity = resource.capacity || 100;
        return option;
      }));
      renderMerchantSettings(advancedSettings, { categories, resources, layouts, owner: currentRole === 'owner',
        save: async (rpc, parameters) => {
          if (shopMenu.value !== shop.value) throw new Error('Shop changed');
          const { error } = await client.rpc(rpc, { ...parameters, p_shop_id: shop.value });
          if (error) throw error;
        },
        reload: loadShop
      });
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
      byId('merchantAccountUid').textContent = data.session.user.id;
      await loadPlatformAdmin(client);
      const shops = await listMerchantShops(client);
      if (!shops.length) {
        login.classList.add('hidden');
        dashboard.classList.add('hidden');
        registration.classList.toggle('hidden', !byId('platformAdmin').classList.contains('hidden'));
        byId('merchantRegistrationUid').textContent = data.session.user.id;
        status.textContent = '';
        return;
      }
      shopMenu.replaceChildren(...shops.map(shop => {
        const option = new Option(shop.name, shop.id);
        option.dataset.timezone = shop.timezone;
        if (shop.slug) option.dataset.slug = shop.slug;
        option.dataset.role = shop.role;
        option.dataset.open = String(shop.public_booking_enabled);
        return option;
      }));
      login.classList.add('hidden');
      registration.classList.add('hidden');
      registerForm.reset();
      dashboard.classList.remove('hidden');
      status.textContent = '';
      await loadShop();
    } catch {
      showLogin('ตรวจสิทธิ์ร้านค้าไม่สำเร็จ กรุณาลองอีกครั้ง');
    } finally {
      signIn.disabled = false;
      emailSignIn.disabled = false;
    }
  }

  signIn.addEventListener('click', async () => {
    signIn.disabled = true;
    status.textContent = 'กำลังเปิด LINE Login…';
    try {
      const redirectTo = new URL('./merchant.html', location.href).href;
      const { error } = await client.auth.signInWithOAuth({
        provider: 'custom:line-manual',
        options: { redirectTo }
      });
      if (error) throw error;
    } catch {
      showLogin('เปิด LINE Login ไม่ได้ กรุณาลองอีกครั้ง');
      signIn.disabled = false;
    }
  });
  emailForm.addEventListener('submit', async event => {
    event.preventDefault();
    emailSignIn.disabled = true;
    signIn.disabled = true;
    status.textContent = 'กำลังเข้าสู่ระบบ…';
    try {
      const { error } = await client.auth.signInWithPassword({
        email: emailForm.elements.email.value.trim(), password: emailForm.elements.password.value
      });
      if (error) throw error;
      await loadSession();
    } catch {
      showLogin('เข้าสู่ระบบไม่สำเร็จ กรุณาตรวจอีเมลและรหัสผ่าน');
    } finally {
      emailForm.elements.password.value = '';
      emailSignIn.disabled = false;
      signIn.disabled = false;
    }
  });

  byId('merchantShopSettingsForm').addEventListener('submit', event => {
    event.preventDefault();
    if (currentRole !== 'owner') return;
    const shop = shopMenu.selectedOptions[0];
    const name = byId('merchantShopName').value.trim();
    const enabled = byId('merchantShopOpen').checked;
    void runAction(async store => {
      await store.updateShop(name, enabled);
      shop.textContent = name;
      shop.dataset.open = String(enabled);
    }, 'บันทึกการตั้งค่าร้านแล้ว');
  });

  joinForm.addEventListener('submit', async event => {
    event.preventDefault();
    const button = byId('merchantJoinSubmit');
    if (button.disabled) return;
    const raw = joinForm.elements.slug.value.trim();
    let slug = raw;
    if (raw.startsWith('https://')) {
      try { slug = new URL(raw).searchParams.get('shop') || ''; }
      catch { slug = ''; }
    }
    button.disabled = true;
    joinStatus.textContent = 'กำลังส่งคำขอ…';
    try {
      const { error } = await client.rpc('request_merchant_team_access', {
        p_slug: slug, p_name: joinForm.elements.teamName.value.trim()
      });
      if (error) throw error;
      joinForm.reset();
      joinStatus.textContent = 'ส่งคำขอแล้ว รอเจ้าของร้านอนุมัติ แล้วรีเฟรชหน้านี้';
    } catch (error) {
      const errors = {
        INVALID_TEAM_REQUEST: 'ตรวจชื่อร้านและชื่อที่แจ้งเจ้าของร้าน',
        TEAM_ALREADY_MEMBER: 'บัญชีนี้อยู่ในร้านแล้ว กรุณารีเฟรชหน้า',
        TEAM_REQUEST_LIMIT: 'ส่งคำขอครบจำนวนที่กำหนดแล้ว'
      };
      joinStatus.textContent = errors[error.message] || 'ส่งคำขอไม่ได้ กรุณาลองอีกครั้ง';
    } finally {
      button.disabled = false;
    }
  });

  registerForm.addEventListener('submit', async event => {
    event.preventDefault();
    if (registerSubmit.disabled) return;
    registerSubmit.disabled = true;
    const logoutButton = byId('merchantRegisterSignOut');
    logoutButton.disabled = true;
    status.textContent = 'กำลังสร้างร้าน…';
    try {
      const { error } = await client.rpc('register_merchant_shop', {
        p_name: registerForm.elements.shopName.value.trim(),
        p_slug: registerForm.elements.slug.value.trim()
      });
      if (error) throw error;
      await loadSession();
      if (!dashboard.classList.contains('hidden')) {
        actionStatus.textContent = 'สร้างร้านแล้ว เปิดรับจองได้จากเมนูตั้งค่าร้าน';
      }
    } catch (error) {
      const errors = {
        SHOP_SLUG_TAKEN: 'ชื่อลิงก์นี้ถูกใช้แล้ว กรุณาเลือกชื่ออื่น',
        SHOP_MEMBERSHIP_EXISTS: 'บัญชีนี้มีร้านอยู่แล้ว กรุณารีเฟรชเพื่อเปิดหลังบ้าน',
        INVALID_SHOP_REGISTRATION: 'กรุณาตรวจชื่อร้านและชื่อสำหรับลิงก์จอง'
      };
      status.textContent = errors[error.message] || 'ยืนยันผลการสร้างร้านไม่ได้ กรุณาลองอีกครั้ง';
    } finally {
      registerSubmit.disabled = false;
      logoutButton.disabled = false;
    }
  });
  byId('platformSignOut').addEventListener('click', () => signOut.click());
  byId('merchantRegisterSignOut').addEventListener('click', () => signOut.click());
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
