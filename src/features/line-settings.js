function element(tag, text) {
  const node = document.createElement(tag);
  if (text) node.textContent = text;
  return node;
}

function action(text) {
  const node = element('button', text);
  node.type = 'button';
  node.className = 'btn soft small';
  return node;
}

function errorMessage() {
  return 'ยังตั้งค่า LINE ไม่ได้ กรุณาตรวจการเชื่อมต่อแล้วลองใหม่';
}

function shopChannelSettings(client, shopId, refresh) {
  const section = element('div');
  const status = element('p');
  status.setAttribute('role','status');
  const form = element('form');
  form.className = 'fields';
  const secret = element('input');
  const token = element('input');
  const webhook = element('input');
  webhook.readOnly = true;
  webhook.value = 'https://zotgxsimkrofqxkhjjak.supabase.co/functions/v1/line-webhook?shop=' + encodeURIComponent(shopId);
  for (const input of [secret,token]) {
    input.type = 'password';
    input.autocomplete = 'off';
    input.required = true;
  }
  function label(text, input) {
    const result = element('label',text);
    result.className = 'field';
    result.append(input);
    return result;
  }
  const save = action('บันทึก LINE OA ของร้าน');
  save.type = 'submit';
  form.append(label('Channel secret',secret),label('Channel access token',token),save);
  const copy = action('คัดลอก Webhook URL');
  copy.addEventListener('click',async()=>{
    try { await navigator.clipboard.writeText(webhook.value); status.textContent = 'คัดลอก Webhook URL แล้ว'; }
    catch { webhook.focus(); webhook.select(); status.textContent = 'เลือก URL แล้ว กดคัดลอกจากเบราว์เซอร์'; }
  });
  section.append(element('h3','LINE OA ของร้านนี้'),
    element('p','ใช้ Channel secret และ Channel access token จาก Messaging API ของ OA ร้านเดียวกัน'),
    form,label('Webhook URL สำหรับใส่ใน LINE Developers',webhook),copy,status,
    element('p','ถ้า OA มี Webhook ใช้งานอยู่ ให้ใช้ช่องเชื่อมกลุ่มด้วย Group ID ด้านล่าง ถ้าจะเชื่อมด้วย RF ให้วาง Webhook URL ของร้านใน LINE Developers แล้วกด Verify'));
  const direct = element('details');
  const groupForm = element('form');
  groupForm.className = 'fields';
  const group = element('input');
  group.required = true;
  group.spellcheck = false;
  group.maxLength = 33;
  group.placeholder = 'C…';
  const connect = action('ตรวจและเชื่อมกลุ่ม');
  connect.type = 'submit';
  connect.disabled = true;
  const groupStatus = element('p');
  groupStatus.setAttribute('role','status');
  groupStatus.textContent = 'บันทึก Channel secret และ Channel access token ของ OA ร้านด้านบนก่อน';
  groupForm.append(label('LINE Group ID (source.groupId)',group),connect);
  direct.append(element('summary','ใช้ Webhook เดิม · เชื่อมกลุ่มด้วย Group ID'),
    element('p','เชิญ OA ร้านเข้ากลุ่ม แล้วใช้ source.groupId จากระบบเดิม'),groupForm,groupStatus);
  section.append(direct);
  groupForm.addEventListener('submit',async event=>{
    event.preventDefault();
    const id = group.value.trim();
    if (!/^C[a-f0-9]{32}$/.test(id)) {
      groupStatus.textContent = 'ใช้เฉพาะค่า source.groupId ที่ขึ้นต้นด้วย C จากบอทเดิม';
      return;
    }
    connect.disabled = true;
    groupStatus.textContent = 'กำลังตรวจกลุ่มจาก LINE…';
    try {
      const {data,error}=await client.functions.invoke('line-webhook?link-group=1',{
        body:{shop_id:shopId,group_id:id}
      });
      if (error) throw error;
      if (data.result === 'linked') {
        groupForm.reset();
        groupStatus.textContent = 'เชื่อมกลุ่มแล้ว';
        await refresh();
      } else {
        groupStatus.textContent = ({
          invalid_group:'ใช้ Group ID ที่ขึ้นต้นด้วย C ตามด้วย 32 ตัวอักษร',
          group_not_found:'ไม่พบกลุ่ม ให้ตรวจ Group ID และเชิญ OA ร้านเข้ากลุ่ม',
          group_access_denied:'LINE ไม่อนุญาต ให้ตรวจ Token และเช็กว่า OA ยังอยู่ในกลุ่ม',
          group_not_configured:'บันทึก OA ร้านและติดตั้ง SQL ไฟล์ 22 ก่อน'
        })[data.result] || 'ยังเชื่อมกลุ่มไม่ได้';
      }
    } catch {groupStatus.textContent = 'อัปเดต line-webhook ใน Supabase แล้วลองอีกครั้ง';}
    finally {connect.disabled = false;}
  });
  async function load() {
    const { data,error } = await client.rpc('shop_line_channel_status',{p_shop_id:shopId});
    const configured = !error && Boolean(data?.bot_name);
    status.textContent = error ? 'เปิด SQL ไฟล์ 21 เพื่อใช้ LINE OA รายร้าน'
      : configured ? 'OA ที่บันทึกไว้ · '+data.bot_name : 'ยังไม่ได้บันทึก LINE OA ของร้าน';
    connect.disabled = !configured;
    if (configured && groupStatus.textContent.startsWith('บันทึก Channel')) {
      groupStatus.textContent = 'พร้อมเชื่อมกลุ่มจาก Webhook เดิม';
    }
    return configured;
  }
  form.addEventListener('submit',async event=>{
    event.preventDefault();
    const channelSecret = secret.value.trim();
    const accessToken = token.value.trim();
    if (!/^[a-f0-9]{32}$/i.test(channelSecret)) {
      status.textContent = 'คัดลอก Channel secret จาก Basic settings ของ Messaging API ให้ครบ 32 ตัว';
      secret.focus();
      return;
    }
    if (accessToken.length < 20) {
      status.textContent = 'คัดลอก Channel access token จากแท็บ Messaging API ของ OA เดียวกัน';
      token.focus();
      return;
    }
    save.disabled = true;
    status.textContent = 'กำลังตรวจ Token กับ LINE…';
    try {
      const {data,error}=await client.functions.invoke('line-webhook?configure=1',{
        body:{shop_id:shopId,secret:channelSecret,token:accessToken}
      });
      if (error) throw error;
      if (data.result !== 'saved') {
        status.textContent = ({
          invalid_token:'LINE แจ้งว่า Channel access token ใช้ไม่ได้',
          invalid_credentials:'ตรวจ Channel secret และ Channel access token',
          bot_already_linked:'LINE OA นี้ถูกตั้งให้ร้านอื่นแล้ว',
          unauthorized:'เฉพาะเจ้าของร้านที่ตั้งค่า LINE OA ได้'
        })[data.result] || 'บันทึกไม่สำเร็จ กรุณาตรวจการเชื่อมต่อ';
        return;
      }
      form.reset();
      await refresh();
    } catch {status.textContent = 'เผยแพร่ line-webhook เวอร์ชันล่าสุดใน Supabase ก่อนตั้งค่า';}
    finally {save.disabled = false;}
  });
  return {section,load};
}

