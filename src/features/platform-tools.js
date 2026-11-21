import { promptPayPayload } from './promptpay.js?v=team-slip-credits-1';

const labels = { monthly:'รายเดือน', quarterly:'3 เดือน', half_year:'6 เดือน', yearly:'รายปี' };
const suggestedPrices = { monthly:299, quarterly:849, half_year:1590, yearly:2990 };
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
    catch (error) {
      const messages = {
        INVALID_REFERRAL_LIFF:'กรอก LIFF ID ที่ได้จาก LINE Developers',
        INVALID_SLIP_PACK_PRICE:'จำนวนสลิปหรือราคาอยู่นอกช่วงที่กำหนด',
        SLIP_PACK_NOT_FOUND:'ไม่พบแพ็กเกจนี้ กรุณาเปิดหน้านี้ใหม่',
        INVALID_PLATFORM_PROMPTPAY:'ใช้เบอร์มือถือพร้อมเพย์ 10 หลักหรือเลขบัตรประชาชน 13 หลัก',
        INVALID_PLATFORM_REFERRAL:'ใส่ค่าแนะนำระหว่าง 0 ถึง 100%',
        INVALID_PLATFORM_PRICES:'ตรวจราคาทุกช่อง ราคาที่ระบุเริ่มต้นที่ 1 บาท',
        PGRST202:'Supabase ยังไม่พบฟังก์ชันนี้ ตรวจว่า SQL ไฟล์ 33 และ 34 รันสำเร็จในโปรเจกต์ reserveflow',
        '42501':'บัญชีนี้ไม่มีสิทธิ์ทำรายการ',
        '23505':'เลขอ้างอิงนี้เคยถูกใช้แล้ว',
        '23514':'ฐานข้อมูลปฏิเสธข้อมูลตามเงื่อนไขเดิม ถ้าใส่เลขบัตร 13 หลัก ให้ตรวจ SQL ไฟล์ 34',
        '22023':'ข้อมูลไม่ผ่านการตรวจสอบ ถ้าใช้พร้อมเพย์เลขบัตร 13 หลัก ให้ตรวจ SQL ไฟล์ 34'
      };
      status.textContent = messages[error.message] || messages[error.code] || 'ทำรายการไม่สำเร็จ กรุณาลองอีกครั้ง';
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
  const visit = node('a','เปิดใบสมัครร้านค้า');
  visit.href = link.href;
  visit.className = 'btn soft small';
  const share = node('a','เลือกรายชื่อเพื่อนใน LINE');
  share.className = 'btn primary small';
  const linkShare = 'https://line.me/R/share?text=' + encodeURIComponent('สมัครร้านค้าบน ReserveFlow\n' + link.href);
  share.href = linkShare;
  const help = node('p','แชร์ลิงก์ใบสมัครผ่านรายชื่อเพื่อนใน LINE');
  help.className = 'sub';
  panel.append(field('ลิงก์สมัครร้าน',url),
    button('คัดลอกลิงก์',async () => {
      try { await navigator.clipboard.writeText(link.href); feedback.textContent = 'คัดลอกแล้ว'; }
      catch { url.select(); feedback.textContent = 'เลือกข้อความแล้ว กดคัดลอกจากเบราว์เซอร์'; }
    },feedback),
    button('แสดง QR ใบสมัคร',() => qr(image,link.href),feedback),
    visit, share, help, image, feedback);
  const liffId = node('input');
  if (!shopId) {
    liffId.placeholder = '1234567890-abcdefgh';
    panel.append(field('LIFF ID สำหรับแชร์ Flex',liffId),button('บันทึก LIFF ID',async () => {
      await rpc(client,'save_platform_referral_share_liff',{p_liff_id:liffId.value.trim()});
      configureShare(liffId.value.trim());
      feedback.textContent = 'บันทึกการตั้งค่าแชร์ LINE แล้ว';
    },feedback));
  }

  function configureShare(id) {
    const configured = /^[0-9]{6,16}-[A-Za-z0-9]{4,24}$/.test(id || '');
    const liff = configured ? new URL('https://liff.line.me/' + id) : null;
    if (liff && shopId) liff.searchParams.set('ref',shopId);
    share.textContent = configured ? 'เลือกเพื่อนเพื่อส่ง Flex' : 'เลือกรายชื่อเพื่อนใน LINE';
    share.href = liff?.href || linkShare;
    help.textContent = configured ? 'LINE จะให้เลือกรายชื่อผู้รับเมื่อกดส่ง Flex'
      : 'ตอนนี้แชร์เป็นลิงก์ได้ หากต้องการแชร์เป็น Flex ให้ตั้ง LIFF ID ใน Superadmin';
  }
  panel.addEventListener('toggle',async () => {
    if (!panel.open) return;
    try {
      const configured = await rpc(client,'platform_referral_share_liff');
      liffId.value = configured || '';
      configureShare(configured);
    } catch {
      configureShare(null);
    }
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
      'ทดลองฟรี 7 วัน · ตรวจสลิป 10 ครั้ง',
      ...Object.entries(labels).map(([key,label]) => label + (data.prices[key] ? ' ' + money(data.prices[key]) : ' · รอตั้งราคา'))
    ].join(' / ');
  } catch { container.textContent = 'ทดลองฟรี 7 วัน'; }
}

