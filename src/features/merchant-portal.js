import { bookingPrice } from './booking-pricing.js';
import { counterPaymentRpc, openMerchantCounterPayment } from './counter-payment.js?v=customer-qr-handoff';
import { editBookingRecipient, renderBookingHistory } from './merchant-booking-tools.js?v=merchant-tools-1';
import { passStatus, passTokenPattern, renderPassDetails } from './booking-pass-details.js';
import { renderDailyReport } from './daily-report.js?v=report-labels-45';
import { renderPlatformTools, renderShopBusinessTools, showSignupPackages } from './platform-tools.js?v=platform-shop-management-43';
import { addThunderCheck } from './thunder-slip.js?v=bank-slip-preview-37';
import { loadPlatformAdmin, renderLineSettings } from './line-settings.js?v=hour-promotions-51';
import { renderMerchantTeam } from './merchant-team.js?v=team-slip-credits-1';
import { renderMerchantSettings } from './merchant-settings.js?v=hour-promotions-51';
import { bookingTimeOptions, businessDateAtShop, calendarSlotDate, dateAtShop, timeAtShop } from './booking-slots.js?v=business-day-1';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
import { createSupabaseStore, listMerchantShops } from '../data/supabase-store.js?v=platform-shop-management-43';

const byId = id => document.getElementById(id);
const scanKey = 'reserveflow.merchant-scan';
const scanFromLink = new URLSearchParams(location.hash.slice(1)).get('scan');
let scanToken;
if (passTokenPattern.test(scanFromLink || '')) {
  scanToken = scanFromLink;
  try { sessionStorage.setItem(scanKey, scanToken); } catch {}
  history.replaceState(null, '', location.pathname + location.search);
} else {
  try { scanToken = sessionStorage.getItem(scanKey); } catch {}
}
const login = byId('merchantLogin');
const passPanel = byId('merchantPassPanel');
const haveScan = () => passTokenPattern.test(scanToken || '');
if (haveScan()) byId('merchantLoginHelp').textContent = 'เข้าสู่ระบบครั้งแรกเพื่อเปิดบัตรที่สแกนไว้';
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
const accountPanel = byId('merchantAccount');
const loginShopKey = 'reserveflow.login-shop';
function setShopUrl(shop) {
  const url = new URL(location.href);
  url.searchParams.set('shop',shop.dataset.slug || shop.value);
  if (url.href !== location.href) history.replaceState(history.state,'',url);
}
const bookings = byId('merchantBookings');
const status = byId('merchantStatus');
const actionStatus = byId('merchantActionStatus');
const tableEditor = byId('merchantTableEditor');
const tableForm = byId('merchantTableForm');
const tableMenu = byId('merchantTable');
const categoryMenu = byId('merchantBookingCategory');
const hoursField = byId('merchantBookingHours');
const ticketsField = byId('merchantBookingTickets');
let shopResources = [];
const tableMode = byId('merchantTableMode');
const dateField = byId('merchantTableDate');
const timeField = byId('merchantTableTime');
const actualTimeField = byId('merchantTableActualTime');
const guestField = byId('merchantTableGuests');
const bookingPayment = byId('merchantBookingPayment');
const tableSubmit = tableForm.querySelector('button[type="submit"]');
const categorySettings = byId('merchantCategorySettings');
const statCards = [...byId('merchantStats').querySelectorAll('strong')];
const settings = byId('merchantShopSettings');
const advancedSettings = byId('merchantAdvancedSettings');
const search = byId('merchantBookingSearch');
const publicLink = byId('merchantPublicLink');
const emailForm = byId('merchantEmailForm');
const emailSignIn = byId('merchantEmailSignIn');
const roleLabel = { owner: 'เจ้าของร้าน', admin: 'แอดมินร้าน', cashier: 'แคชเชียร์', staff: 'พนักงาน' };
let currentRole;
let displayedBookings = [];
let bookingTimezone;
const canEditLayout = () => ['owner', 'admin'].includes(currentRole);
const canManageTables = () => ['owner', 'admin', 'cashier'].includes(currentRole);

let bookingRequest = 0;
let pendingBooking;
let saving = false;

