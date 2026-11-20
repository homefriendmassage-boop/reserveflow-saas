const roleNames = {
  owner: 'เจ้าของร้าน', admin: 'แอดมินร้าน',
  cashier: 'แคชเชียร์', staff: 'พนักงาน', pending: 'รออนุมัติ', remove: 'ถอนสิทธิ์', reject: 'ปฏิเสธ'
};

export function renderMerchantTeam(container, rows, search, apply) {
  const term = search.trim().toLowerCase();
  const visible = rows.filter(member => [member.requested_name, member.line_name, member.email, member.user_id]
    .some(value => value?.toLowerCase().includes(term)));
  if (!visible.length) {
    container.textContent = term ? 'ไม่พบชื่อหรือ UID ที่ค้นหา' : 'ยังไม่มีคำขอหรือรายชื่อทีมงาน';
    return;
  }
  container.replaceChildren(...visible.map(member => {
    const card = document.createElement('article');
    card.className = 'booking';
    const name = document.createElement('h4');
    name.textContent = member.line_name || member.requested_name || member.email || 'บัญชีไม่มีชื่อแสดง';
    const role = document.createElement('p');
    role.textContent = roleNames[member.role] || member.role;
    const uid = document.createElement('code');
    uid.textContent = member.user_id;
    card.append(name, role, uid);
    if (member.requested_name) {
      const requestedName = document.createElement('p');
      requestedName.textContent = 'ชื่อที่แจ้งร้าน · ' + member.requested_name;
      card.append(requestedName);
    }
    if (member.role === 'owner') return card;

    const options = member.role === 'pending' ? ['staff', 'cashier', 'admin', 'reject'] : ['staff', 'cashier', 'admin', 'remove'];
    const form = document.createElement('form');
    form.className = 'inline-actions';
    const select = document.createElement('select');
    select.setAttribute('aria-label', 'สิทธิ์ของ ' + name.textContent);
    select.replaceChildren(...options.map(value => new Option(roleNames[value], value)));
    if (member.role !== 'pending') select.value = member.role;
    const button = document.createElement('button');
    button.className = 'btn soft small';
    button.textContent = member.role === 'pending' ? 'ดำเนินการคำขอ' : 'บันทึกสิทธิ์';
    form.append(select, button);
    form.addEventListener('submit', async event => {
      event.preventDefault();
      if (['remove', 'reject'].includes(select.value) && !window.confirm(roleNames[select.value] + 'สำหรับบัญชีนี้ใช่ไหม?')) return;
      button.disabled = select.disabled = true;
      try {
        await apply(member, select.value);
      } finally {
        button.disabled = select.disabled = false;
      }
    });
    card.append(form);
    return card;
  }));
}
