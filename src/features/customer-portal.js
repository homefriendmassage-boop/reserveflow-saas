import { merchantAuthStorage } from './merchant-auth-storage.js';
import { listMerchantShops } from '../data/supabase-store.js?v=platform-shop-management-43';
import { bookingPrice } from './booking-pricing.js';
import { initBookingLiff, submitLiffPayment } from './booking-liff.js?v=friendship-verification';
import { prepareSlipAttachment } from './customer-slip.js?v=manual-slip-review';
import { highlightTable, refreshFloorAvailability, renderFloor, showFloorMessage } from './customer-floor.js?v=next-available-start';
import { bookingTimeOptions, businessDateAtShop, calendarSlotDate, dateAtShop, nextBookingDate, timeAtShop } from './booking-slots.js?v=display-time-only';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';

const form = document.getElementById('publicBookingForm');
const title = document.getElementById('bookingTitle');
const status = document.getElementById('bookingStatus');
const estimate = document.getElementById('bookingEstimate');
const submit = document.getElementById('sendBooking');
const fields = form.elements;
const categoryTabs = document.getElementById('liveCategoryTabs');
const submitStatus = document.getElementById('bookingSubmitStatus');
const selectionTitle = document.getElementById('bookingSelectionTitle');
const selectionHint = document.getElementById('bookingSelectionHint');
const resourceCards = document.getElementById('bookingResourceCards');
const customerPhoto = /^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/;
const resourceField = document.getElementById('bookingResourceField');
let floorLoading = false;
let sending = false;
let checkingOffer = false;
const categoryIcons = { table: '🍽️', seat: '💺', staff: '👤', vip: '🚪', ticket: '🎟️' };
const pageParams = new URLSearchParams(location.search);
const shopSlug = pageParams.get('shop');
const throughLiff = pageParams.get('line') === '1' || pageParams.has('liff.state');
async function showMerchantLink() {
  const link = document.getElementById('bookingMerchantLink');
  try {
    // Keep the storefront's booking requests anonymous. This client checks the separate back-office session.
    const storage = merchantAuthStorage(() => sessionStorage.getItem('reserveflow.remember-device') === 'yes');
    const sessionKey = 'sb-' + new URL(SUPABASE_URL).hostname.split('.')[0] + '-auth-token';
    if (!storage.getItem(sessionKey)) return;
    const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
      auth: {flowType:'pkce',storage,detectSessionInUrl:false,autoRefreshToken:false}
    });
    const {data,error} = await client.auth.getSession();
    if (error || !data.session) return;
    const shops = (await listMerchantShops(client)).filter(shop => ['owner','admin','cashier','staff'].includes(shop.role));
    if (!shops.length) return;
    const merchant = new URL('./merchant.html',location.href);
    if (shops.some(shop => shop.slug === shopSlug)) merchant.searchParams.set('shop',shopSlug);
    link.href = merchant.href;
    link.classList.remove('hidden');
  } catch {
    // The public booking page stays available even when account storage is unavailable.
  }
}

void showMerchantLink();
const money = new Intl.NumberFormat('th-TH', { style: 'currency', currency: 'THB' });
let categories = [];
const offerPicker = document.getElementById('bookingOffer');
const offerField = document.getElementById('bookingOfferField');
const hoursMinus = document.getElementById('bookingHoursMinus');
const hoursPlus = document.getElementById('bookingHoursPlus');
let availableOffers = [];
let loadingOffers = true;
let selectedOfferId = '';
const selectedOffer = () => availableOffers.find(offer => offer.id === selectedOfferId);
let pendingRequest;