function slipCreditPanel(client, shopId) {
  const panel = detail(shopId ? 'เติมเครดิตตรวจสลิป' : 'แพ็กเกจเครดิตตรวจสลิป');
  const body = node('div');
  const feedback = node('p');
  feedback.setAttribute('role','status');
  panel.append(body,feedback);

  async function load() {
    const data = await rpc(client,'shop_slip_credit_overview',{p_shop_id:shopId});
    const packs = data.offers || [{code:'starter',...data.offer}];
    const packLabel = pack => pack.credits + ' สลิป · ' + money(pack.amount)
      + ' (' + money(pack.amount / pack.credits) + ' ต่อสลิป)';
    body.replaceChildren(node('p','เครดิตตรวจสลิปไม่มีค่าแนะนำ'));
    if (!data.offers && !shopId) body.append(node('p',
      'ฐานข้อมูลยังแสดงแพ็กเกจเดิม 1 แบบ ตรวจว่า SQL ไฟล์ 33 รันสำเร็จในโปรเจกต์ reserveflow'));
    if (shopId) {
      if (data.allowance) body.append(node('p','โควต้ารวมในแพ็กเกจคงเหลือ ' + data.allowance.remaining
        + ' / ' + data.allowance.included_limit + ' สลิป'));
      body.append(node('p','เครดิตเติมเงินคงเหลือ ' + data.balance + ' สลิป'));
      const current = data.orders.find(order => order.state === 'pending');
      for (const order of data.orders.filter(order => order.state !== 'pending')) {
        body.append(node('p',order.credits + ' สลิป · ' + money(order.amount) + ' · ' + stateLabels[order.state]));
      }
      if (!current) {
        if (!data.payments_enabled) {
          body.append(node('p','รอ Superadmin ตั้งค่าบัญชีรับเงินแพลตฟอร์ม'));
          return;
        }
        const pack = node('select');
        pack.replaceChildren(...packs.map(item => new Option(packLabel(item),item.code)));
        body.append(field('เลือกแพ็กเกจตรวจสลิป',pack),button('สร้างรายการเติมเครดิต',async () => {
          if (data.offers) await rpc(client,'open_slip_credit_pack',{p_shop_id:shopId,p_code:pack.value});
          else await rpc(client,'open_slip_credit_order',{p_shop_id:shopId});
          await load();
        },feedback));
        return;
      }
      body.append(node('h3','รายการเติมเครดิต · ' + current.credits + ' สลิป · ' + money(current.amount)));
      if (current.has_slip) { body.append(node('p','ส่งสลิปแล้ว · รอ Superadmin ตรวจ')); return; }

      const image = node('div');
      qr(image,promptPayPayload(current.receiving_mobile,Number(current.amount)));
      const file = node('input');
      file.type = 'file';
      file.accept = 'image/jpeg,image/png,image/webp';
      body.append(image,field('แนบสลิปเติมเครดิต',file),button('ส่งสลิปเติมเครดิต',async () => {
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
        await rpc(client,'submit_slip_credit_payment',{p_order_id:current.id,p_image:contents});
        await load();
        feedback.textContent = 'ส่งสลิปแล้ว';
      },feedback),button('ยกเลิกรายการที่ยังไม่ชำระ',async () => {
        if (!confirm('ยกเลิกการเติมเครดิตนี้หรือไม่? หากโอนแล้วให้ส่งสลิปแทน')) return;
        await rpc(client,'submit_slip_credit_payment',{p_order_id:current.id,p_image:null});
        await load();
      },feedback));
      return;
    }

    for (const pack of packs) {
      const quantity = node('input');
      Object.assign(quantity,{type:'number',min:'1',max:'100000',step:'1',value:pack.credits,required:true});
      const price = node('input');
      Object.assign(price,{type:'number',min:'0.01',step:'0.01',value:pack.amount,required:true});
      const fields = node('div');
      fields.className = 'fields';
      fields.append(field('จำนวนสลิป',quantity),field('ราคาแพ็กเกจ (บาท)',price));
      const packStatus = node('p');
      packStatus.setAttribute('role','status');
      body.append(node('h3',packLabel(pack)),fields,button('บันทึกราคาเครดิตตรวจสลิป',async () => {
        if (!quantity.reportValidity() || !price.reportValidity()) return;
        const args = {p_credits:Number(quantity.value),p_amount:Number(price.value)};
        if (data.offers) await rpc(client,'save_slip_credit_pack',{...args,p_code:pack.code});
        else await rpc(client,'save_slip_credit_offer',args);
        await load();
        feedback.textContent = 'บันทึกราคาแพ็กเกจ ' + args.p_credits + ' สลิปแล้ว';
      },packStatus),packStatus);
    }
    body.append(node('h3','สลิปเติมเครดิตรอตรวจ'));
    if (!data.orders.length) body.append(node('p','ไม่มีสลิปเติมเครดิตรอตรวจ'));
    for (const order of data.orders) {
      const entry = node('article');
      entry.className = 'booking';
      const image = node('img');
      image.alt = 'สลิปเติมเครดิต';
      image.className = 'booking-slip-image hidden';
      const reference = node('input');
      reference.maxLength = 200;
      entry.append(node('p',order.name + ' · ' + order.credits + ' สลิป · ' + money(order.amount) + ' · พร้อมเพย์ ' + order.receiving_mobile),
        button('เปิดรูปสลิป',async () => {
          const slip = await rpc(client,'platform_slip_credit_image',{p_order_id:order.id});
          if (!slip) throw new Error('Missing slip');
          image.src = slip;
          image.classList.remove('hidden');
        },feedback),image,field('เลขอ้างอิงที่ตรวจสอบแล้ว',reference),
        button('อนุมัติและเติมเครดิต',async () => {
          if (!image.getAttribute('src') || reference.value.trim().length < 4) {
            feedback.textContent = 'เปิดสลิป ตรวจยอดและผู้รับ แล้วกรอกเลขอ้างอิงก่อนอนุมัติ';
            return;
          }
          if (!confirm('ยืนยันว่าตรวจยอด ผู้รับ และเลขอ้างอิงของสลิปเติมเครดิตแล้วหรือไม่?')) return;
          await rpc(client,'review_slip_credit_order',{p_order_id:order.id,p_approve:true,p_reference:reference.value});
          await load();
          feedback.textContent = 'เติมเครดิตแล้ว';
        },feedback),button('ปฏิเสธสลิป',async () => {
          if (!confirm('ปฏิเสธสลิปเติมเครดิตนี้หรือไม่?')) return;
          await rpc(client,'review_slip_credit_order',{p_order_id:order.id,p_approve:false,p_reference:null});
          await load();
        },feedback));
      body.append(entry);
    }
  }
  panel.addEventListener('toggle',() => {
    if (panel.open) load().catch(() => { feedback.textContent = 'โหลดแพ็กเกจเครดิตตรวจสลิปไม่ได้'; });
  });
  return panel;
}