const actionErrors = {
  LINE_CUSTOMER_UNAVAILABLE: 'โปรไฟล์ LINE นี้ใช้ส่งจาก OA ของร้านไม่ได้ กรุณาค้นหาใหม่',
  BOOKING_PRICE_CHANGED: 'ยอดจองเปลี่ยนระหว่างทำรายการ โหลดหน้าร้านใหม่แล้วตรวจยอดก่อนบันทึก',
  COUNTER_PHONE_REQUIRED: 'ใส่เบอร์โทรลูกค้าเพื่อสร้าง QR รับชำระ',
  BOOKING_PAYMENT_UNAVAILABLE: 'ตรวจช่องทางรับเงินและราคาที่นั่งก่อนสร้าง QR',
  SLIP_BOOKING_UNAVAILABLE: 'รายการนี้หมดเวลาหรือยังไม่มีสลิปให้ยืนยัน',
  BOOKING_RESOURCE_IN_USE: 'จุดนี้ยังมีผู้ใช้บริการ กรุณาสิ้นสุดการใช้งานเดิมก่อน',
  BOOKING_SLOT_TAKEN: 'รายการนี้ถูกจองในช่วงเวลาดังกล่าวแล้ว',
  INVALID_BOOKING_DATE: 'เลือกเวลาในอนาคตและจองล่วงหน้าได้สูงสุด 90 วัน',
  INVALID_CAPACITY: 'จำนวนคนหรือจำนวนบัตรเกินที่กำหนด',
  INVALID_BOOKING: 'ตรวจจำนวนชั่วโมง จำนวนคน จำนวนบัตร และเบอร์โทรศัพท์',
  INVALID_TABLE_BOOKING: 'ตรวจจำนวนคนและเบอร์โทรศัพท์',
  INVALID_ACTUAL_BOOKING_DATE: 'เวลาเริ่มจริงต้องเป็นเวลาปัจจุบันหรือย้อนหลัง',
  INVALID_BOOKING_STATUS: 'เปลี่ยนสถานะไม่ได้ กรุณาตรวจสถานะล่าสุด',
  INVALID_CHECK_IN: 'เช็กอินได้ตั้งแต่ 30 นาทีก่อนเริ่มจนถึงก่อนหมดเวลาของรายการที่ยืนยันแล้ว',
  INVALID_TABLE_POSITION: 'ตำแหน่งโต๊ะต้องอยู่ระหว่าง 5 ถึง 95%',
  INVALID_STAFF_ROLE: 'ตรวจ UID และสิทธิ์ที่เลือก หรือบัญชีนี้อาจเป็นเจ้าของร้าน',
  INVALID_SHOP_SETTINGS: 'กรุณาตรวจชื่อร้าน',
  PLATFORM_SHOP_BOOKING_SUSPENDED: 'Superadmin ปิดรับจองออนไลน์ของร้านนี้ กรุณาติดต่อ Superadmin เพื่อเปิดอีกครั้ง',
  MERCHANT_BOOKING_FORBIDDEN: 'บัญชีนี้ไม่มีสิทธิ์จัดการการจองของร้าน'
};

function toggleTableSchedule() {
  const scheduled = tableMode.value === 'scheduled';
  const actual = tableMode.value === 'actual';
  const timezone = shopMenu.selectedOptions[0]?.dataset.timezone;
  if (timezone) {
    const today = actual ? dateAtShop(timezone) : businessDateAtShop(timezone);
    dateField.min = scheduled ? today : '';
    dateField.max = actual ? today : '';
    if ((scheduled || actual) && dateField.dataset.mode !== tableMode.value) dateField.value = today;
    if (actual && !actualTimeField.value) actualTimeField.value = timeAtShop(timezone);
  }
  dateField.dataset.mode = tableMode.value;
  for (const [field, enabled] of [[dateField,scheduled || actual],[timeField,scheduled],[actualTimeField,actual]]) {
    field.disabled = !enabled;
    field.parentElement.classList.toggle('hidden', !enabled);
  }
}

function updateTableCapacity() {
  const template = categoryMenu.selectedOptions[0]?.dataset.template;
  const capacity = Number(tableMenu.selectedOptions[0]?.dataset.capacity) || 100;
  for (const [field, active, max] of [
    [guestField, ['vip','table'].includes(template), Math.min(capacity, 100)],
    [hoursField, Boolean(template), template === 'seat' ? 6 : 5],
    [ticketsField, template === 'ticket', Math.min(capacity, 10)]
  ]) {
    field.disabled = !active;
    field.max = max;
    field.parentElement.classList.toggle('hidden', !active);
    if (Number(field.value) > max) field.value = max;
  }
}

function loadMerchantResources() {
  tableMenu.replaceChildren(...shopResources.filter(resource => resource.category_code === categoryMenu.value && resource.display?.archived !== true).map(resource => {
    const option = new Option(resource.name, resource.code);
    option.dataset.capacity = resource.capacity || 100;
    return option;
  }));
  updateTableCapacity();
  tableSubmit.disabled = saving || !tableMenu.value;
  updateBookingPayment();
}
categoryMenu.addEventListener('change', loadMerchantResources);

timeField.replaceChildren(...bookingTimeOptions());
function bookingCashAmount() {
  const category = categoryMenu.selectedOptions[0]?.dataset;
  if (!category || category.price === undefined) return null;
  const quantity = ['staff','vip','seat'].includes(category.template)
    ? Number(hoursField.value) : Number((category.template === 'ticket' ? ticketsField : guestField).value);
  return bookingPrice({template:category.template,price:category.price,
    service_fee:category.serviceFee,hour_promotions:JSON.parse(category.hourPromotions || '{}')},quantity).total;
}
function updateBookingPayment() {
  const cash = bookingPayment.value === 'cash';
  const amount = bookingCashAmount();
  tableSubmit.textContent = cash
    ? amount === 0 ? 'บันทึกการจอง' : 'ยืนยันรับเงินสดและบันทึกจอง'
    : 'สร้าง QR ให้ลูกค้าชำระ';
  const total = new Intl.NumberFormat('th-TH',{style:'currency',currency:'THB'}).format(amount);
  byId('merchantBookingPaymentHelp').textContent = cash
    ? amount === 0 ? 'รายการนี้ไม่มียอดชำระ'
      : amount === null ? 'กดยืนยันเมื่อรับเงินสดครบแล้ว' : 'รับเงินสด ' + total + ' ก่อนกดยืนยัน'
    : 'ให้ลูกค้าสแกน QR เพื่อชำระเงินและแนบสลิปบนเครื่องของลูกค้า';
}
bookingPayment.addEventListener('change', updateBookingPayment);
for (const field of [guestField,hoursField,ticketsField]) field.addEventListener('input',updateBookingPayment);
tableMode.addEventListener('change', toggleTableSchedule);
tableMenu.addEventListener('change', updateTableCapacity);