const errorMessages = {
  PROMOTION_UNAVAILABLE: 'โปรโมชั่นนี้ไม่พร้อมใช้งาน กรุณาเลือกใหม่',
  PROMOTION_SOLD_OUT: 'โปรโมชั่นนี้ครบจำนวนสิทธิ์แล้ว กรุณาเลือกใหม่',
  PROMOTION_QUOTE_EXPIRED: 'หมดเวลาจองสิทธิ์ กรุณาเริ่มรายการใหม่',
  PROMOTION_QUOTE_MISMATCH: 'ข้อมูลโปรโมชั่นเปลี่ยน กรุณาเริ่มรายการใหม่',
  BOOKING_LINE_UNAVAILABLE: 'เปิดการเชื่อม LINE ไม่ได้ กรุณาเปิดหน้าจองใหม่จากเมนู LINE ของร้าน',
  BOOKING_LINE_EXPIRED: 'การเชื่อม LINE หมดอายุ กรุณาเปิดหน้าจองใหม่จากเมนู LINE ของร้าน',
  BOOKING_PAYMENT_UNAVAILABLE: 'ร้านยังไม่ได้เปิดรับชำระพร้อมเพย์สำหรับรายการนี้',
  BOOKING_QUOTE_MISMATCH: 'กรุณาเริ่มรายการใหม่เพื่อเปิดช่องทางชำระเงิน',
  BOOKING_OPTION_UNAVAILABLE: 'รายการนี้ไม่เปิดให้จองแล้ว กรุณารีเฟรชหน้า',
  INVALID_CAPACITY: 'จำนวนคนหรือจำนวนบัตรเกินที่กำหนด',
  INVALID_BOOKING_DATE: 'เลือกเวลาในอนาคตและจองล่วงหน้าได้สูงสุด 90 วัน',
  INVALID_BOOKING: 'กรุณาตรวจข้อมูลการจองและใช้เบอร์โทรศัพท์ไทย',
  INVALID_BOOKING_PRICE: 'ร้านยังไม่สามารถรับคำขอในราคานี้',
  BOOKING_RATE_LIMIT: 'เบอร์นี้ส่งคำขอครบ 5 รายการในชั่วโมงนี้แล้ว',
  BOOKING_RESOURCE_IN_USE: 'จุดนี้ยังมีรายการที่ร้านยังไม่ปิด กรุณาเลือกจุดอื่นหรือรอให้ร้านปิดรายการ',
  BOOKING_SLOT_TAKEN: 'รายการนี้มีการจองทับช่วงเวลาที่เลือก กรุณาเลือกเวลาอื่น',
  BOOKING_REQUEST_MISMATCH: 'คำขอนี้เคยถูกส่งแล้ว กรุณารีเฟรชหน้าก่อนส่งใหม่'
};

function selectedCategory() {
  return categories.find(category => category.code === fields.category.value);
}

function setQuantity(field, visible, max) {
  field.disabled = !visible;
  field.parentElement.classList.toggle('hidden', !visible);
  if (visible) {
    field.max = max;
    if (Number(field.value) > max) field.value = max;
  }
}

function offersForHours(hours) {
  const exact = availableOffers.filter(offer => offer.hours === hours);
  if (exact.length) return exact;
  const highest = availableOffers.at(-1)?.hours;
  return hours > highest ? availableOffers.filter(offer => offer.hours === highest && offer.allows_extra_hours) : [];
}

function offerForHours(hours) {
  const offers = offersForHours(hours);
  return offers.find(offer => offer.id === selectedOfferId) || offers[0];
}

function offerTotal(category, offer, hours) {
  return (Math.round(Number(offer.price) * 100) + Math.round(Number(category.service_fee) * 100)
    + (hours - offer.hours) * Math.round(Number(category.price) * 100)) / 100;
}

function describeOffer(offer, hours, showGift = true) {
  const extras = hours - offer.hours;
  return offer.name + ' · แพ็กเกจ ' + offer.hours + ' ชม.'
    + (extras > 0 ? ' + ราคาปกติ ' + extras + ' ชม.' : '')
    + (showGift && offer.gift ? ' · รับ ' + offer.gift + ' 1 สิทธิ์' : '');
}

function updateEstimate() {
  const category = selectedCategory();
  const resource = category.resources.find(item => item.code === fields.resource.value);
  const { template } = category;
  const offer = selectedOffer();
  fields.hours.max = template === 'seat' ? 6 : 5;
  if (Number(fields.hours.value) > Number(fields.hours.max)) fields.hours.value = fields.hours.max;
  const lockHours = loadingOffers || checkingOffer || sending;
  hoursMinus.disabled = lockHours || Number(fields.hours.value) <= 1;
  hoursPlus.disabled = lockHours || Number(fields.hours.value) >= Number(fields.hours.max);
  setQuantity(fields.guests, ['table', 'vip'].includes(template), Math.min(resource?.capacity ?? 100, 100));
  setQuantity(fields.tickets, template === 'ticket', Math.min(resource?.capacity ?? 10, 10));

  const units = template === 'table' ? fields.guests.value
    : template === 'ticket' ? fields.tickets.value : fields.hours.value;
  const duration = Number(fields.hours.value);
  const [hour, minute] = fields.hour.value.split(':').map(Number);
  const endMinutes = hour * 60 + minute + duration * 60;
  const end = [Math.floor(endMinutes / 60) % 24, endMinutes % 60]
    .map(value => String(value).padStart(2, '0')).join(':');
  const endField = document.getElementById('bookingEnd');
  const validPeriod = !loadingOffers && Boolean(fields.hour.value) && duration > 0 &&
    (fields.hours.disabled || fields.hours.validity.valid);
  endField.value = validPeriod ? end : '—';
  document.getElementById('bookingSummaryResource').textContent = resource
    ? category.name + ' · ' + resource.name : 'ยังไม่ได้เลือก';
  document.getElementById('bookingSummaryDate').textContent = fields.date.value.split('-').reverse().join('/') || '—';
  document.getElementById('bookingSummaryTime').textContent = validPeriod
    ? fields.hour.selectedOptions[0].textContent + ' – ' + end : '—';
  document.getElementById('bookingSummaryHours').textContent = validPeriod ? duration + ' ชั่วโมง' : '—';
  const price = validPeriod ? (offer ? {
    total:offerTotal(category,offer,duration),packageHours:0
  } : bookingPrice(category,Number(units))) : null;
  estimate.textContent = price ? money.format(price.total) : '—';
  const savings = offer && price
    ? Math.max(0, Math.round(Number(category.price) * 100) * offer.hours - Math.round(Number(offer.price) * 100)) / 100
    : price?.savings;
  document.getElementById('bookingPromotion').textContent = price && offer?.gift
    ? offer.gift + ' · 1 สิทธิ์' : savings > 0 ? 'ส่วนลด ' + money.format(savings) : '';
  submit.disabled = !resource || !validPeriod || floorLoading || sending || checkingOffer;
  highlightTable(fields.resource.value);
  for (const card of resourceCards.children) {
    const selected = card.dataset.code === fields.resource.value;
    card.classList.toggle('selected', selected);
    card.setAttribute('aria-pressed', String(selected));
  }
}

