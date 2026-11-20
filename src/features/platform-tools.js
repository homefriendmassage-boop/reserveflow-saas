import { promptPayPayload } from './promptpay.js';

const labels = { monthly:'รายเดือน', quarterly:'3 เดือน', half_year:'6 เดือน', yearly:'รายปี' };
const money = value => new Intl.NumberFormat('th-TH', { style:'currency',currency:'THB' }).format(value);
const date = value => new Date(value).toLocaleString('th-TH', { timeZone:'Asia/Bangkok' });
const stateLabels = { pending:'รอตรวจ', approved:'อนุมัติแล้ว', rejected:'ปฏิเสธ' };

function node(tag, text = '') {
  const result = document.createElement(tag);
  result.textContent = text;
  return result;
}

async function rpc(client, name, args = {}) {
  const { data, error } = await client.rpc(name, args);
  if (error) throw error;
  return data;
}

function button(text, action, status) {
  const el = node('button', text);
  el.type = 'button';
  el.className = 'btn soft small';
  el.addEventListener('click', async () => {
    el.disabled = true;
    try { await action(); }
    catch {
      status.textContent = 'ทำรายการไม่สำเร็จ ตรวจการตั้งค่า สิทธิ์ หรือเลขอ้างอิงซ้ำ แล้วลองอีกครั้ง';
    } finally { el.disabled = false; }
  });
  return el;
}

function detail(title) {
  const panel = node('details');
  panel.className = 'merchant-settings-panel';
  panel.append(node('summary', title));
  return panel;
}

function field(label, control) {
  const wrapper = node('label');
  wrapper.className = 'field platform-field';
  wrapper.append(node('span',label),control);
  return wrapper;
}

function qr(container, text) {
  container.replaceChildren();
  new window.QRCode(container, { text, width:180,height:180 });
}

function referralPanel(client, shopId) {
  const panel = detail(shopId ? 'แชร์แนะนำร้านค้า' : 'สมัครร้านใหม่และแชร์ใบสมัคร');
  const link = new URL('./merchant.html', location.href);
  link.searchParams.set('signup','1');
  if (shopId) link.searchParams.set('ref',shopId);
  const url = node('input');
  url.value = link.href;
  url.readOnly = true;
  const feedback = node('p');
  feedback.setAttribute('role','status');
  const image = node('div');
  const line = node('select');
  const visit = node('a','เปิดใบสมัครร้านค้า');
  visit.href = link.href;
  visit.className = 'btn soft small';
  panel.append(field('ลิงก์สมัครร้าน',url),
    button('คัดลอกลิงก์',async () => {
      try { await navigator.clipboard.writeText(link.href); feedback.textContent = 'คัดลอกแล้ว'; }
      catch { url.select(); feedback.textContent = 'เลือกข้อความแล้ว กดคัดลอกจากเบราว์เซอร์'; }
    },feedback),
    button('แสดง QR ใบสมัคร',() => qr(image,link.href),feedback),
    visit, image, field('ปลายทาง LINE ที่เชื่อมไว้',line),
    button('ส่ง Flex ไป LINE เพื่อส่งต่อ',async () => {
      if (!line.value) { feedback.textContent = 'เชื่อมปลายทาง LINE และเลือกผู้รับก่อนส่ง'; return; }
      if (!confirm('ส่ง Flex ใบสมัครไปยังปลายทาง LINE ที่เลือกหรือไม่?')) return;
      await rpc(client,'send_referral_flex',{p_shop_id:shopId,p_target_id:line.value});
      feedback.textContent = 'เข้าคิวส่ง Flex แล้ว เปิดแชต LINE เพื่อส่งต่อใบสมัครให้เพื่อน';
    },feedback),feedback);
  panel.addEventListener('toggle',async () => {
    if (!panel.open) return;
    try {
      const targets = await rpc(client,'list_line_targets',{p_shop_id:shopId});
      line.replaceChildren(new Option('เลือกปลายทาง',''),...targets.map(target => new Option(
        (target.target_type==='group'?'กลุ่ม LINE':'LINE ส่วนตัว')+' · '+date(target.created_at),target.id)));
    } catch { feedback.textContent = 'โหลดปลายทาง LINE ไม่ได้'; }
  });
  return panel;
}

export async function showSignupPackages(client, container) {
  try {
    const data = await rpc(client,'platform_package_prices');
    const select=document.getElementById('merchantSignupPlan');
    select.replaceChildren(new Option('ทดลองฟรี 7 วัน',''),
      ...Object.entries(labels).filter(([key]) => data.payments_enabled && data.prices[key])
        .map(([key,label]) => new Option(label+' · '+money(data.prices[key]),key)));
    container.textContent = [
      'ทดลองฟรี 7 วัน',
      ...Object.entries(labels).map(([key,label]) => label + (data.prices[key] ? ' ' + money(data.prices[key]) : ' · รอตั้งราคา'))
    ].join(' / ');
  } catch { container.textContent = 'ทดลองฟรี 7 วัน'; }
}