function showLogin(message = '') {
  passPanel.classList.add('hidden');
  byId('platformAdmin').classList.add('hidden');
  byId('platformShopList').replaceChildren();
  for (const id of ['platformSignup','platformBilling','merchantBusinessTools','merchantDailyReport']) byId(id).replaceChildren();
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
  accountPanel.classList.add('hidden');
  shopMenu.replaceChildren();
  publicLink.classList.add('hidden');
  tableMenu.replaceChildren();
  tableForm.reset();
  updateBookingPayment();
  toggleTableSchedule();
  tableEditor.open = false;
  categoryMenu.replaceChildren();
  shopResources = [];
  pendingBooking = undefined;
  actionStatus.textContent = '';
  bookings.replaceChildren();
  currentRole = undefined;
  displayedBookings = [];
  advancedSettings.replaceChildren();
  search.value = '';
  categorySettings.replaceChildren();
  dashboard.classList.add('hidden');
  login.classList.remove('hidden');
  status.textContent = message;
}

function bookingCard(booking, timezone, changeStatus, readSlip, client, refresh, showCounter) {
  const card = document.createElement('article');
  card.className = 'booking';
  const title = document.createElement('h3');
  title.textContent = shopResources.find(row => row.category_code === booking.category_code && row.code === booking.resource_code)?.name || booking.resource_code;
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
    booking.paid_cash ? 'รับเงินสดแล้ว' : '',
    currentRole === 'staff' ? '' : amount.format(booking.amount)
  ].filter(Boolean).join(' · ');
  const reference = document.createElement('small');
  reference.textContent = booking.id;
  card.append(title, details);
  if (booking.customer_name) {
    const customer = document.createElement('p');
    customer.textContent = 'ผู้จอง ' + booking.customer_name;
    card.append(customer);
  }
  card.append(reference);
  if (canManageTables()) {
    const attachment = document.createElement('details');
    const label = document.createElement('summary');
    label.textContent = 'ดูสลิปที่แนบ';
    attachment.append(label);
    attachment.addEventListener('toggle', async () => {
      if (!attachment.open || attachment.childElementCount > 1) return;
      const note = document.createElement('p');
      note.textContent = 'กำลังโหลดรูปสลิป…';
      attachment.append(note);
      try {
        const data = await readSlip(booking.id);
        if (!data?.image) {
          note.textContent = 'ยังไม่มีสลิปแนบ';
          return;
        }
        note.textContent = 'สลิปที่ลูกค้าแนบ · รอตรวจ';
        const image = document.createElement('img');
        image.className = 'booking-slip-image';
        image.alt = 'รูปสลิปที่ลูกค้าแนบ';
        image.src = data.image;
        attachment.append(image);
        addThunderCheck(attachment, client, booking.id, data, refresh);
      } catch {
        note.remove();
        label.textContent = 'เปิดสลิปอีกครั้งเพื่อโหลดใหม่';
      }
    });
    card.append(attachment);
  }
  if (['pending_payment','slip_review'].includes(booking.status)) {
    void counterPaymentRpc(client,'merchant_counter_payment_token',{
      p_shop_id:shopMenu.value,p_booking_id:booking.id
    }).then(token => {
      if (!token) return;
      const payment = document.createElement('button');
      payment.type = 'button';
      payment.className = 'btn soft small';
      payment.textContent = 'เปิด QR ให้ลูกค้า';
      payment.onclick = () => showCounter(token);
      card.append(payment);
      if (booking.status === 'slip_review' && canManageTables()) {
        const approve = document.createElement('button');
        approve.type = 'button';
        approve.className = 'btn primary small';
        approve.textContent = 'ยืนยันรับชำระแล้ว';
        approve.onclick = () => changeStatus(booking.id,'counter_paid');
        card.append(approve);
      }
    }).catch(() => {});
  }
  const isTable = booking.category_code === 'table' ||
    shopResources.some(row => row.category_code === booking.category_code && row.table === true);
  const start = new Date(booking.starts_at).getTime();
  const now = Date.now();
  const options = [];
  if ((isTable || currentRole !== 'staff') && booking.status === 'confirmed' && now >= start - 1800000 && now < new Date(booking.ends_at).getTime()) {
    options.push(['checked_in', 'เช็กอิน']);
  }
  if (canManageTables() && !['completed', 'cancelled'].includes(booking.status)) {
    const started = start <= now;
    if (!started && booking.status === 'pending_confirm') options.push(['confirmed', 'ยืนยันการจอง']);
    if (started && ['confirmed', 'checked_in'].includes(booking.status)) options.push(['completed', 'ใช้งานเสร็จ']);
    options.push(['cancelled', 'ยกเลิกการจอง']);
  }

  if (currentRole === 'staff' && isTable && booking.status === 'checked_in') options.push(['completed', 'สิ้นสุดการใช้โต๊ะ']);

  if (options.length) {
    const actions = document.createElement('div');
    actions.className = 'inline-actions';
    for (const [next, label] of options) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = next === 'cancelled' ? 'btn danger small' : 'btn soft small';
      button.textContent = label;
      button.addEventListener('click', () => {
        if (next !== 'cancelled' || window.confirm('ปฏิเสธหรือยกเลิกรายการและเปิดให้จองช่วงเวลานี้อีกครั้งใช่ไหม?')) {
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
  const remember = byId('merchantRememberDevice');
  const authStorage = {
    getItem(key) {
      return sessionStorage.getItem(key) ?? (key.endsWith('-code-verifier') ? null : localStorage.getItem(key));
    },
    setItem(key, value) {
      const shared = !key.endsWith('-code-verifier') &&
        (remember.checked || localStorage.getItem(key) !== null);
      if (shared) {
        localStorage.setItem(key, value);
        sessionStorage.removeItem(key);
      } else {
        sessionStorage.setItem(key, value);
      }
    },
    removeItem(key) {
      sessionStorage.removeItem(key);
      if (!key.endsWith('-code-verifier')) localStorage.removeItem(key);
    }
  };
  try { remember.checked = sessionStorage.getItem('reserveflow.remember-device') === 'yes'; } catch {}
  remember.addEventListener('change', () => {
    try { sessionStorage.setItem('reserveflow.remember-device', remember.checked ? 'yes' : 'no'); } catch {}
  });
  const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: { flowType: 'pkce', storage: authStorage }
  });

  const addShop = byId('merchantAddShop');
  const cancelAddShop = byId('merchantAddShopCancel');
  const registerLogout = byId('merchantRegisterSignOut');
  let addingShop = false;
  function setAdditionalShopMode(enabled) {
    addingShop = enabled;
    byId('merchantRegisterTitle').textContent = enabled ? 'เพิ่มร้านค้าด้วยบัญชีเดิม' : 'สมัครร้านค้าใหม่';
    byId('merchantRegisterHelp').textContent = enabled
      ? 'ร้านใหม่จะมีลิงก์จอง แพ็กเกจ เครดิตตรวจสลิป และ LINE OA แยกจากร้านเดิม'
      : 'ถ้าคุณเป็นทีมงาน ให้ส่งคำขอเข้าร้านแทนการสร้างร้านใหม่';
    byId('merchantJoinPanel').classList.toggle('hidden',enabled);
    registerLogout.classList.toggle('hidden',enabled);
    cancelAddShop.classList.toggle('hidden',!enabled);
  }
  const isPlatformAdmin = () => !byId('platformAdmin').classList.contains('hidden');
  addShop.onclick = () => {
    if (!isPlatformAdmin() && ![...shopMenu.options].some(shop => shop.dataset.role==='owner')) return;
    registerForm.reset();
    setAdditionalShopMode(true);
    registration.classList.remove('hidden');
    byId('merchantRegistrationUid').textContent = byId('merchantAccountUid').textContent;
    status.textContent = '';
    void showSignupPackages(client,byId('signupPackages'));
    registration.scrollIntoView({block:'start'});
    registerForm.elements.shopName.focus({preventScroll:true});
  };
  cancelAddShop.onclick = () => {
    setAdditionalShopMode(false);
    registration.classList.add('hidden');
    status.textContent = '';
    addShop.focus();
  };

  const recipientPicker = editBookingRecipient(client, byId('merchantBookingRecipient'));
  const passFeedback = byId('merchantPassStatus');
  const passDetails = byId('merchantPassDetails');
  const passConfirm = byId('merchantPassConfirm');
  const passRefresh = byId('merchantPassRefresh');
  let scannedShopId;
  passRefresh.onclick = openScannedPass;
  byId('merchantPassClose').onclick = () => {
    scanToken = null;
    try { sessionStorage.removeItem(scanKey); } catch {}
    passPanel.classList.add('hidden');
    void loadSession(scannedShopId);
  };

  async function openScannedPass() {
    if (!haveScan()) return;
    const token = scanToken;
    passPanel.classList.remove('hidden');
    passPanel.focus();
    passDetails.replaceChildren();
    passConfirm.disabled = true;
    passConfirm.classList.add('hidden');
    passRefresh.classList.add('hidden');
    passFeedback.textContent = 'กำลังตรวจบัตร…';
    const { data, error } = await client.rpc('get_merchant_booking_pass', { p_token: token });
    if (scanToken !== token) return;
    if (error || !data) {
      passFeedback.textContent = 'เปิดบัตรนี้ไม่ได้ กรุณาตรวจว่าบัตรเป็นของร้านที่คุณมีสิทธิ์';
      return;
    }
    scannedShopId = data.shop_id;
    renderPassDetails(passDetails, data);
    const pending = ['pending_payment', 'pending_confirm', 'slip_review'].includes(data.status);
    let message = passStatus(data);
    if (pending) message = 'รอร้านยืนยันการจองก่อนเช็กอิน';
    if (data.status === 'confirmed' && !data.can_check_in) {
      const [start, end] = data.period?.match(/\d{2}:\d{2}/g) || [];
      if (start && end) {
        const [hour, minute] = start.split(':').map(Number);
        const opening = (hour * 60 + minute + 1410) % 1440;
        const from = [Math.floor(opening / 60), opening % 60].map(part => String(part).padStart(2, '0')).join(':');
        message = 'เช็กอินได้ช่วง ' + from + '–' + end + ' น.';
      } else {
        message = 'เช็กอินได้ตั้งแต่ 30 นาทีก่อนเริ่มจนถึงเวลาสิ้นสุด';
      }
    }
    passFeedback.textContent = data.shop + ' · ' + message;
    passConfirm.classList.toggle('hidden', !pending && data.status !== 'confirmed');
    passConfirm.disabled = !data.can_check_in;
    passRefresh.classList.toggle('hidden', !pending && (data.status !== 'confirmed' || data.can_check_in));
    passConfirm.onclick = async () => {
      passConfirm.disabled = true;
      try {
        const result = await client.rpc('check_in_booking_pass', { p_token: token });
        if (result.error) throw result.error;
        await openScannedPass();
      } catch {
        if (scanToken === token) {
          passFeedback.textContent = error.message === 'BOOKING_RESOURCE_IN_USE'
            ? 'จุดนี้ยังมีผู้ใช้บริการ กรุณาสิ้นสุดการใช้งานเดิมก่อนเช็กอิน'
            : 'ยืนยันเช็กอินไม่ได้ กรุณาอัปเดตสถานะบัตร';
          passRefresh.classList.remove('hidden');
        }
      }
    };
  }

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
        actionStatus.textContent = actionErrors[error.message] || (error.code === '23P01' ? actionErrors.BOOKING_SLOT_TAKEN : '') || (error.code === 'PGRST202' ? 'ต้องอัปเดต SQL ระบบจองก่อนใช้งาน' : 'ยืนยันผลการบันทึกไม่ได้ กรุณาลองอีกครั้ง');
        await loadBookings();
      }
    } finally {
      saving = false;
      tableSubmit.disabled = !tableMenu.value;
    }
  }

  function showCounter(token) {
    return openMerchantCounterPayment(client,byId('merchantCounterPayment'),token);
  }

  function changeStatus(id, next) {
    if (next === 'counter_paid') return runAction(() =>
      counterPaymentRpc(client,'confirm_counter_booking_payment',{p_shop_id:shopMenu.value,p_booking_id:id}),
    'ยืนยันรับชำระแล้ว');
    if (next === 'checked_in') return runAction(store => store.checkIn(id), 'เช็กอินแล้ว');
    const message = next === 'confirmed' ? 'ยืนยันการจองแล้ว' : 'บันทึกว่าใช้งานเสร็จแล้ว';
    return runAction(store => store.changeTableStatus(id, next), message);
  }

  function renderBookingList() {
    const term = search.value.trim().toLowerCase();
    const rows = displayedBookings.filter(row => !term ||
      [row.id, row.resource_code, row.customer_name].some(value => value?.toLowerCase().includes(term)));
    if (rows.length) {
      bookings.replaceChildren(...rows.map(row => bookingCard(row, bookingTimezone, changeStatus, id =>
        createSupabaseStore(client, shopMenu.value).getBookingSlip(id), client, loadBookings, token => runAction(() => showCounter(token),'เปิดรายการรับชำระแล้ว'))));
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
      const [rows,cash] = await Promise.all([
        createSupabaseStore(client,shop.value).getBookings(),
        counterPaymentRpc(client,'merchant_cash_booking_ids',{p_shop_id:shop.value}).catch(() => [])
      ]);
      if (request !== bookingRequest) return;
      const cashIds = new Set(cash || []);
      displayedBookings = rows.map(row => ({...row,paid_cash:cashIds.has(row.id)}));
      const totals = [
        rows.length,
        rows.filter(row => row.status === 'pending_payment').length,
        rows.filter(row => row.status === 'pending_confirm').length,
        rows.filter(row => ['confirmed', 'checked_in'].includes(row.status)).length
      ];
      statCards.forEach((card, index) => { card.textContent = totals[index]; });
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

  const bankForm = byId('merchantBankAccountForm');
  const bankStatus = byId('merchantBankAccountStatus');
  const bankSave = bankForm.querySelector('button');

  async function loadBankAccount(shopId) {
    bankForm.reset();
    bankStatus.textContent = '';
    bankSave.disabled = true;
    if (currentRole !== 'owner') return;
    const {data,error} = await client.rpc('get_shop_bank_account',{p_shop_id:shopId});
    if (shopMenu.value !== shopId) return;
    if (error) {
      bankStatus.textContent = error.code === 'PGRST202' ? 'รัน SQL ไฟล์ 37 เพื่อเปิดการตั้งค่าบัญชีธนาคาร' : 'โหลดข้อมูลบัญชีธนาคารไม่ได้';
      return;
    }
    bankForm.elements.bank.value = data?.bank_name || '';
    bankForm.elements.holder.value = data?.holder_name || '';
    bankForm.elements.account.value = data?.account_number || '';
    bankSave.disabled = false;
  }

  bankForm.addEventListener('submit', async event => {
    event.preventDefault();
    if (bankSave.disabled || currentRole !== 'owner') return;
    const shopId = shopMenu.value;
    const fields = bankForm.elements;
    const number = fields.account.value.replace(/[\s-]/g,'');
    bankSave.disabled = true;
    const {error} = await client.rpc('save_shop_bank_account',{
      p_shop_id:shopId,p_bank:fields.bank.value,p_holder:fields.holder.value,p_number:number
    });
    if (shopMenu.value !== shopId) return;
    bankSave.disabled = false;
    bankStatus.textContent = error ? (error.message === 'INVALID_SHOP_BANK_ACCOUNT'
      ? 'ระบุธนาคาร ชื่อบัญชี และเลขบัญชี 6–20 หลักให้ครบ' : 'บันทึกบัญชีธนาคารไม่ได้')
      : number ? 'บันทึกบัญชีธนาคารแล้ว' : 'ปิดรับโอนทางบัญชีธนาคารแล้ว';
    if (!error) fields.account.value = number;
  });

  const promptPayForm = byId('merchantPromptPayForm');
  const promptPayMobile = byId('merchantPromptPayMobile');
  const promptPayStatus = byId('merchantPromptPayStatus');
  const savePromptPay = promptPayForm.querySelector('button');

  async function loadPromptPay(shopId) {
    savePromptPay.disabled = true;
    promptPayMobile.value = '';
    promptPayStatus.textContent = '';
    if (currentRole !== 'owner') return;
    const { data, error } = await client.from('shop_promptpay').select('mobile').eq('shop_id', shopId).maybeSingle();
    if (shopMenu.value !== shopId) return;
    if (error) {
      promptPayStatus.textContent = error.code === 'PGRST205' ? 'รัน SQL ไฟล์ 16 เพื่อเปิดการตั้งค่าพร้อมเพย์' : 'โหลดข้อมูลพร้อมเพย์ไม่ได้';
      return;
    }
    promptPayMobile.value = data?.mobile || '';
    savePromptPay.disabled = false;
  }

  promptPayForm.addEventListener('submit', async event => {
    event.preventDefault();
    if (savePromptPay.disabled || currentRole !== 'owner') return;
    const shopId = shopMenu.value;
    const mobile = promptPayMobile.value.replace(/[\s-]/g, '');
    savePromptPay.disabled = true;
    const { error } = await client.rpc('save_shop_promptpay', { p_shop_id: shopId, p_mobile: mobile });
    if (shopMenu.value !== shopId) return;
    savePromptPay.disabled = false;
    if (error) {
      promptPayStatus.textContent = ['INVALID_PROMPTPAY_PROXY','INVALID_PROMPTPAY_MOBILE'].includes(error.message)
        ? 'ใช้เบอร์มือถือ 10 หลักหรือเลขบัตรประชาชน 13 หลัก หากใส่เลขบัตรแล้วบันทึกไม่ได้ ให้อัปเดต SQL ไฟล์ 23' : 'บันทึกพร้อมเพย์ไม่ได้ กรุณาลองอีกครั้ง';
      return;
    }
    promptPayMobile.value = mobile;
    promptPayStatus.textContent = mobile ? 'บันทึกพร้อมเพย์แล้ว' : 'ปิด QR พร้อมเพย์แล้ว';
  });

  async function loadShop() {
    const counterPanel = byId('merchantCounterPayment');
    counterPanel.classList.add('hidden');
    counterPanel.replaceChildren();
    const shop = shopMenu.selectedOptions[0];
    if (!shop?.value) return;
    setShopUrl(shop);
    const request = ++bookingRequest;
    currentRole = shop.dataset.role;
    byId('merchantPromotionPanel').classList.toggle('hidden',!['owner','admin'].includes(currentRole));
    byId('merchantPromotionLink').href = './promotion-manager.html?' + new URLSearchParams({shop:shop.dataset.slug || ''});
    const report = byId('merchantDailyReport');
    report.replaceChildren();
    if (canManageTables()) renderDailyReport(client, report, shop.value, shop.dataset.timezone);
    renderBookingHistory(client, byId('merchantBookingHistory'), canManageTables() ? shop.value : null, shop.dataset.timezone);
    recipientPicker.reset(canManageTables() ? shop.value : null);
    publicLink.classList.toggle('hidden', !shop.dataset.slug);
    publicLink.href = './book.html?' + new URLSearchParams({ shop: shop.dataset.slug || '' });
    const roleHelp = {
      owner: 'ตั้งค่าร้านและทีมงาน จัดการการจอง และแพ็กเกจร้าน',
      cashier: 'จัดการจอง สลิป และรายงานรายวัน',
      admin: 'จัดการจอง สลิป รายงาน ผัง และรายการจอง',
      staff: 'เปิดโต๊ะ เช็กอิน และสิ้นสุดการใช้โต๊ะ'
    };
    byId('merchantRole').textContent = [roleLabel[currentRole],roleHelp[currentRole]].filter(Boolean).join(' · ');
    settings.classList.toggle('hidden', currentRole !== 'owner');
    tableEditor.classList.toggle('hidden', !canManageTables() && currentRole !== 'staff');
    tableEditor.querySelector('summary').textContent = currentRole === 'staff' ? 'เปิดโต๊ะให้ลูกค้า' : 'จองแทนลูกค้า';
    tableMode.querySelector('[value=scheduled]').disabled = currentRole === 'staff';
    const tools = byId('merchantBusinessTools');
    tools.replaceChildren();
    if (currentRole === 'owner') renderShopBusinessTools(client, tools, shop.value);
    byId('merchantShopName').value = shop.textContent;
    byId('merchantShopSlug').value = shop.dataset.slug || '';
    byId('merchantShopOpen').checked = shop.dataset.open === 'true';
    displayedBookings = [];
    advancedSettings.replaceChildren();
    categorySettings.replaceChildren();
    statCards.forEach(card => { card.textContent = '—'; });
    search.value = '';
    categoryMenu.replaceChildren();
    shopResources = [];
    pendingBooking = undefined;
    tableMenu.replaceChildren();
    tableSubmit.disabled = true;
    tableForm.reset();
    updateBookingPayment();
    toggleTableSchedule();
    dateField.value = businessDateAtShop(shop.dataset.timezone);
    actionStatus.textContent = '';
    bookings.textContent = 'กำลังโหลดข้อมูลร้าน…';
    teamSearch.value = '';
    teamStatus.textContent = '';
    void loadTeam();
    const lineSettings = byId('merchantLineSettings');
    lineSettings.replaceChildren();
    if (currentRole === 'owner') renderLineSettings(client, lineSettings, shop.value);
    void loadPromptPay(shop.value);
    void loadBankAccount(shop.value);

    try {
      const store = createSupabaseStore(client, shop.value);
      const [categories, resources, layouts, templateAccess] = await Promise.all([
        store.getCategories(), store.getResources(), canEditLayout() ? store.getLayouts() : Promise.resolve([]),
        currentRole === 'owner' ? client.rpc('editable_merchant_category_templates',{p_shop_id:shop.value}) : null
      ]);
      if (request !== bookingRequest) return;
      const editableTemplates = new Map((templateAccess?.data || []).map(row => [row.code,row.editable]));
      for (const category of categories) category.template_editable = editableTemplates.get(category.code);
      const tableCodes = new Set(categories.filter(category => ['table','seat'].includes(category.template)).map(category => category.code));
      shopResources = resources.map(resource => ({ ...resource, table: tableCodes.has(resource.category_code) }));
      categoryMenu.replaceChildren(...categories.filter(category => currentRole !== 'staff' || ['table','seat'].includes(category.template)).map(category => {
        const option = new Option(category.name || category.code, category.code);
        option.dataset.template = category.template;
        if (category.price != null) option.dataset.price = category.price;
        option.dataset.serviceFee = category.service_fee || 0;
        option.dataset.hourPromotions = JSON.stringify(category.hour_promotions || {});
        return option;
      }));
      loadMerchantResources();
      if (canEditLayout()) renderMerchantSettings(advancedSettings, { categoryContainer: categorySettings, categories, resources, layouts, owner: currentRole === 'owner',
        save: async (rpc, parameters) => {
          if (shopMenu.value !== shop.value) throw new Error('Shop changed');
          const { data, error } = await client.rpc(rpc, { ...parameters, p_shop_id: shop.value });
          if (error) throw error;
          return data;
        },
        reload: loadShop
      });
      updateTableCapacity();
      tableSubmit.disabled = saving || !tableMenu.value;
    } catch {
      if (request === bookingRequest) actionStatus.textContent = 'โหลดตัวเลือกการจองไม่ได้';
    }
    if (request === bookingRequest) await loadBookings();
  }

  tableForm.addEventListener('submit', event => {
    event.preventDefault();
    if (saving || !tableMenu.value) return;
    const category = categoryMenu.value;
    const resource = tableMenu.value;
    const template = categoryMenu.selectedOptions[0]?.dataset.template;
    const counter = bookingPayment.value === 'transfer';
    if (!counter && currentRole === 'staff' && template === 'seat' && tableMode.value === 'actual') {
      actionStatus.textContent = 'ให้แคชเชียร์หรือแอดมินบันทึกเวลาเริ่มย้อนหลังสำหรับที่นั่ง';
      return;
    }
    if (counter && tableMode.value === 'actual') {
      actionStatus.textContent = 'เลือกตอนนี้หรือจองล่วงหน้าเพื่อสร้าง QR';
      return;
    }
    const scheduled = tableMode.value === 'scheduled';
    const actual = tableMode.value === 'actual';
    const [hour, minute] = (actual ? actualTimeField : timeField).value.split(':').map(Number);
    const payload = {
      p_category_code: category, p_resource_code: resource,
      p_date: scheduled ? calendarSlotDate(dateField.value, timeField.value) : actual ? dateField.value : null,
      p_hour: scheduled || actual ? hour : null, p_minute: scheduled || actual ? minute : null,
      p_guests: guestField.disabled ? null : Number(guestField.value),
      p_hours: hoursField.disabled ? null : Number(hoursField.value),
      p_tickets: ticketsField.disabled ? null : Number(ticketsField.value),
      p_name: byId('merchantTableName').value, p_phone: byId('merchantTablePhone').value
    };
    const recipient = recipientPicker.recipient;
    const cashAmount = counter ? null : bookingCashAmount();
    const fingerprint = JSON.stringify([tableMode.value,payload,recipient?.line_user,counter,cashAmount]);
    if (pendingBooking?.fingerprint !== fingerprint) {
      pendingBooking = { fingerprint, id: crypto.randomUUID() };
    }
    const id = pendingBooking.id;
    const shopId = shopMenu.value;
    void runAction(async () => {
      const request = { ...payload, p_request_id: id, p_name: payload.p_name.trim() || recipient?.display_name || '' };
      if (counter) {
        const token = await counterPaymentRpc(client,'create_counter_booking_payment',{p_shop_id:shopId,p_request:request});
        if (shopMenu.value === shopId) await showCounter(token);
      } else {
        await counterPaymentRpc(client,'create_merchant_cash_booking',{
          p_shop_id:shopId,p_request:{...request,p_expected_amount:cashAmount},p_actual:actual,p_line_user:recipient?.line_user || null
        });
      }
      if (shopMenu.value !== shopId) return;
      if (!counter) {
        const panel = byId('merchantCounterPayment');
        panel.classList.add('hidden');
        panel.replaceChildren();
      }
      pendingBooking = undefined;
      byId('merchantTableName').value = '';
      byId('merchantTablePhone').value = '';
      recipientPicker.reset();
    }, counter ? 'สร้าง QR รับชำระแล้ว'
      : cashAmount === 0 ? 'บันทึกการจองแล้ว · ไม่มียอดชำระ' : 'บันทึกการจองและรับเงินสดแล้ว');
  });

  client.auth.onAuthStateChange(event => {
    if (event === 'SIGNED_OUT') showLogin();
  });

  async function loadSession(selectShopId) {
    try {
      const { data, error } = await client.auth.getSession();
      if (error) throw error;
      if (!data.session) {
        const params = new URLSearchParams(location.search);
        if (params.has('error') || params.has('error_code') || params.has('code')) {
          showLogin('เข้าสู่ระบบด้วย LINE ไม่สำเร็จ กรุณาลองอีกครั้ง');
        } else {
          showLogin();
        }
        return;
      }
      if (haveScan()) {
        login.classList.add('hidden');
        status.textContent = '';
        await openScannedPass();
        return;
      }
      byId('merchantAccountUid').textContent = data.session.user.id;
      await loadPlatformAdmin(client, () => loadSession());
      if (!byId('platformAdmin').classList.contains('hidden')) renderPlatformTools(client, () => addShop.click());
      const shops = await listMerchantShops(client);
      const urlShop = new URLSearchParams(location.search).get('shop');
      let loginShop;
      try {
        loginShop = sessionStorage.getItem(loginShopKey);
        sessionStorage.removeItem(loginShopKey);
      } catch {}
      const requested = selectShopId || urlShop || loginShop || shopMenu.value;
      if (requested && !urlShop && !selectShopId && loginShop) {
        const url = new URL(location.href);
        url.searchParams.set('shop',loginShop);
        history.replaceState(history.state,'',url);
      }
      setAdditionalShopMode(false);
      addShop.classList.toggle('hidden',!isPlatformAdmin() && !shops.some(shop => shop.role==='owner'));
      if (!shops.length && !requested) {
        accountPanel.classList.add('hidden');
        login.classList.add('hidden');
        dashboard.classList.add('hidden');
        registration.classList.toggle('hidden', !byId('platformAdmin').classList.contains('hidden'));
        void showSignupPackages(client, byId('signupPackages'));
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
      const selected = requested ? shops.find(shop => shop.id === requested || shop.slug === requested)
        : shops.length === 1 ? shops[0] : undefined;
      if (selected) shopMenu.value = selected.id;
      else {
        shopMenu.prepend(new Option('เลือกร้านค้าที่ต้องการเปิด','',true,true));
        shopMenu.options[0].disabled = true;
      }
      accountPanel.classList.remove('hidden');
      login.classList.add('hidden');
      registration.classList.add('hidden');
      registerForm.reset();
      dashboard.classList.toggle('hidden',!selected);
      status.textContent = selected ? '' : requested
        ? 'บัญชีนี้ไม่มีสิทธิ์เข้าร้านตามลิงก์ กรุณาเลือกร้านที่มีสิทธิ์หรือเข้าสู่ระบบด้วยบัญชีของร้านนั้น'
        : 'กรุณาเลือกร้านค้าก่อนเปิดหลังบ้าน';
      if (selected) await loadShop();
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
      const requestedShop = new URLSearchParams(location.search).get('shop');
      try {
        if (requestedShop) sessionStorage.setItem(loginShopKey,requestedShop);
        else sessionStorage.removeItem(loginShopKey);
      } catch {}
      const referral = new URLSearchParams(location.search).get('ref');
      if (referral) sessionStorage.setItem('reserveflow_signup_referral',referral);
      else if (new URLSearchParams(location.search).has('signup')) sessionStorage.removeItem('reserveflow_signup_referral');
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
    registerLogout.disabled = cancelAddShop.disabled = true;
    const additional = addingShop;
    status.textContent = 'กำลังสร้างร้าน…';
    try {
      const plan = byId('merchantSignupPlan').value || null;
      const args = {
        p_plan:plan,p_name:registerForm.elements.shopName.value.trim(),p_slug:registerForm.elements.slug.value.trim()
      };
      if (!additional) {
        const referral = new URLSearchParams(location.search).get('ref') || sessionStorage.getItem('reserveflow_signup_referral');
        args.p_referral = /^[a-f0-9]{8}(?:-[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(referral || '') ? referral : null;
      }
      const {data:createdShop,error} = await client.rpc(
        additional ? 'register_additional_platform_shop' : 'register_platform_shop', args
      );
      if (error) throw error;
      if (!additional) sessionStorage.removeItem('reserveflow_signup_referral');
      await loadSession(createdShop);
      if (!dashboard.classList.contains('hidden')) {
        actionStatus.textContent = 'สร้างร้านแล้ว เปิดรับจองได้จากเมนูตั้งค่าร้าน';
        const packages = byId('shopPackagePanel');
        if (plan && packages) {
          packages.open = true;
          packages.scrollIntoView({block:'start'});
        }
      }
    } catch (error) {
      const errors = {
        SHOP_OWNER_REQUIRED:'บัญชีนี้ต้องมีสิทธิ์เจ้าของร้านก่อนเพิ่มร้าน',
        SHOP_SLUG_TAKEN: 'ชื่อลิงก์นี้ถูกใช้แล้ว กรุณาเลือกชื่ออื่น',
        SHOP_MEMBERSHIP_EXISTS: 'บัญชีนี้มีร้านอยู่แล้ว กรุณารีเฟรชเพื่อเปิดหลังบ้าน',
        INVALID_SHOP_REGISTRATION: 'กรุณาตรวจชื่อร้านและชื่อสำหรับลิงก์จอง',
        PACKAGE_NOT_CONFIGURED: 'แพ็กเกจยังไม่พร้อม กรุณาเลือกทดลองฟรีหรือติดต่อ Superadmin'
      };
      status.textContent = errors[error.message] || (additional && error.code==='PGRST202'
        ? 'รัน SQL ไฟล์ 42 และ 43 ใน Supabase เพื่อเปิดการเพิ่มร้าน' : 'ยืนยันผลการสร้างร้านไม่ได้ กรุณาลองอีกครั้ง');
    } finally {
      registerSubmit.disabled = false;
      registerLogout.disabled = cancelAddShop.disabled = false;
    }
  });
  byId('platformSignOut').addEventListener('click', () => signOut.click());
  byId('merchantRegisterSignOut').addEventListener('click', () => signOut.click());
  void loadSession();

  shopMenu.addEventListener('change', () => {
    if (!shopMenu.value) return;
    dashboard.classList.remove('hidden');
    status.textContent = '';
    void loadShop();
  });
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
