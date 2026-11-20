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

export function renderLineSettings(client, container, shopId) {
  const panel = element('details');
  panel.className = 'merchant-settings-panel';
  const pair = action('สร้างรหัสเชื่อม LINE');
  const reload = action('รีเฟรชปลายทาง');
  const help = element('ol');
  help.append(
    element('li', 'กดสร้างรหัส แล้วกดคัดลอกข้อความให้ครบ รวม RF ด้านหน้า'),
    element('li', shopId
      ? 'ส่งข้อความในแชตกับ LINE Official Account (OA) ของระบบ หรือในกลุ่ม LINE ที่เชิญ OA เข้ากลุ่มแล้ว'
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
  panel.append(element('summary', 'แจ้งเตือนผ่าน LINE'), help, pair, reload, codeRow, status, destinations, docs);
  container.replaceChildren(panel);

  async function load() {
    reload.disabled = true;
    try {
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
        ? 'ส่งข้อความนี้ให้ LINE Official Account ในแชตส่วนตัวหรือกลุ่มที่เชิญ OA แล้ว ภายใน 15 นาที'
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
