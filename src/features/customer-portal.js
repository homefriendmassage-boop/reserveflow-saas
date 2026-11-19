import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';

const form = document.getElementById('publicBookingForm');
const title = document.getElementById('bookingTitle');
const status = document.getElementById('bookingStatus');
const estimate = document.getElementById('bookingEstimate');
const submit = document.getElementById('sendBooking');
const fields = form.elements;
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
    : 'หมวดนี้ยังไม่มีรายการให้จอง';
  submit.disabled = !resource;
}

function updateResources() {
  fields.resource.replaceChildren(...selectedCategory().resources.map(resource => {
    const label = [resource.name, resource.description].filter(Boolean).join(' · ');
    return new Option(label, resource.code);
  }));
  updateEstimate();
}

function dateAtShop(timezone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit'
  }).formatToParts(new Date()).map(part => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
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
  fields.hour.replaceChildren(...[10, 12, 14, 16, 18, 20, 22].map(hour => new Option(`${hour}:00`, hour)));
  fields.date.min = dateAtShop(data.timezone);
  fields.date.value = fields.date.min;
  updateResources();
  status.textContent = '';
  form.classList.remove('hidden');

  fields.category.addEventListener('change', updateResources);
  for (const field of [fields.resource, fields.hours, fields.guests, fields.tickets]) {
    field.addEventListener('input', updateEstimate);
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (submit.disabled) return;
    const count = field => field.disabled ? null : Number(field.value);
    const payload = {
      p_shop_slug: shopSlug, p_category_code: fields.category.value, p_resource_code: fields.resource.value,
      p_date: fields.date.value, p_hour: Number(fields.hour.value),
      p_hours: count(fields.hours), p_guests: count(fields.guests), p_tickets: count(fields.tickets),
      p_name: fields.customerName.value, p_phone: fields.customerPhone.value, p_note: fields.note.value
    };
    const fingerprint = JSON.stringify(payload);
    if (pendingRequest?.fingerprint !== fingerprint) {
      pendingRequest = { fingerprint, id: crypto.randomUUID() };
    }
    const editable = Array.from(fields).filter(field => !field.disabled);
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
