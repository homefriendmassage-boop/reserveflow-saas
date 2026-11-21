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
    element('p','ถ้า OA มี Webhook ใช้งานอยู่ ให้ใช้ช่องเชื่อมกลุ่มหรือ LINE ส่วนตัวด้วย ID ด้านล่าง ถ้าจะเชื่อมด้วย RF ให้วาง Webhook URL ของร้านใน LINE Developers แล้วกด Verify'));
  const friendForm = element('form');
  const friendId = element('input');
  friendId.placeholder = '@ร้านค้า';
  friendId.maxLength = 50;
  friendId.autocapitalize = 'none';
  const friendSave = action('บันทึก LINE ID สำหรับเพิ่มเพื่อน');
  friendSave.type = 'submit';
  friendForm.append(label('LINE ID ของ OA ที่ขึ้นต้นด้วย @',friendId),friendSave);
  section.append(friendForm);
  void client.rpc('shop_line_friend_id',{p_shop_id:shopId}).then(({data}) => { if (!friendId.value) friendId.value=data || ''; });
  friendForm.onsubmit = async event => {
    event.preventDefault();
    const id = friendId.value.trim();
    if (id && !/^@[A-Za-z0-9._-]{1,49}$/.test(id)) {
      status.textContent = 'ใส่ LINE ID ของ OA ตามที่แสดงใน LINE Official Account Manager';
      return;
    }
    friendSave.disabled = true;
    try {
      const {error} = await client.rpc('save_shop_line_friend_id',{p_shop_id:shopId,p_basic_id:id});
      status.textContent = error ? 'บันทึกไม่ได้ ตรวจการเชื่อม LINE OA และ SQL 46' : 'บันทึก LINE ID แล้ว';
    } finally { friendSave.disabled = false; }
  };
  function directConnection(isGroup) {
    const direct = element('details');
    const targetForm = element('form');
    targetForm.className = 'fields';
    const target = element('input');
    target.required = true;
    target.spellcheck = false;
    target.maxLength = 33;
    const prefix = isGroup ? 'C' : 'U';
    target.placeholder = prefix + '…';
    const connect = action(isGroup ? 'ตรวจและเชื่อมกลุ่ม' : 'ตรวจและเชื่อม LINE ส่วนตัว');
    connect.type = 'submit';
    connect.disabled = true;
    const feedback = element('p');
    feedback.setAttribute('role','status');
    feedback.textContent = 'บันทึก Channel secret และ Channel access token ของ OA ร้านด้านบนก่อน';
    targetForm.append(label(isGroup ? 'LINE Group ID (source.groupId)' : 'LINE User ID (source.userId)',target),connect);
    direct.append(element('summary',isGroup ? 'ใช้ Webhook เดิม · เชื่อมกลุ่มด้วย Group ID' : 'ใช้ Webhook เดิม · เชื่อม LINE ส่วนตัว'),
      element('p',isGroup ? 'เชิญ OA ร้านเข้ากลุ่ม แล้วใช้ source.groupId จากระบบเดิม'
        : 'เพิ่มเพื่อน OA ร้าน ส่งข้อความในแชตส่วนตัว แล้วใช้ source.userId จาก Log บอทเดิม'),targetForm,feedback);
    section.append(direct);
    targetForm.addEventListener('submit',async event=>{
      event.preventDefault();
      const id = target.value.trim();
      if (!new RegExp('^'+prefix+'[a-f0-9]{32}$').test(id)) {
        feedback.textContent = 'ใส่รหัสที่ขึ้นต้นด้วย '+prefix+' ตามด้วย 32 ตัวอักษร';
        return;
      }
      connect.disabled = true;
      feedback.textContent = 'กำลังตรวจปลายทางจาก LINE…';
      try {
        const method = isGroup ? 'link-group' : 'link-user';
        const {data,error}=await client.functions.invoke('line-webhook?'+method+'=1',{
          body:{shop_id:shopId,[isGroup?'group_id':'user_id']:id}
        });
        if (error) throw error;
        if (data.result === 'linked') {
          targetForm.reset();
          feedback.textContent = isGroup ? 'เชื่อมกลุ่มแล้ว' : 'เชื่อม LINE ส่วนตัวแล้ว';
          await refresh();
        } else {
          feedback.textContent = ({
            invalid_target:'ตรวจรหัส LINE ที่กรอก',
            group_not_found:isGroup ? 'ไม่พบกลุ่ม ให้เชิญ OA ร้านเข้ากลุ่ม' : 'ไม่พบบัญชี ให้เพิ่มเพื่อน OA ร้านแล้วส่งข้อความในแชตส่วนตัว',
            group_access_denied:'LINE ไม่อนุญาต ให้ตรวจ Token ของ OA ร้าน',
            group_not_configured:'บันทึก OA ร้านและติดตั้ง SQL ไฟล์ 25 ก่อน'
          })[data.result] || 'ยังเชื่อมปลายทางไม่ได้';
        }
      } catch {feedback.textContent = 'อัปเดต line-webhook ใน Supabase แล้วลองอีกครั้ง';}
      finally {connect.disabled = false;}
    });
    return {connect,feedback};
  }
  const connections = [directConnection(true),directConnection(false)];
  async function load() {
    const { data,error } = await client.rpc('shop_line_channel_status',{p_shop_id:shopId});
    const configured = !error && Boolean(data?.bot_name);
    status.textContent = error ? 'เปิด SQL ไฟล์ 21 เพื่อใช้ LINE OA รายร้าน'
      : configured ? 'OA ที่บันทึกไว้ · '+data.bot_name : 'ยังไม่ได้บันทึก LINE OA ของร้าน';
    for (const {connect,feedback} of connections) {
      connect.disabled = !configured;
      if (configured && feedback.textContent.startsWith('บันทึก Channel')) feedback.textContent = 'พร้อมเชื่อมจาก Webhook เดิม';
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

export async function loadPlatformAdmin(client, refresh) {
  const { data, error } = await client.rpc('platform_shop_overview');
  const admin = document.getElementById('platformAdmin');
  admin.classList.toggle('hidden', !!error || !Array.isArray(data));
  if (admin.classList.contains('hidden')) return;
  const list = document.getElementById('platformShopList');
  const feedback = element('p');
  feedback.setAttribute('role','status');
  const cards = data.map(shop => {
    const card = element('article');
    card.className = 'booking';
    const customer = element('a', 'หน้าจองของร้าน');
    customer.href = './book.html?' + new URLSearchParams({ shop: shop.slug });
    const suspended = shop.platform_booking_suspended;
    async function change(control, rpcName, args, success) {
      control.disabled = true;
      try {
        const { error } = await client.rpc(rpcName,{p_shop_id:shop.shop_id,...args});
        if (error) throw error;
        await refresh();
        document.getElementById('platformShopManagementStatus').textContent = success;
      } catch (error) {
        const messages = {
          PGRST202:'รัน SQL ไฟล์ 43 ใน Supabase เพื่อเปิดเมนูจัดการร้าน',
          PLATFORM_SHOP_NOT_FOUND:'ไม่พบร้านนี้ กรุณาโหลดหน้าใหม่',
          PLATFORM_SHOP_CLOSE_FIRST:'ปิดรับจองจากเมนู Superadmin ก่อนลบร้าน',
          PLATFORM_SHOP_CONFIRM_SLUG:'พิมพ์ชื่อในลิงก์จองให้ตรงกับร้าน',
          '42501':'บัญชีนี้ไม่มีสิทธิ์จัดการร้าน'
        };
        feedback.textContent = messages[error.message] || messages[error.code] || 'จัดการร้านไม่สำเร็จ กรุณาลองอีกครั้ง';
      } finally { control.disabled = false; }
    }
    const bookingAction = enabled => {
      const label = enabled ? 'เปิดรับจองออนไลน์' : 'ปิดรับจองออนไลน์';
      const control = action(label);
      control.onclick = () => change(control,'set_platform_shop_booking',{p_enabled:enabled},
        shop.name + ' ' + label + 'แล้ว');
      return control;
    };
    card.append(element('h3', shop.name), element('p', [
      shop.slug, suspended ? 'Superadmin ปิดรับจอง' : shop.public_booking_enabled ? 'เปิดรับจอง' : 'ปิดรับจอง',
      'ทีมงาน ' + shop.staff_count + ' บัญชี'
    ].join(' · ')), customer);
    if (!shop.public_booking_enabled) card.append(bookingAction(true));
    if (!suspended) card.append(bookingAction(false));
    if (suspended) {
      const deletion = element('details');
      const form = element('form');
      const label = element('label','พิมพ์ ' + shop.slug + ' เพื่อยืนยัน');
      label.className = 'field';
      const slug = element('input');
      slug.required = true;
      slug.autocomplete = 'off';
      slug.setAttribute('autocapitalize','none');
      label.append(slug);
      const remove = action('ยืนยันลบร้านถาวร');
      remove.type = 'submit';
      remove.className = 'btn danger small';
      form.append(label,remove);
      form.onsubmit = event => {
        event.preventDefault();
        if (slug.value !== shop.slug) {
          feedback.textContent = 'พิมพ์ชื่อในลิงก์จองให้ตรงกับร้าน';
          slug.focus();
          return;
        }
        void change(remove,'delete_platform_shop',{p_confirm_slug:slug.value},'ลบร้าน ' + shop.name + ' แล้ว');
      };
      deletion.append(element('summary','ลบร้านถาวร'),
        element('p','ระบบจะลบข้อมูลร้าน การจอง ทีมงาน แพ็กเกจ เครดิตตรวจสลิป และการเชื่อม LINE OA การลบนี้ย้อนกลับไม่ได้'),
        form);
      card.append(deletion);
    }
    return card;
  });
  feedback.id = 'platformShopManagementStatus';
  list.replaceChildren(element('h3','จัดการร้านค้า'),feedback,...cards);
  renderLineSettings(client, document.getElementById('platformLineSettings'), null);
}