export function renderShopBusinessTools(client, container, shopId) {
  const panel = detail('แพ็กเกจและต่ออายุ');
  panel.id = 'shopPackagePanel';
  const body = node('div');
  const feedback = node('p');
  feedback.setAttribute('role','status');
  panel.append(body,feedback);
  container.append(referralPanel(client,shopId),panel);
  async function load() {
    const data = await rpc(client,'shop_package_overview',{p_shop_id:shopId});
    const pricing = await rpc(client,'platform_package_prices');
    const plan = node('select');
    plan.replaceChildren(...Object.entries(labels).filter(([key]) => pricing.payments_enabled && pricing.prices[key])
      .map(([key,label]) => new Option(label+' · '+money(pricing.prices[key]),key)));
    const current = data.orders.find(order => order.state==='pending');
    body.replaceChildren(
      node('p',data.expires_at?'ใช้งานได้ถึง '+date(data.expires_at):'ร้านเดิม · ยังไม่มีวันหมดอายุในระบบแพ็กเกจ'),
      node('p','ค่าแนะนำรอจ่าย '+money(data.unpaid_referral)),
      ...data.orders.map(order => node('p',labels[order.plan]+' · '+money(order.amount)+' · '+stateLabels[order.state])));
    if (!current && plan.options.length) {
      body.append(field('เลือกแพ็กเกจ',plan),button('สร้างรายการชำระแพ็กเกจ',async () => {
        await rpc(client,'open_package_order',{p_shop_id:shopId,p_plan:plan.value});
        await load();
      },feedback));
    } else if (!current) {
      body.append(node('p','กำลังรอ Superadmin ตั้งราคาแพ็กเกจ'));
    }
    if (current) {
      body.append(node('h3',labels[current.plan]+' · '+money(current.amount)));
      if (current.has_slip) { body.append(node('p','ส่งสลิปแล้ว · รอ Superadmin ตรวจ')); return; }
      const image = node('div');
      qr(image,promptPayPayload(current.receiving_mobile,Number(current.amount)));
      const file = node('input');
      file.type = 'file';
      file.accept = 'image/jpeg,image/png,image/webp';
      const preview = node('img');
      preview.alt = 'ตัวอย่างสลิป';
      preview.className = 'booking-slip-image hidden';
      file.addEventListener('change', () => {
        const previous = preview.getAttribute('src');
        if (previous) URL.revokeObjectURL(previous);
        if (file.files[0]) preview.src = URL.createObjectURL(file.files[0]);
        preview.classList.toggle('hidden',!file.files[0]);
      });
      body.append(image,field('แนบสลิปแพ็กเกจ',file),preview,button('ยกเลิกรายการที่ยังไม่ชำระ',async () => {
        if (!confirm('ยกเลิกรายการแพ็กเกจนี้หรือไม่? หากโอนแล้วให้ส่งสลิปแทน')) return;
        await rpc(client,'cancel_unpaid_package_order',{p_order_id:current.id});
        await load();
      },feedback),button('ส่งสลิปแพ็กเกจ',async () => {
        const chosen = file.files[0];
        if (!chosen || chosen.size > 1024*1024 || !['image/jpeg','image/png','image/webp'].includes(chosen.type)) {
          feedback.textContent = 'เลือกภาพ JPG, PNG หรือ WebP ขนาดไม่เกิน 1 MB';
          return;
        }
        const reader = new FileReader();
        const contents = await new Promise((resolve,reject) => {
          reader.onload = () => resolve(reader.result);
          reader.onerror = reject;
          reader.readAsDataURL(chosen);
        });
        await rpc(client,'submit_package_slip',{p_order_id:current.id,p_image:contents});
        URL.revokeObjectURL(preview.src);
        await load();
        feedback.textContent = 'ส่งสลิปแล้ว';
      },feedback));
    }
  }
  panel.addEventListener('toggle',() => {
    if (panel.open) load().catch(() => { feedback.textContent = 'เปิดระบบแพ็กเกจด้วย SQL ไฟล์ 19'; });
  });
}