function updateResources() {
  fields.resource.replaceChildren(new Option('เลือกรายการ', ''), ...selectedCategory().resources.map(resource => {
    const label = [resource.name, resource.description].filter(Boolean).join(' · ');
    return new Option(label, resource.code);
  }));
  const category = selectedCategory();
  const showCards = ['staff', 'ticket'].includes(category.template) && category.resources.length > 0;
  resourceCards.classList.toggle('hidden', !showCards);
  resourceCards.replaceChildren(...(showCards ? category.resources : []).map(resource => {
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'card-btn';
    card.dataset.code = resource.code;
    const details = document.createElement('span');
    for (const [tag, value] of [['strong',resource.name],['small',resource.position],['small',resource.description]]) {
      if (!value) continue;
      const line = document.createElement(tag);
      line.textContent = value;
      details.append(line);
    }
    if (category.template === 'staff') {
      const price = document.createElement('small');
      price.className = 'staff-hourly-price';
      price.textContent = money.format(Number(category.price)) + ' / ชั่วโมง'
        + (Number(category.service_fee) > 0 ? ' · ค่าบริการ ' + money.format(Number(category.service_fee)) + ' / การจอง' : '');
      details.append(price);
    }
    if (category.template === 'staff' && customerPhoto.test(resource.photo || '')) {
      const photo = document.createElement('img');
      photo.loading = 'lazy';
      photo.className = 'live-staff-photo';
      photo.alt = '';
      photo.src = resource.photo;
      card.append(photo);
    }
    card.append(details);
    card.addEventListener('click', () => {
      fields.resource.value = resource.code;
      fields.resource.dispatchEvent(new Event('input'));
    });
    return card;
  }));
  updateEstimate();
}