export function renderShopBusinessTools(client, container, shopId) {
  const panel = detail('แพ็กเกจใช้งานแพลตฟอร์มและต่ออายุ');
  panel.id = 'shopPackagePanel';
  const body = node('div');
  const feedback = node('p');
  feedback.setAttribute('role','status');
  panel.append(body,feedback);
  container.append(referralPanel(client,shopId),panel,slipCreditPanel(client,shopId));
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
  const panel = detail('ราคาแพ็กเกจแพลตฟอร์มและค่าแนะนำ');
  const body = node('div');
  const feedback = node('p');
  feedback.setAttribute('role','status');
  panel.append(body,feedback);
  document.getElementById('platformBilling').replaceChildren(panel,slipCreditPanel(client,null));

  async function load() {
    const [billing,queue] = await Promise.all([rpc(client,'platform_package_prices'),rpc(client,'platform_package_queue')]);
    const mobile = node('input');
    mobile.type='tel';
    mobile.value=billing.mobile || '';
    const referralPercent = node('input');
    Object.assign(referralPercent,{type:'number',min:'0',max:'100',step:'0.01',required:true});
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
    fields.append(field('พร้อมเพย์แพลตฟอร์ม (เบอร์มือถือหรือเลขบัตรประชาชน)',mobile),field('ค่าแนะนำเฉพาะแพ็กเกจแพลตฟอร์ม (%)',referralPercent),...rows.map(row=>row.field));
    body.replaceChildren(node('p','แพ็กเกจที่ชำระแล้วรวมโควต้าตรวจสลิป 100 ครั้งต่อเดือนปฏิทิน'
      + ' · ทดลองใช้และร้านเดิมที่ยังไม่มีแพ็กเกจได้รับโควต้าเริ่มต้น 10 ครั้ง'),fields,button('ใส่ราคาแนะนำ',() => {
      for (const row of rows) row.input.value = suggestedPrices[row.key];
      feedback.textContent = 'ใส่ราคาแนะนำแล้ว ตรวจราคาแล้วกดบันทึกเพื่อใช้จริง';
    },feedback),button('บันทึกราคาและบัญชีรับเงิน',async () => {
      const proxy = mobile.value.replace(/[\s-]/g,'');
      if (proxy && !/^(0[689][0-9]{8}|[0-9]{13})$/.test(proxy)) {
        feedback.textContent = 'ใช้เบอร์มือถือพร้อมเพย์ 10 หลักหรือเลขบัตรประชาชน 13 หลัก';
        mobile.focus();
        return;
      }
      if (!referralPercent.reportValidity() || rows.some(row => !row.input.reportValidity())) return;
      await rpc(client,'save_platform_package_settings',{
        p_mobile:proxy,
        p_prices:Object.fromEntries(rows.filter(row=>row.input.value).map(row=>[row.key,Number(row.input.value)])),
        p_referral:Number(referralPercent.value)
      });
      feedback.textContent='บันทึกแล้ว';
    },feedback),node('h3','สลิปแพ็กเกจแพลตฟอร์มรอตรวจ'));
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