export function renderPlatformTools(client) {
  const signup = document.getElementById('platformSignup');
  const referral = referralPanel(client,null);
  const create = button('สร้างร้านค้าใหม่',() => {
    const registration = document.getElementById('merchantRegister');
    if (!document.getElementById('merchantDashboard').classList.contains('hidden')) {
      const notice = document.getElementById('platformCreateNote');
      notice.textContent = 'บัญชีนี้มีร้านแล้ว ส่งใบสมัครให้เจ้าของร้านใหม่เปิดและเข้าสู่ระบบด้วยบัญชีของเขา';
      return;
    }
    registration.classList.remove('hidden');
    void showSignupPackages(client,document.getElementById('signupPackages'));
    registration.scrollIntoView({block:'start'});
  },referral);
  const note = node('p');
  note.id = 'platformCreateNote';
  signup.replaceChildren(create,note,referral);
  const panel = detail('ราคาแพ็กเกจ ตรวจสลิป และค่าแนะนำ');
  const body = node('div');
  const feedback = node('p');
  feedback.setAttribute('role','status');
  panel.append(body,feedback);
  document.getElementById('platformBilling').replaceChildren(panel);

  async function load() {
    const [billing,queue] = await Promise.all([rpc(client,'platform_package_prices'),rpc(client,'platform_package_queue')]);
    const mobile = node('input');
    mobile.type='tel';
    mobile.value=billing.mobile || '';
    const referralPercent = node('input');
    referralPercent.type='number';
    referralPercent.value=billing.referral_percent || 0;
    const rows = Object.entries(labels).map(([key,label]) => {
      const input=node('input');
      input.type='number';
      input.value=billing.prices[key] || '';
      input.min='1';
      input.step='0.01';
      return {key,input,field:field(label+' (บาท)',input)};
    });
    const fields=node('div');
    fields.className='fields';
    fields.append(field('เบอร์พร้อมเพย์ของแพลตฟอร์ม',mobile),field('ค่าแนะนำ (%)',referralPercent),...rows.map(row=>row.field));
    body.replaceChildren(fields,button('บันทึกราคาและบัญชีรับเงิน',async () => {
      await rpc(client,'save_platform_package_settings',{
        p_mobile:mobile.value.replace(/[\s-]/g,''),
        p_prices:Object.fromEntries(rows.filter(row=>row.input.value).map(row=>[row.key,Number(row.input.value)])),
        p_referral:Number(referralPercent.value)
      });
      feedback.textContent='บันทึกแล้ว';
    },feedback),node('h3','สลิปแพ็กเกจรอตรวจ'));
    if (!queue.orders.length) body.append(node('p','ไม่มีสลิปรอตรวจ'));
    for (const order of queue.orders) {
      const entry = node('article');
      entry.className='booking';
      const image = node('img');
      image.alt='สลิปชำระแพ็กเกจ';
      image.className='booking-slip-image hidden';
      const reference=node('input');
      reference.maxLength=200;
      entry.append(node('p',order.name+' · '+labels[order.plan]+' · '+money(order.amount)+' · พร้อมเพย์ '+order.receiving_mobile),
        button('เปิดรูปสลิป',async()=>{
          image.src=await rpc(client,'platform_package_slip',{p_order_id:order.id});
          image.classList.remove('hidden');
        },feedback),image,
        button('ตรวจสลิปแพ็กเกจด้วย Thunder',async()=>{
          const {data,error}=await client.functions.invoke('thunder-verify-slip',{body:{package_order_id:order.id}});
          if (error) throw error;
          if (data.state==='package_match') {
            reference.value=data.reference;
            feedback.textContent='Thunder ตรวจยอดและผู้รับตรงแล้ว ตรวจรายการก่อนกดอนุมัติ';
          } else {
            feedback.textContent=({
              not_configured:'ยังไม่ได้ตั้งค่า Thunder',
              amount_review:'ยอดสลิปไม่ตรงกับยอดแพ็กเกจ',
              receiver_review:'ยอดตรง แต่ยังต้องตรวจผู้รับหรือเวลาโอน',
              qr_unreadable:'อ่าน QR ไม่ได้ กรุณาตรวจจากรูปสลิป'
            })[data.state] || 'Thunder ยังตรวจรายการนี้ไม่ได้';
          }
        },feedback),field('เลขอ้างอิงที่ตรวจสอบแล้ว',reference),
        button('อนุมัติและต่ออายุ',async()=>{
          if (!image.getAttribute('src') || reference.value.trim().length<4) {
            feedback.textContent='เปิดสลิป ตรวจยอดและผู้รับ แล้วกรอกเลขอ้างอิงก่อนอนุมัติ';
            return;
          }
          if (!confirm('ยืนยันว่าตรวจยอด ผู้รับ และเลขอ้างอิงของสลิปนี้แล้วหรือไม่?')) return;
          await rpc(client,'review_package_order',{p_order_id:order.id,p_approve:true,p_reference:reference.value});
          await load();
          feedback.textContent='อนุมัติและต่ออายุแล้ว';
        },feedback),
        button('ปฏิเสธสลิป',async()=>{
          if (!confirm('ปฏิเสธสลิปแพ็กเกจนี้หรือไม่?')) return;
          await rpc(client,'review_package_order',{p_order_id:order.id,p_approve:false,p_reference:null});
          await load();
        },feedback));
      body.append(entry);
    }
    body.append(node('h3','ค่าแนะนำรอจ่าย'));
    for (const credit of queue.credits) {
      const row=node('p',credit.name+' · '+money(credit.amount)+' ');
      row.append(button('บันทึกว่าจ่ายแล้ว',async()=>{
        if (!confirm('บันทึกว่าคุณจ่ายค่าแนะนำรายการนี้แล้วหรือไม่?')) return;
        await rpc(client,'complete_referral_payout',{p_order_id:credit.order_id});
        await load();
      },feedback));
      body.append(row);
    }
  }
  panel.addEventListener('toggle',() => {
    if (panel.open) load().catch(() => { feedback.textContent = 'เปิดระบบแพ็กเกจด้วย SQL ไฟล์ 19'; });
  });
}
