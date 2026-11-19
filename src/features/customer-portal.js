import { highlightTable, renderFloor, showFloorMessage } from './customer-floor.js';
import { bookingTimeOptions, dateAtShop } from './booking-slots.js';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';

const form = document.getElementById('publicBookingForm');
const title = document.getElementById('bookingTitle');
const status = document.getElementById('bookingStatus');
const estimate = document.getElementById('bookingEstimate');
const submit = document.getElementById('sendBooking');
const fields = form.elements;
const selection = document.getElementById('bookingSelection');
const contact = document.getElementById('bookingContact');
const continueButton = document.getElementById('bookingContinue');
const backButton = document.getElementById('bookingBack');
const summary = document.getElementById('bookingSelectionSummary');
let floorLoading = false;
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
  estimate.textContent = resource
    ? `ระยะเวลา ${duration} ชม. · ยอดโดยประมาณ ${money.format(Number(category.price) * Number(units) + Number(category.service_fee))}`
    : 'เลือกรายการว่างเพื่อดูยอดโดยประมาณ';
  continueButton.disabled = !resource || floorLoading;
  highlightTable(fields.resource.value);
}

function updateResources() {
  fields.resource.replaceChildren(new Option('เลือกรายการ', ''), ...selectedCategory().resources.map(resource => {
    const label = [resource.name, resource.description].filter(Boolean).join(' · ');
    return new Option(label, resource.code);
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
  fields.hour.replaceChildren(...bookingTimeOptions());
  fields.date.min = dateAtShop(data.timezone);
  fields.date.value = fields.date.min;
  updateResources();
  status.textContent = '';
  form.classList.remove('hidden');

  const selectionInputs = [fields.category, fields.date, fields.hour, fields.resource, fields.guests, fields.hours, fields.tickets];

  function showSelection() {
    contact.disabled = true;
    contact.classList.add('hidden');
    selection.classList.remove('hidden');
    continueButton.focus();
  }

  continueButton.addEventListener('click', () => {
    if (!selectionInputs.every(input => input.reportValidity()) || floorLoading) return;
    summary.textContent = [
      fields.resource.selectedOptions[0].text, fields.date.value, fields.hour.value, estimate.textContent
    ].join(' · ');
    selection.classList.add('hidden');
    contact.classList.remove('hidden');
    contact.disabled = false;
    document.getElementById('bookingContactTitle').focus();
  });
  backButton.addEventListener('click', showSelection);

  let planRequest = 0;
  async function loadFloor() {
    const request = ++planRequest;
    const category = selectedCategory();
    floorLoading = false;
    if (category.template !== 'table' || !fields.date.value || !fields.date.checkValidity()) {
      showFloorMessage('', false);
      updateEstimate();
      return;
    }
    for (const option of fields.resource.options) option.disabled = false;
    floorLoading = true;
    updateEstimate();
    showFloorMessage('กำลังตรวจโต๊ะว่าง…');
    const [hour, minute] = fields.hour.value.split(':').map(Number);
    try {
      const { data: plan, error } = await client.rpc('booking_table_plan', {
        p_shop_slug: shopSlug, p_category_code: category.code,
        p_date: fields.date.value, p_hour: hour, p_minute: minute
      });
      if (request !== planRequest) return;
      if (error || !plan) {
        showFloorMessage('ดูผังไม่ได้ในขณะนี้ เลือกโต๊ะจากช่องรายการได้');
        return;
      }
      const occupied = new Set(plan.tables.filter(table => table.occupied).map(table => table.code));
      for (const option of fields.resource.options) option.disabled = occupied.has(option.value);
      if (occupied.has(fields.resource.value)) fields.resource.value = '';
      renderFloor(plan, category.resources, fields.resource);
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
    updateResources();
    void loadFloor();
  });
  fields.date.addEventListener('change', loadFloor);
  fields.hour.addEventListener('change', loadFloor);
  void loadFloor();
  for (const field of [fields.resource, fields.hours, fields.guests, fields.tickets]) {
    field.addEventListener('input', updateEstimate);
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (contact.disabled || submit.disabled || !fields.resource.value) return;
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
    const editable = Array.from(fields).filter(field => field !== contact && !field.disabled);
    editable.forEach(field => { field.disabled = true; });
    status.textContent = 'กำลังส่งคำขอ…';

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
      if (error.message === 'BOOKING_SLOT_TAKEN') {
        showSelection();
        void loadFloor();
      }
      status.textContent = errorMessages[error.message]
        || 'ยืนยันผลการส่งไม่ได้ ลองส่งข้อมูลเดิมอีกครั้งเพื่อป้องกันการจองซ้ำ';
    } finally {
      editable.forEach(field => { field.disabled = false; });
    }
  });
}

start().catch(() => {
  status.textContent = 'โหลดข้อมูลร้านไม่สำเร็จ กรุณารีเฟรชหน้า';
});