export function renderLineSettings(client, container, shopId) {
  const panel = element('details');
  panel.className = 'merchant-settings-panel';
  const pair = action('สร้างรหัสเชื่อม LINE');
  const shopChannel = shopId ? shopChannelSettings(client,shopId,load) : null;
  if (shopChannel) pair.disabled = true;
  const reload = action('รีเฟรชปลายทาง');
  const help = element('ol');
  help.append(
    element('li', 'กดสร้างรหัส แล้วกดคัดลอกข้อความให้ครบ รวม RF ด้านหน้า'),
    element('li', shopId
      ? 'ส่งข้อความในแชตกับ LINE Official Account (OA) ของร้าน หรือในกลุ่ม LINE ที่เชิญ OA ร้านเข้ากลุ่มแล้ว'
      : 'ส่งข้อความในแชตส่วนตัวกับ LINE Official Account (OA) ของระบบ'),
    element('li', 'กลับมากดตรวจการเชื่อม แล้วดูว่ามีปลายทางขึ้นในรายการ')
  );
  reload.textContent = 'ตรวจการเชื่อม';
  const copy = action('คัดลอกข้อความ RF');
  const code = element('input');
  const codeRow = element('div');
  codeRow.className = 'line-pairing-code hidden';
  code.readOnly = true;
  code.spellcheck = false;
  code.setAttribute('aria-label', 'ข้อความสำหรับส่งให้ LINE Official Account');
  const status = element('p');
  status.setAttribute('role', 'status');
  const destinations = element('ul');
  const docs = element('a', 'คู่มือเปิดระบบแจ้งเตือน LINE สำหรับผู้ดูแล');
  docs.href = 'https://github.com/homefriendmassage-boop/reserveflow-saas/blob/main/README.md#superadmin-and-line-notifications';
  codeRow.append(code, copy);
  panel.append(element('summary', 'แจ้งเตือนผ่าน LINE'));
  if (shopChannel) panel.append(shopChannel.section);
  panel.append(help, pair, reload, codeRow, status, destinations, docs);
  container.replaceChildren(panel);

  async function load() {
    reload.disabled = true;
    try {
      if (shopChannel) pair.disabled = !await shopChannel.load();
      const { data, error } = await client.rpc('list_line_targets', { p_shop_id: shopId });
      if (error) throw error;
      destinations.replaceChildren(...data.map(destination => {
        const label = destination.target_type === 'group' ? 'กลุ่ม LINE' : 'LINE ส่วนตัว';
        const item = element('li', label + ' · ' + new Date(destination.created_at).toLocaleString('th-TH'));
        const remove = action('ยกเลิกการเชื่อม');
        remove.addEventListener('click', async () => {
          if (!confirm('ยกเลิกการแจ้งเตือนไปยังปลายทางนี้ใช่ไหม?')) return;
          const { error } = await client.rpc('remove_line_target', {
            p_shop_id: shopId, p_target_id: destination.id
          });
          if (error) status.textContent = errorMessage();
          else await load();
        });
        item.append(' ', remove);
        return item;
      }));
      if (!data.length) destinations.append(element('li', 'ยังไม่มีปลายทางที่เชื่อม หากส่งข้อความ RF แล้ว ให้ผู้ดูแลตรวจว่าเปิด Webhook ของ LINE OA แล้ว'));
    } catch {
      status.textContent = errorMessage();
    } finally {
      reload.disabled = false;
    }
  }

  panel.addEventListener('toggle', () => { if (panel.open) void load(); });
  reload.addEventListener('click', load);
  copy.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(code.value);
      status.textContent = 'คัดลอกแล้ว ส่งข้อความนี้ไปที่แชตภายใน 15 นาทีหลังสร้างรหัส';
    } catch {
      code.focus();
      code.select();
      status.textContent = 'เลือกข้อความแล้ว กดคัดลอกจากเบราว์เซอร์';
    }
  });
  pair.addEventListener('click', async () => {
    pair.disabled = true;
    try {
      const { data, error } = await client.rpc('create_line_pairing', { p_shop_id: shopId });
      if (error) throw error;
      code.value = 'RF ' + data;
      codeRow.classList.remove('hidden');
      code.select();
      status.textContent = shopId
        ? 'ส่งข้อความนี้ในแชตกับ LINE OA ของร้านหรือกลุ่มที่เชิญ OA ร้านแล้ว ภายใน 15 นาที'
        : 'ส่งข้อความนี้ในแชตส่วนตัวกับ LINE Official Account ภายใน 15 นาที';
    } catch {
      status.textContent = errorMessage();
    } finally {
      pair.disabled = false;
    }
  });
}

export async function loadPlatformAdmin(client) {
  const { data, error } = await client.rpc('platform_shop_overview');
  if (error || !Array.isArray(data)) return;
  document.getElementById('platformAdmin').classList.remove('hidden');
  const list = document.getElementById('platformShopList');
  list.replaceChildren(...data.map(shop => {
    const card = element('article');
    card.className = 'booking';
    const customer = element('a', 'หน้าจองของร้าน');
    customer.href = './book.html?' + new URLSearchParams({ shop: shop.slug });
    card.append(element('h3', shop.name), element('p', [
      shop.slug, shop.public_booking_enabled ? 'เปิดรับจอง' : 'ปิดรับจอง',
      'ทีมงาน ' + shop.staff_count + ' บัญชี'
    ].join(' · ')), customer);
    return card;
  }));
  renderLineSettings(client, document.getElementById('platformLineSettings'), null);
}
