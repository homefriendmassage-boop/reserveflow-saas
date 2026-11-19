import { highlightTable, renderFloor, showFloorMessage } from './customer-floor.js';
import { bookingTimeOptions, dateAtShop } from './booking-slots.js';
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
const categoryIcons = { table: '🍽️', seat: '💺', staff: '👤', vip: '🚪', ticket: '🎟️' };
const shopSlug = new URLSearchParams(location.search).get('shop');
const money = new Intl.NumberFormat('th-TH', { style: 'currency', currency: 'THB' });
let categories = [];
let pendingRequest;

const errorMessages = {
  BOOKING_OPTION_UNAVAILABLE: 'รายการนี้ไม่เปิดให้จองแล้ว กรุณารีเฟรชหน้า',
  INVALID_CAPACITY: 'จำนวนคนหรือจำนวนบัตรเกินที่กำหนด',
  INVALID_BOOKING_DATE: 'เลือกเวลาในอนาคตและจองล่วงหน้าได้สูงสุด 90 วัน',
  INVALID_BOOKING: 'กรุณาตรวจข้อมูลการจองและใช้เบอร์โทรศัพท์ไทย',
  INVALID_BOOKING_PRICE: 'ร้านยังไม่สามารถรับคำขอในราคานี้',
  BOOKING_RATE_LIMIT: 'เบอร์นี้ส่งคำขอครบ 5 รายการในชั่วโมงนี้แล้ว',
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

function updateEstimate() {
  const category = selectedCategory();
  const resource = category.resources.find(item => item.code === fields.resource.value);
  const { template } = category;
  setQuantity(fields.hours, ['staff', 'vip', 'seat'].includes(template), template === 'seat' ? 6 : 5);
  setQuantity(fields.guests, ['table', 'vip'].includes(template), Math.min(resource?.capacity ?? 100, 100));
  setQuantity(fields.tickets, template === 'ticket', Math.min(resource?.capacity ?? 10, 10));

  const units = template === 'table' ? fields.guests.value
    : template === 'ticket' ? fields.tickets.value : fields.hours.value;
  const duration = fields.hours.disabled ? 2 : Number(fields.hours.value);
  const hasDuration = ['staff','vip','seat'].includes(template);
  const [hour, minute] = fields.hour.value.split(':').map(Number);
  const endMinutes = hour * 60 + minute + duration * 60;
  const end = [Math.floor(endMinutes / 60) % 24, endMinutes % 60]
    .map(value => String(value).padStart(2, '0')).join(':') + (endMinutes >= 1440 ? ' (+1 วัน)' : '');
  const endField = document.getElementById('bookingEnd');
  endField.parentElement.classList.toggle('hidden', !hasDuration);
  endField.value = fields.hours.validity.valid && Number.isFinite(endMinutes) ? end : '—';
  document.getElementById('bookingSummaryCategory').textContent = category.name;
  document.getElementById('bookingSummaryResource').textContent = resource?.name || 'ยังไม่ได้เลือก';
  document.getElementById('bookingSummaryDate').textContent = [fields.date.value, fields.hour.value].join(' · ');
  estimate.textContent = resource
    ? money.format(Number(category.price) * Number(units) + Number(category.service_fee))
    : '—';
  submit.disabled = !resource || floorLoading || sending;
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
  const { data, error } = await client.rpc('booking_catalog', { p_shop_slug: shopSlug });
  if (error) throw error;
  if (!data?.categories.length) {
    status.textContent = 'ร้านนี้ยังไม่เปิดรับจองผ่านหน้าเว็บ';
    return;
  }

  categories = data.categories;
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
  fields.date.min = dateAtShop(data.timezone);
  fields.date.value = fields.date.min;
  fields.hour.value = '18:00';
  updateResources();
  status.textContent = '';
  form.classList.remove('hidden');

  let planRequest = 0;
  async function loadFloor() {
    const request = ++planRequest;
    const category = selectedCategory();
    floorLoading = false;
    const mapped = ['table', 'seat', 'vip'].includes(category.template);
    const itemLabel = ({ seat: 'ที่นั่ง', vip: 'ห้อง', table: 'โต๊ะ' })[category.template];
    selectionTitle.textContent = mapped ? `เลือก${itemLabel}จากผัง` : `เลือก${category.name.replace(/^จอง/, '')}`;
    selectionHint.textContent = mapped ? 'เลือกวันและจุดบนผัง แล้วกำหนดเวลา ระบบจะตรวจว่าจุดที่เลือกยังว่าง' : 'เลือกวัน เวลา และรายการที่ต้องการจอง';
    resourceField.classList.toggle('hidden', !resourceCards.classList.contains('hidden'));
    if (!mapped || !fields.date.value || !fields.date.checkValidity()
      || (['seat', 'vip'].includes(category.template) && !fields.hours.checkValidity())) {
      showFloorMessage('', false);
      updateEstimate();
      return;
    }
    for (const option of fields.resource.options) option.disabled = false;
    floorLoading = true;
    updateEstimate();
    showFloorMessage(`กำลังตรวจ${itemLabel}ว่าง…`);
    const [hour, minute] = fields.hour.value.split(':').map(Number);
    const args = {
      p_shop_slug: shopSlug, p_category_code: category.code,
      p_date: fields.date.value, p_hour: hour, p_minute: minute
    };
    try {
      const { data: plan, error } = category.template === 'table'
        ? await client.rpc('booking_table_plan', args)
        : await client.rpc('booking_resource_plan', { ...args, p_hours: Number(fields.hours.value) });
      if (request !== planRequest) return;
      if (error || !plan?.tables?.length) {
        showFloorMessage('ผังยังไม่พร้อม เลือกรายการจากช่องด้านบนได้');
        return;
      }
      const occupied = new Set(plan.tables.filter(table => table.occupied).map(table => table.code));
      for (const option of fields.resource.options) option.disabled = occupied.has(option.value);
      if (occupied.has(fields.resource.value)) fields.resource.value = '';
      renderFloor(plan, category.resources, fields.resource, category.template);
      resourceField.classList.add('hidden');
    } catch {
      if (request === planRequest) showFloorMessage('โหลดผังร้านไม่สำเร็จ');
    } finally {
      if (request === planRequest) {
        floorLoading = false;
        updateEstimate();
      }
    }
  }

  fields.category.addEventListener('change', () => {
    markCategory();
    updateResources();
    void loadFloor();
  });
  fields.date.addEventListener('change', loadFloor);
  fields.hour.addEventListener('change', loadFloor);
  fields.hours.addEventListener('change', () => {
    if (['seat', 'vip'].includes(selectedCategory().template)) void loadFloor();
  });
  void loadFloor();
  for (const field of [fields.resource, fields.hours, fields.guests, fields.tickets]) {
    field.addEventListener('input', updateEstimate);
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (sending || submit.disabled || !fields.resource.value) return;
    const count = field => field.disabled ? null : Number(field.value);
    const [hour, minute] = fields.hour.value.split(':').map(Number);
    const payload = {
      p_shop_slug: shopSlug, p_category_code: fields.category.value, p_resource_code: fields.resource.value,
      p_date: fields.date.value, p_hour: hour, p_minute: minute,
      p_hours: count(fields.hours), p_guests: count(fields.guests), p_tickets: count(fields.tickets),
      p_name: fields.customerName.value, p_phone: fields.customerPhone.value, p_note: fields.note.value
    };
    const fingerprint = JSON.stringify(payload);
    if (pendingRequest?.fingerprint !== fingerprint) {
      pendingRequest = { fingerprint, id: crypto.randomUUID() };
    }
    sending = true;
    const editable = [...fields, ...categoryTabs.children, ...document.querySelectorAll('#bookingFloor button, #bookingResourceCards button')].filter(field => !field.disabled);
    editable.forEach(field => { field.disabled = true; });
    submitStatus.textContent = 'กำลังส่งคำขอ…';

    try {
      const { data, error } = await client.rpc('submit_customer_booking', {
        p_request_id: pendingRequest.id, ...payload
      });
      if (error) throw error;
      form.reset();
      form.classList.add('hidden');
      pendingRequest = undefined;
      status.textContent = `ส่งคำขอแล้ว · รอร้านยืนยัน · ${money.format(data.amount)} · เลขจอง ${data.id}`;
    } catch (error) {
      submitStatus.textContent = errorMessages[error.message]
        || 'ยืนยันผลการส่งไม่ได้ ลองส่งข้อมูลเดิมอีกครั้งเพื่อป้องกันการจองซ้ำ';
    } finally {
      editable.forEach(field => { field.disabled = false; });
      sending = false;
      if (!form.classList.contains('hidden')) {
        updateEstimate();
        if (submitStatus.textContent === errorMessages.BOOKING_SLOT_TAKEN) void loadFloor();
      }
    }
  });
}

start().catch(() => {
  status.textContent = 'โหลดข้อมูลร้านไม่สำเร็จ กรุณารีเฟรชหน้า';
});