async function start() {
  if (!shopSlug || shopSlug.length > 100) {
    status.textContent = 'เปิดลิงก์จองที่ได้รับจากร้านค้า';
    return;
  }

  const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: { persistSession: false, detectSessionInUrl: false, autoRefreshToken: false }
  });
  const liffConfig = Promise.resolve(client.rpc('shop_booking_liff',{p_shop_slug:shopSlug})).catch(() => ({data:null}));
  const lineSession = throughLiff ? initBookingLiff(client,shopSlug) : Promise.resolve(null);
  const lineAction = document.getElementById('bookingLineAction');

  function showLineAction(url,text,message) {
    lineAction.href = url;
    lineAction.textContent = text;
    lineAction.classList.remove('hidden');
    submitStatus.textContent = message;
  }

  async function requireLineFriendship() {
    const {data:liffId} = await liffConfig;
    if (!throughLiff) {
      if (!liffId) return true;
      showLineAction('https://liff.line.me/' + liffId,'จองผ่าน LINE','เปิดหน้าจองผ่าน LINE เพื่อรับข้อความและบัตรจองในแชตของร้าน');
      return false;
    }
    const liff = await lineSession;
    if (!liff) throw new Error('BOOKING_LINE_UNAVAILABLE');
    if (!liff.isLoggedIn()) {
      const redirectUri = new URL('./book.html',location.href);
      redirectUri.search = new URLSearchParams({shop:shopSlug,line:'1'});
      liff.login({redirectUri:redirectUri.href});
      return false;
    }
    if (!liff.getIDToken() || !liff.getAccessToken()) throw new Error('BOOKING_LINE_EXPIRED');
    const friendship = await liff.getFriendship();
    if (friendship.friendFlag) return true;
    const {data:basicId} = await client.rpc('booking_line_friend_id',{p_shop_slug:shopSlug});
    if (/^@[A-Za-z0-9._-]{1,49}$/.test(basicId || '')) {
      showLineAction('https://line.me/R/ti/p/' + encodeURIComponent(basicId),'เพิ่มเพื่อน LINE ร้าน','เพิ่มเพื่อนแล้วกลับมากดแสดงช่องทางชำระเงินอีกครั้ง');
    } else submitStatus.textContent = 'เพิ่มเพื่อน LINE OA ของร้าน แล้วกลับมากดแสดงช่องทางชำระเงินอีกครั้ง';
    return false;
  }
  const { data, error } = await client.rpc('booking_catalog', { p_shop_slug: shopSlug });
  if (error) throw error;
  if (!data?.categories.length) {
    status.textContent = 'ร้านนี้ยังไม่เปิดรับจองผ่านหน้าเว็บ';
    return;
  }

  categories = data.categories;
  const dataCatalogTimezone = data.timezone;
  const draftKey = 'reserveflow.payment.v1:' + shopSlug;
  const passKey = 'reserveflow.last-pass:' + shopSlug;
  const passLink = document.getElementById('customerBookingPass');
  const lastPass = document.getElementById('lastCustomerBookingPass');
  const result = document.getElementById('customerBookingResult');
  const resultTitle = document.getElementById('customerBookingResultTitle');
  function showLastPass(token) {
    if (!token) return;
    lastPass.href = './booking-pass.html#' + encodeURIComponent(token);
    lastPass.classList.remove('hidden');
  }
  try { showLastPass(localStorage.getItem(passKey)); } catch {}
  document.getElementById('customerStartNewBooking').onclick = () => {
    result.classList.add('hidden');
    lastPass.classList.remove('hidden');
    form.classList.remove('hidden');
    void loadFloor();
    document.getElementById('date').focus();
  };
  let awaitingSlip = false;
  title.textContent = `ส่งคำขอจอง · ${data.name}`;
  fields.category.replaceChildren(...categories.map(category => new Option(category.name, category.code)));
  categoryTabs.replaceChildren(...categories.map(category => {
    const tab = document.createElement('button');
    tab.type = 'button';
    tab.dataset.category = category.code;
    tab.textContent = (categoryIcons[category.template] || '') + ' ' + category.name;
    tab.addEventListener('click', () => {
      if (fields.category.value === category.code) return;
      fields.category.value = category.code;
      fields.category.dispatchEvent(new Event('change'));
    });
    return tab;
  }));
  function markCategory() {
    for (const tab of categoryTabs.children) {
      const active = tab.dataset.category === fields.category.value;
      tab.classList.toggle('active', active);
      tab.setAttribute('aria-pressed', String(active));
    }
  }
  markCategory();
  fields.hour.replaceChildren(...bookingTimeOptions());
  function refreshCustomerSlot() {
    const initial = fields.date.value + ' ' + fields.hour.value;
    const now = new Date();
    const today = businessDateAtShop(dataCatalogTimezone, now);
    const nowDate = dateAtShop(dataCatalogTimezone, now);
    const time = timeAtShop(dataCatalogTimezone, now);
    fields.date.min = today;
    const resetTime = !fields.date.value || fields.date.value < today;
    if (resetTime) fields.date.value = today;
    for (const option of fields.hour.options) {
      const calendarDate = calendarSlotDate(fields.date.value, option.value);
      option.disabled = calendarDate + 'T' + option.value <= nowDate + 'T' + time;
    }
    let first = [...fields.hour.options].find(option => !option.disabled);
    if (!first) {
      fields.date.value = nextBookingDate(today);
      for (const option of fields.hour.options) option.disabled = false;
      first = fields.hour.options[0];
      fields.hour.value = first.value;
    }
    if (resetTime || !fields.hour.value || fields.hour.selectedOptions[0]?.disabled) fields.hour.value = first.value;
    return initial !== fields.date.value + ' ' + fields.hour.value;
  }
  refreshCustomerSlot();
  updateResources();
  status.textContent = '';
  form.classList.remove('hidden');

  let planRequest = 0;
  let liveAvailability = false;
  let refreshing = false;
  let floorLoadingCount = 0;
  const selectionSession = crypto.randomUUID();

  function slotArguments(category) {
    const [hour, minute] = fields.hour.value.split(':').map(Number);
    return { p_shop_slug: shopSlug, p_category_code: category.code,
      p_date: calendarSlotDate(fields.date.value, fields.hour.value), p_hour: hour, p_minute: minute };
  }

  let presenceUpdate = Promise.resolve();
  function syncSelection() {
    if (!liveAvailability) return presenceUpdate;
    presenceUpdate = presenceUpdate.catch(() => {}).then(async () => {
      const category = selectedCategory();
      const mapped = ['table', 'seat', 'vip'].includes(category.template);
      await client.rpc('mark_booking_selection', {
        ...slotArguments(category), p_session: selectionSession,
        p_resource_code: mapped && !sending && !awaitingSlip && !document.hidden ? fields.resource.value || null : null,
        p_hours: Number(fields.hours.value)
      });
    });
    return presenceUpdate;
  }

  async function loadFloor(quiet = false) {
    if (quiet && (refreshing || floorLoadingCount || sending || awaitingSlip || document.hidden)) return;
    if (quiet) refreshing = true;
    else floorLoadingCount++;
    try {
      await updateFloor(quiet);
    } finally {
      if (quiet) refreshing = false;
      else floorLoadingCount--;
    }
  }

  async function updateFloor(quiet) {
    const request = ++planRequest;
    const category = selectedCategory();
    floorLoading = false;
    const mapped = ['table', 'seat', 'vip'].includes(category.template);
    const itemLabel = ({ seat: 'ที่นั่ง', vip: 'ห้อง', table: 'โต๊ะ' })[category.template];
    selectionTitle.textContent = mapped ? `เลือก${itemLabel}จากผัง` : `เลือก${category.name.replace(/^จอง/, '')}`;
    selectionHint.textContent = mapped ? 'เลือกวันและจุดบนผัง แล้วกำหนดเวลา ระบบจะตรวจว่าจุดที่เลือกยังว่าง' : 'เลือกวัน เวลา และรายการที่ต้องการจอง';
    if (!quiet) resourceField.classList.toggle('hidden', !resourceCards.classList.contains('hidden'));
    if (!mapped || !fields.date.value || !fields.date.checkValidity()
      || !fields.hours.checkValidity()) {
      showFloorMessage('', false);
      updateEstimate();
      return;
    }
    if (!quiet) {
      for (const option of fields.resource.options) option.disabled = false;
      floorLoading = true;
      updateEstimate();
      showFloorMessage(`กำลังตรวจ${itemLabel}ว่าง…`);
    }
    const args = slotArguments(category);
    try {
      const { data: plan, error } = await client.rpc('booking_resource_plan', { ...args, p_hours: Number(fields.hours.value) });
      if (request !== planRequest || (quiet && (sending || awaitingSlip))) return;
      if (error || !plan?.tables?.length) {
        if (!quiet) showFloorMessage('ผังยังไม่พร้อม เลือกรายการจากช่องด้านบนได้');
        return;
      }
      const occupied = new Set(plan.tables.filter(table => table.occupied).map(table => table.code));
      for (const option of fields.resource.options) option.disabled = occupied.has(option.value);
      if (plan.tables.some(table => typeof table.availability === 'string')) {
        liveAvailability = true;
        document.querySelectorAll('.live-hold-legend').forEach(node => node.classList.remove('hidden'));
      }
      if (occupied.has(fields.resource.value)) {
        fields.resource.value = '';
        invalidateOfferCheck();
        renderOffers();
        void syncSelection();
      }
      if (quiet) refreshFloorAvailability(plan);
      else renderFloor(plan, category.resources, fields.resource, category.template, showNextAvailable);
      resourceField.classList.add('hidden');
    } catch {
      if (!quiet && request === planRequest) showFloorMessage('โหลดผังร้านไม่สำเร็จ');
    } finally {
      if (request === planRequest) {
        floorLoading = false;
        updateEstimate();
      }
    }
  }

  const nextStatus = document.getElementById('bookingNextStartStatus');
  const nextButton = document.getElementById('bookingNextStart');
  let nextRevision = 0;

  function clearNextAvailable() {
    ++nextRevision;
    nextStatus.textContent = '';
    nextButton.classList.add('hidden');
  }

  async function showNextAvailable(resource) {
    if (sending || awaitingSlip) return;
    clearNextAvailable();
    const revision = nextRevision;
    nextStatus.textContent = 'กำลังหาช่วงถัดไปสำหรับ ' + resource.name + '…';
    try {
      const {data: time,error} = await client.rpc('booking_resource_next_start', {
        p_shop_slug: shopSlug, p_category_code: fields.category.value,
        p_resource_code: resource.code, p_business_date: fields.date.value,
        p_after: fields.hour.value, p_hours: Number(fields.hours.value)
      });
      if (revision !== nextRevision) return;
      if (error) throw error;
      if (!time) {
        nextStatus.textContent = resource.name + ' ไม่มีช่วงว่างถัดไปที่จองได้ในรอบวันนี้';
        return;
      }
      const label = fields.hour.querySelector('option[value="' + time + '"]')?.textContent || time;
      nextStatus.textContent = resource.name + ' ว่างถัดไปเวลา ' + label;
      nextButton.textContent = 'เลือก ' + resource.name + ' เวลา ' + label;
      nextButton.classList.remove('hidden');
      nextButton.onclick = async () => {
        clearNextAvailable();
        invalidateOfferCheck();
        fields.hour.value = time;
        if (refreshCustomerSlot() || fields.hour.value !== time) {
          nextStatus.textContent = 'เวลาเดิมผ่านไปแล้ว กรุณาเลือกช่วงใหม่';
          void loadFloor();
          return;
        }
        fields.resource.value = resource.code;
        fields.resource.dispatchEvent(new Event('input'));
        await loadFloor();
        if (fields.resource.value !== resource.code) nextStatus.textContent = 'ช่วงนี้มีคนจองแล้ว กรุณาเลือกเวลาใหม่';
      };
    } catch {
      if (revision === nextRevision) nextStatus.textContent = 'ตรวจช่วงถัดไปไม่ได้ ลองเปลี่ยนเวลาเริ่มเพื่อดูผังอีกครั้ง';
    }
  }

  let offerRevision = 0;
  let offerCheck = 0;
  const offerStatus = document.getElementById('bookingOfferStatus');

  function renderOffers() {
    const hours = Number(fields.hours.value);
    const current = selectedOffer();
    const category = selectedCategory();
    const hourly = ['staff', 'seat', 'vip'].includes(category.template);
    const price = current ? offerTotal(category,current,hours)
      : hourly ? bookingPrice(category, hours).total : null;
    document.getElementById('bookingCurrentOffer').textContent = loadingOffers ? 'กำลังโหลดโปรโมชั่น…'
      : (current ? describeOffer(current,hours) : hours + ' ชั่วโมง') + (price === null ? '' : ' · ' + money.format(price));
    const currentOffers = offersForHours(hours);
    const nextHours = availableOffers.find(item => item.hours > hours)?.hours;
    const nextOffers = availableOffers.filter(offer => offer.hours === nextHours);
    const choices = [...currentOffers,...nextOffers];
    document.getElementById('bookingOfferListTitle').textContent = currentOffers.length
      ? 'แพ็กเกจสำหรับช่วงที่เลือก' : 'โปรถัดไปที่แนะนำ';
    offerField.classList.toggle('hidden', !choices.length || awaitingSlip);
    offerPicker.replaceChildren();
    if (awaitingSlip) return;
    for (const offer of choices) {
      const isCurrent = currentOffers.includes(offer);
      if (currentOffers.length && offer === nextOffers[0]) {
        const heading = document.createElement('h4');
        heading.textContent = 'โปรถัดไปที่แนะนำ';
        offerPicker.append(heading);
      }
      const bookingHours = isCurrent ? hours : offer.hours;
      const card = document.createElement('button');
      card.type = 'button';
      card.className = 'booking-offer-card';
      card.setAttribute('aria-pressed',String(offer.id === current?.id));
      const title = document.createElement('strong');
      title.textContent = offer.name;
      card.append(title);
      const details = document.createElement('small');
      const nextPrice = offerTotal(category,offer,bookingHours);
      const extra = nextPrice - price;
      details.textContent = bookingHours + ' ชั่วโมง · ' + money.format(nextPrice)
        + (category.template === 'seat' ? ' / ที่นั่ง' : '')
        + (price !== null && extra > 0 ? ' · เพิ่ม ' + money.format(extra) : '');
      card.append(details);
      if (offer.gift) {
        const gift = document.createElement('small');
        gift.textContent = 'ฟรี ' + offer.gift;
        card.append(gift);
      }
      card.onclick = () => void chooseHours(bookingHours,offer.id);
      offerPicker.append(card);
    }
  }

  async function chooseHours(hours, offerId) {
    if (sending || awaitingSlip || loadingOffers || checkingOffer || hours < 1 || hours > Number(fields.hours.max)) return;
    clearNextAvailable();
    const offer = offerId ? offersForHours(hours).find(item => item.id === offerId) : offerForHours(hours);
    if (offerId && !offer) return;
    const check = ++offerCheck;
    offerStatus.textContent = '';
    checkingOffer = false;
    const category = selectedCategory();
    const resource = fields.resource.value;
    if (resource && ['seat', 'vip'].includes(category.template)) {
      const args = slotArguments(category);
      offerStatus.textContent = 'กำลังตรวจที่ว่างสำหรับช่วงเวลานี้…';
      checkingOffer = true;
      updateEstimate();
      try {
        const {data, error} = await client.rpc('booking_resource_plan', {...args, p_hours: hours});
        if (check !== offerCheck || sending || awaitingSlip) return;
        if (error || !data?.tables?.some(table => table.code === resource && !table.occupied)) {
          offerStatus.textContent = 'ที่เลือกไว้ไม่ว่างครบ ' + hours + ' ชั่วโมง กรุณาเปลี่ยนเวลา หรือเลือกที่อื่น';
          return;
        }
      } catch {
        if (check === offerCheck) offerStatus.textContent = 'ตรวจที่ว่างไม่สำเร็จ กรุณาลองใหม่';
        return;
      } finally {
        if (check === offerCheck) {
          checkingOffer = false;
          updateEstimate();
        }
      }
    }
    offerStatus.textContent = '';
    selectedOfferId = offer?.id || '';
    fields.hours.value = hours;
    renderOffers();
    updateEstimate();
    void syncSelection();
    void loadFloor();
  }

  async function refreshOffers() {
    const requested = ++offerRevision;
    const category = selectedCategory();
    loadingOffers = ['staff', 'seat', 'vip'].includes(category.template);
    availableOffers = [];
    const feedback = document.getElementById('bookingOfferLoadStatus');
    feedback.textContent = '';
    selectedOfferId = '';
    renderOffers();
    updateEstimate();
    if (!loadingOffers) return;
    const results = await Promise.allSettled(Array.from({length:5}, (_, index) =>
      client.rpc('rf_booking_offers',{
        p_shop_slug:shopSlug,p_category_code:category.code,p_hours:index+1
      })));
    if (requested !== offerRevision) return;
    loadingOffers = false;
    if (results.some(result => result.status === 'rejected' || result.value.error)) {
      feedback.textContent = 'โหลดโปรโมชั่นได้ไม่ครบ กรุณารีเฟรชก่อนจองหากต้องการใช้โปรโมชั่น';
    }
    availableOffers = results.flatMap(result => result.status === 'fulfilled' && Array.isArray(result.value.data)
      ? result.value.data : []);
    selectedOfferId = offerForHours(Number(fields.hours.value))?.id || '';
    renderOffers();
    updateEstimate();
  }

  function invalidateOfferCheck() {
    clearNextAvailable();
    ++offerCheck;
    checkingOffer = false;
    offerStatus.textContent = '';
  }

  fields.customerPhone.addEventListener('input', () => {
    const digits = fields.customerPhone.value.replace(/[^0-9]/g, '').slice(0, 10);
    if (fields.customerPhone.value !== digits) fields.customerPhone.value = digits;
  });

  fields.category.addEventListener('change', () => {
    invalidateOfferCheck();
    markCategory();
    updateResources();
    void refreshOffers();
    void syncSelection();
    void loadFloor();
  });
  for (const input of [fields.date, fields.hour]) input.addEventListener('change', () => {
    invalidateOfferCheck();
    refreshCustomerSlot();
    void syncSelection();
    void loadFloor();
  });
  hoursMinus.onclick = () => void chooseHours(Number(fields.hours.value) - 1);
  hoursPlus.onclick = () => void chooseHours(Number(fields.hours.value) + 1);
  fields.resource.addEventListener('input', () => {
    invalidateOfferCheck();
    renderOffers();
    void syncSelection();
  });
  document.addEventListener('visibilitychange', () => void syncSelection());
  setInterval(() => {
    if (document.hidden || sending || awaitingSlip) return;
    if (refreshCustomerSlot()) {
      void syncSelection();
      void loadFloor();
      return;
    }
    if (!liveAvailability) return;
    void syncSelection();
    void loadFloor(true);
  }, 4000);
  for (const field of [fields.resource, fields.hours, fields.guests, fields.tickets]) {
    field.addEventListener('input', updateEstimate);
  }

  const paymentGrid = document.querySelector('.live-booking-grid');
  const paymentHidden = [
    categoryTabs, document.getElementById('bookingSelection'),
    ...document.querySelectorAll('#bookingContact > h2, #bookingContact > .sub, .live-booking-contact, #bookingContact > .summary')
  ];

  function openPayment(draft) {
    invalidateOfferCheck();
    awaitingSlip = true;
    offerField.classList.add('hidden');
    lineAction.classList.add('hidden');
    paymentGrid.classList.add('booking-payment-active');
    for (const element of paymentHidden) element.classList.add('hidden');
    submit.classList.add('hidden');
    submitStatus.textContent = 'รอแนบสลิปเพื่อส่งคำขอจอง';
    prepareSlipAttachment(client, draft, async image => {
      const payment = { p_request:draft.payload,p_amount:Number(draft.booking.amount),p_image:image };
      if (throughLiff) return submitLiffPayment(client,await lineSession,payment);
      const { data, error } = await client.rpc('submit_customer_payment',payment);
      if (error) throw error;
      return data;
    }, (message, saved) => {
      if (!saved && draft.payload.offer_id) {
        void client.rpc('rf_release_promotion_quote',{p_request:draft.payload});
      }
      try { localStorage.removeItem(draftKey); } catch {}
      pendingRequest = undefined;
      awaitingSlip = false;
      paymentGrid.classList.remove('booking-payment-active');
      form.reset();
      for (const element of paymentHidden) element.classList.remove('hidden');
      submit.classList.remove('hidden');
      fields.category.selectedIndex = 0;
      markCategory();
      fields.hour.value = '';
      refreshCustomerSlot();
      updateResources();
      void refreshOffers();
      if (saved?.pass_token) {
        try { localStorage.setItem(passKey, saved.pass_token); } catch {}
        showLastPass(saved.pass_token);
        passLink.href = lastPass.href;
        lastPass.classList.add('hidden');
        form.classList.add('hidden');
        result.classList.remove('hidden');
        document.getElementById('customerBookingResultStatus').textContent = message + (saved.line_linked ? ' · เชื่อม LINE แล้ว ระบบจะแจ้งสถานะในแชตของร้าน' : '') + ' · เลขจอง ' + saved.id;
        resultTitle.focus();
        return;
      }
      void loadFloor();
      submitStatus.textContent = saved ? message + ' · เลขจอง ' + saved.id : message;
      submitStatus.focus();
    });
  }

  let savedDraft;
  try {
    savedDraft = JSON.parse(localStorage.getItem(draftKey));
    if (savedDraft && (savedDraft.expires <= Date.now() || savedDraft.payload?.p_shop_slug !== shopSlug ||
        (!savedDraft.booking?.qr && !savedDraft.booking?.bank_account) || !savedDraft.label)) {
      localStorage.removeItem(draftKey);
      savedDraft = null;
    }
  } catch {}
  if (savedDraft && (throughLiff || !(await liffConfig).data)) openPayment(savedDraft);
  else void loadFloor();
  void refreshOffers();

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (awaitingSlip || sending || submit.disabled || !fields.resource.value || !form.reportValidity()) return;
    if (refreshCustomerSlot()) {
      submitStatus.textContent = 'เวลาเดิมผ่านไปแล้ว กรุณาตรวจรอบใหม่ก่อนส่ง';
      void syncSelection();
      void loadFloor();
      return;
    }
    const count = field => field.disabled ? null : Number(field.value);
    const [hour, minute] = fields.hour.value.split(':').map(Number);
    const payload = {
      p_shop_slug: shopSlug, p_category_code: fields.category.value, p_resource_code: fields.resource.value,
      p_date: calendarSlotDate(fields.date.value, fields.hour.value), p_hour: hour, p_minute: minute,
      p_hours: count(fields.hours), p_guests: count(fields.guests), p_tickets: count(fields.tickets),
      p_name: fields.customerName.value, p_phone: fields.customerPhone.value, p_note: fields.note.value,
      ...(selectedOffer() ? {offer_id:selectedOffer().id} : {})
    };
    const fingerprint = JSON.stringify(payload);
    if (pendingRequest?.fingerprint !== fingerprint) {
      pendingRequest = { fingerprint, id: crypto.randomUUID() };
    }
    sending = true;
    void syncSelection();
    const editable = [...fields, ...categoryTabs.children, ...document.querySelectorAll('#bookingFloor button, #bookingResourceCards button')]
      .filter(field => !field.disabled && !field.closest('#bookingSlip'));
    editable.forEach(field => { field.disabled = true; });
    submitStatus.textContent = 'กำลังเตรียมช่องทางชำระเงิน…';
    const category = selectedCategory();
    const resource = category.resources.find(row => row.code === payload.p_resource_code);
    const label = [category.name, resource?.name || payload.p_resource_code, document.getElementById('bookingSummaryDate').textContent,
      document.getElementById('bookingSummaryTime').textContent,
      document.getElementById('bookingSummaryHours').textContent, selectedOffer() && describeOffer(selectedOffer(),Number(fields.hours.value),false)].filter(Boolean).join(' · ');

    try {
      lineAction.classList.add('hidden');
      if (!await requireLineFriendship()) return;
      const request = { p_request_id: pendingRequest.id, ...payload };
      const { data, error } = await client.rpc('quote_customer_payment', { p_request: request });
      if (error) throw error;
      const expires = data.promotion?.held_until ? Date.parse(data.promotion.held_until) : Date.now()+86400000;
      const draft = {booking:data,payload:request,label,expires};
      try { localStorage.setItem(draftKey, JSON.stringify(draft)); } catch {}
      openPayment(draft);
    } catch (error) {
      submitStatus.textContent = errorMessages[error.message]
        || (error.code === 'PGRST202' ? 'ร้านยังไม่ได้เปิดใช้หน้าชำระเงิน' : 'โหลดช่องทางชำระเงินไม่ได้ กรุณาลองอีกครั้ง');
    } finally {
      sending = false;
      editable.forEach(field => { field.disabled = false; });
      if (!awaitingSlip) {
        updateEstimate();
        if ([errorMessages.BOOKING_SLOT_TAKEN,errorMessages.BOOKING_RESOURCE_IN_USE].includes(submitStatus.textContent)) void loadFloor();
      }
    }
  });
}

start().catch(() => {
  status.textContent = 'โหลดข้อมูลร้านไม่สำเร็จ กรุณารีเฟรชหน้า';
});
