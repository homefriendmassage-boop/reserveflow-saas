import { businessDateAtShop } from './booking-slots.js?v=business-day-1';

const create = (tag, label = '') => Object.assign(document.createElement(tag), { textContent: label });

export function editBookingRecipient(client, panel) {
  const form = panel.querySelector('form');
  const input = panel.querySelector('input');
  const results = panel.querySelector('[role=list]');
  const feedback = panel.querySelector('[role=status]');
  let shopId;
  let recipient;
  let sequence = 0;

  function reset(nextShopId = shopId) {
    shopId = nextShopId;
    recipient = null;
    sequence++;
    form.reset();
    results.replaceChildren();
    feedback.textContent = '';
    panel.classList.toggle('hidden', !shopId);
    panel.open = false;
  }

  input.addEventListener('input', () => {
    sequence++;
    recipient = null;
    results.replaceChildren();
    feedback.textContent = '';
  });
  form.addEventListener('reset', () => {
    sequence++;
    recipient = null;
    results.replaceChildren();
    feedback.textContent = '';
  });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    const term = input.value.trim();
    if (!term || !shopId) return;
    const request = ++sequence;
    feedback.textContent = 'กำลังค้นหา…';
    try {
      const { data, error } = await client.rpc('search_shop_line_customers',{p_shop_id:shopId,p_search:term});
      if (request !== sequence) return;
      if (error) throw error;
      feedback.textContent = data.length ? '' : 'ไม่พบลูกค้า ให้ลูกค้าส่งคำว่า ลงทะเบียนลูกค้า ในแชตส่วนตัวกับ LINE OA ของร้าน';
      results.replaceChildren(...data.map(customer => {
        const row = create('div');
        row.setAttribute('role','listitem');
        const choose = create('button', customer.display_name + ' · ' + customer.line_user);
        choose.type = 'button';
        choose.className = 'btn soft';
        if (customer.picture_url) {
          const photo = create('img');
          Object.assign(photo,{src:customer.picture_url,alt:'',width:32,height:32,loading:'lazy',referrerPolicy:'no-referrer'});
          choose.prepend(photo);
        }
        choose.onclick = () => {
          input.value = customer.display_name;
          recipient = customer;
          results.replaceChildren();
          feedback.textContent = 'เลือก ' + customer.display_name + ' แล้ว';
        };
        row.append(choose);
        return row;
      }));
    } catch {
      if (request === sequence) feedback.textContent = 'ค้นหาลูกค้า LINE ไม่สำเร็จ';
    }
  });
  return { reset, get recipient() { return recipient; } };
}

export function renderBookingHistory(client, panel, shopId, timezone) {
  const form = panel.querySelector('form');
  const results = panel.querySelector('[role=list]');
  const feedback = panel.querySelector('[role=status]');
  const date = businessDateAtShop(timezone);
  const dateTime = new Intl.DateTimeFormat('th-TH',{timeZone:timezone,dateStyle:'short',timeStyle:'short'});
  const statusNames = {
    pending_payment:'รอชำระ',pending_confirm:'รอยืนยัน',slip_review:'รอตรวจสลิป',
    confirmed:'จองแล้ว',checked_in:'เช็กอินแล้ว',completed:'ใช้งานเสร็จ',cancelled:'ยกเลิก'
  };
  let sequence = 0;
  panel.classList.toggle('hidden', !shopId);
  panel.open = false;
  form.reset();
  results.replaceChildren();
  feedback.textContent = '';
  form.elements.from.value = form.elements.to.value = date;
  form.onsubmit = async event => {
    event.preventDefault();
    if (!shopId) return;
    const request = ++sequence;
    feedback.textContent = 'กำลังค้นหา…';
    try {
      const { data, error } = await client.rpc('find_merchant_booking_history',{
        p_shop_id:shopId,p_from:form.elements.from.value,p_to:form.elements.to.value,p_search:form.elements.term.value
      });
      if (request !== sequence || panel.dataset.shop !== shopId) return;
      if (error) throw error;
      feedback.textContent = data.length ? (data.length===100 ? 'พบอย่างน้อย 100 รายการ กรุณาลดช่วงวันที่เพื่อดูเพิ่มเติม' : '') : 'ไม่พบรายการจองในช่วงที่ค้นหา';
      results.replaceChildren(...data.map(booking => {
        const row = create('article');
        row.className = 'booking';
        row.setAttribute('role','listitem');
        row.append(create('strong',[booking.resource_code,booking.customer_name].filter(Boolean).join(' · ')),
          create('p',dateTime.format(new Date(booking.starts_at))+' · '+(statusNames[booking.status] || booking.status)),
          create('code',booking.id));
        return row;
      }));
    } catch {
      if (request === sequence && panel.dataset.shop === shopId) {
        feedback.textContent = 'ค้นหาไม่ได้ กรุณาตรวจว่าช่วงวันที่ไม่เกิน 93 วัน';
      }
    }
  };
  panel.dataset.shop = shopId || '';
}
