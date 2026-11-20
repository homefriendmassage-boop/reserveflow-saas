import { dateAtShop } from './booking-slots.js';

function node(tag, text) {
  const element = document.createElement(tag);
  if (text) element.textContent = text;
  return element;
}

export function renderDailyReport(client, container, shopId, timezone) {
  const panel = node('section');
  panel.className = 'panel daily-report';
  const controls = node('div');
  controls.className = 'fields daily-report-controls';
  const dateField = node('div');
  dateField.className = 'field';
  const dateLabel = node('label', 'วันที่รายงาน');
  dateLabel.htmlFor = 'dailyReportDate';
  const date = node('input');
  date.type = 'date';
  date.id = 'dailyReportDate';
  date.min = '2000-01-01';
  date.value = date.max = dateAtShop(timezone);
  dateField.append(dateLabel,date);
  const groupField = node('div');
  groupField.className = 'field';
  const groupLabel = node('label', 'กลุ่ม LINE');
  groupLabel.htmlFor = 'dailyReportGroup';
  const group = node('select');
  group.id = 'dailyReportGroup';
  group.replaceChildren(new Option('กำลังโหลดกลุ่ม LINE', ''));
  groupField.append(groupLabel,group);
  const send = node('button', 'ส่งสรุปเข้า LINE กลุ่ม');
  send.type = 'button';
  send.className = 'btn primary';
  send.disabled = true;
  const refresh = node('button','รีเฟรชรายงาน');
  refresh.type = 'button';
  refresh.className = 'btn soft';
  const status = node('p');
  status.setAttribute('role','status');
  const summary = node('div');
  const currency = new Intl.NumberFormat('th-TH', { style:'currency', currency:'THB' });
  const number = new Intl.NumberFormat('th-TH');
  let request = 0;
  let loadedDate = '';
  let sending = false;

  controls.append(dateField,groupField,refresh,send);
  panel.append(node('h2','รายงานประจำวัน'),controls,summary,status);
  container.replaceChildren(panel);

  function updateSend() {
    send.disabled = sending || !group.value || loadedDate !== date.value;
  }

  async function load() {
    const current = ++request;
    loadedDate = '';
    summary.replaceChildren();
    updateSend();
    if (!date.value || !date.checkValidity()) return;
    const selected = date.value;
    status.textContent = 'กำลังโหลดรายงาน…';
    const { data, error } = await client.rpc('shop_daily_report',{p_shop_id:shopId,p_date:selected});
    if (current !== request) return;
    if (error || !data) {
      status.textContent = error?.code === 'PGRST202' ? 'รัน SQL ไฟล์ 20 เพื่อเปิดรายงาน' : 'โหลดรายงานไม่ได้ กรุณาลองใหม่';
      return;
    }
    const stats = node('div');
    stats.className = 'stats';
    for (const [label,value] of [
      ['ยอดรับที่ Thunder ยืนยัน',currency.format(data.verified_amount)],
      ['ยอดจองที่ยืนยันตามวันใช้บริการ',currency.format(data.booking_amount)],
      ['ยืนยัน / เข้าใช้ / เสร็จ',number.format(data.active)],
      ['รอชำระ / รอตรวจ / รอยืนยัน',number.format(data.pending)]
    ]) {
      const stat = node('div');
      stat.className = 'stat';
      stat.append(node('strong',value),node('span',label));
      stats.append(stat);
    }
    const note = node('p', 'ยอดรับนับตามวันโอนที่ Thunder ยืนยันพร้อมเวลาโอน ยอดจองนับตามวันเข้าใช้บริการ');
    note.className = 'sub';
    const overview = node('p', 'รวม ' + number.format(data.bookings) + ' รายการ · ยกเลิก ' +
      number.format(data.cancelled) + ' รายการ · ตรวจรับเงิน ' + number.format(data.verified_count) + ' รายการ');
    summary.replaceChildren(stats,note,overview);
    if (data.categories.length) {
      const table = node('table');
      table.className = 'daily-report-table';
      const head = table.createTHead().insertRow();
      for (const heading of ['หมวด','รายการ','ยกเลิก','ยอดจองที่ยืนยัน']) head.append(node('th',heading));
      const body = table.createTBody();
      for (const category of data.categories) {
        const row = body.insertRow();
        for (const value of [category.name,number.format(category.bookings),number.format(category.cancelled),
          currency.format(category.booking_amount)]) row.insertCell().textContent = value;
      }
      summary.append(table);
    }
    loadedDate = selected;
    status.textContent = '';
    updateSend();
  }

  date.addEventListener('change', load);
  refresh.addEventListener('click',load);
  group.addEventListener('change', updateSend);
  send.addEventListener('click', async () => {
    if (send.disabled || !confirm('ส่งสรุปวันที่ ' + date.value + ' ไปยังกลุ่ม LINE ที่เลือกหรือไม่?')) return;
    const selected = date.value;
    sending = true;
    updateSend();
    try {
      const { error } = await client.rpc('send_shop_daily_report',{
        p_shop_id:shopId,p_date:selected,p_target_id:group.value
      });
      status.textContent = error ? 'ส่งรายงานเข้าคิวไม่ได้ กรุณาตรวจการเชื่อมกลุ่ม LINE'
        : 'รายงานวันที่ ' + selected + ' เข้าคิวส่ง LINE แล้ว';
    } catch {
      status.textContent = 'ส่งรายงานเข้าคิวไม่ได้ กรุณาลองอีกครั้ง';
    } finally {
      sending = false;
      updateSend();
    }
  });
  void load();
  void client.rpc('shop_daily_report_groups',{p_shop_id:shopId}).then(({data,error}) => {
    if (error || !data?.length) {
      group.replaceChildren(new Option('เชื่อมกลุ่ม LINE ในตั้งค่าร้านก่อน',''));
    } else {
      const format = new Intl.DateTimeFormat('th-TH',{dateStyle:'short',timeStyle:'short',timeZone:timezone});
      group.replaceChildren(new Option('เลือกกลุ่ม LINE',''),...data.map((item,index) =>
        new Option('กลุ่ม ' + (index+1) + ' · เชื่อมเมื่อ ' + format.format(new Date(item.created_at)),item.id)));
    }
    updateSend();
  });
}
