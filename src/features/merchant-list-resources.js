const staffPhoto = /^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/;

export function renderListResources(panel, categories, resources, save, archive) {
  const create = (tag, text = '') => Object.assign(document.createElement(tag), { textContent: text });
  const form = create('form');
  form.className = 'fields merchant-resource-fields';
  function field(label, tag = 'input') {
    const wrapper = create('label');
    wrapper.className = 'field';
    const input = create(tag);
    wrapper.append(create('span', label), input);
    form.append(wrapper);
    return input;
  }
  const category = field('หมวดการจอง', 'select');
  category.dataset.listCategory = '';
  category.replaceChildren(...categories.map(row => new Option(row.name, row.code)));
  const resource = field('รายการที่ต้องการแก้ไข', 'select');
  resource.dataset.listResource = '';
  const name = field('ชื่อพนักงานหรือโซนบัตร');
  name.required = true;
  name.maxLength = 100;
  const position = field('ตำแหน่งพนักงาน');
  position.maxLength = 100;
  const description = field('รายละเอียด', 'textarea');
  description.maxLength = 500;
  const capacity = field('จำนวนบัตรสูงสุดต่อการจอง');
  Object.assign(capacity, { type: 'number', min: 1, max: 10, required: true });
  const file = field('รูปพนักงาน ขนาดไม่เกิน 350 KB');
  Object.assign(file, { type: 'file', accept: 'image/png,image/jpeg,image/webp' });
  const preview = create('img');
  preview.className = 'live-staff-photo';
  preview.alt = 'รูปพนักงาน';
  const remove = create('button', 'นำรูปออก');
  remove.className = 'btn soft small';
  remove.type = 'button';
  const submit = create('button', 'บันทึกรายการ');
  submit.className = 'btn primary';
  const status = create('p');
  status.setAttribute('role', 'status');
  const removeEntry = create('button', 'ลบรายการออกจากหน้าจอง');
  removeEntry.className = 'btn danger';
  removeEntry.type = 'button';
  const info = create('p', 'กดแก้ไขที่การ์ดพนักงาน หรือเลือกรายการจากช่องด้านล่าง');
  info.className = 'sub';
  form.append(preview, remove, submit, removeEntry);
  const savedStaff = create('ul');
  savedStaff.className = 'merchant-saved-staff';
  savedStaff.setAttribute('aria-label', 'พนักงานที่บันทึกแล้ว');
  panel.append(info, savedStaff, form, status);
  let photo = null;
  let fileRead = 0;
  function showPhoto() {
    preview.classList.toggle('hidden', !photo);
    remove.classList.toggle('hidden', !photo);
    if (photo) preview.src = photo;
    else preview.removeAttribute('src');
  }
  function loadResource() {
    fileRead++;
    submit.disabled = false;
    const staff = categories.find(row => row.code === category.value).template === 'staff';
    const row = resources.find(row => row.code === resource.value && row.category_code === category.value);
    removeEntry.classList.toggle('hidden', !row);
    name.value = row?.name || '';
    position.value = row?.display?.position || '';
    description.value = row?.description || '';
    capacity.value = Math.min(row?.capacity || 10,10);
    capacity.disabled = staff;
    capacity.parentElement.classList.toggle('hidden', staff);
    position.parentElement.classList.toggle('hidden', !staff);
    file.parentElement.classList.toggle('hidden', !staff);
    file.value = '';
    photo = staff ? row?.display?.photo || null : null;
    showPhoto();
  }
  function loadCategory() {
    const rows = resources.filter(row => row.category_code === category.value && row.display?.archived !== true);
    resource.replaceChildren(new Option('+ เพิ่มรายการใหม่', ''), ...rows.map(row => new Option(row.name, row.code)));
    const staff = categories.find(row => row.code === category.value).template === 'staff';
    savedStaff.classList.toggle('hidden', !staff || !rows.length);
    savedStaff.replaceChildren(...(staff ? rows.map(row => {
      const card = create('li');
      if (staffPhoto.test(row.display?.photo || '')) {
        const portrait = create('img');
        Object.assign(portrait, { className: 'live-staff-photo', loading: 'lazy', alt: '', src: row.display.photo });
        card.append(portrait);
      }
      const details = create('div');
      details.append(create('strong', row.name));
      if (row.display?.position) details.append(create('p', row.display.position));
      const edit = create('button', 'แก้ไข');
      edit.className = 'btn soft small';
      edit.type = 'button';
      edit.setAttribute('aria-label', 'แก้ไข ' + row.name);
      edit.addEventListener('click', () => {
        resource.value = row.code;
        loadResource();
        name.focus();
      });
      card.append(details, edit);
      return card;
    }) : []));
    loadResource();
  }
  removeEntry.addEventListener('click', async () => {
    if (!resource.value || !confirm('ลบรายการนี้ออกจากหน้าจอง? ประวัติการจองเดิมจะยังอยู่')) return;
    removeEntry.disabled = true;
    try {
      await archive({ p_category_code: category.value, p_code: resource.value });
    } finally {
      removeEntry.disabled = false;
    }
  });
  category.addEventListener('change', loadCategory);
  resource.addEventListener('change', loadResource);
  remove.addEventListener('click', () => { fileRead++; photo = null; file.value = ''; submit.disabled = false; showPhoto(); });
  file.addEventListener('change', () => {
    const image = file.files[0];
    if (!image) return;
    if (image.size > 350 * 1024 || !['image/png','image/jpeg','image/webp'].includes(image.type)) {
      status.textContent = 'ใช้ไฟล์ JPG, PNG หรือ WebP ขนาดไม่เกิน 350 KB';
      file.value = '';
      return;
    }
    const request = ++fileRead;
    submit.disabled = true;
    const reader = new FileReader();
    reader.onloadend = () => {
      if (request !== fileRead) return;
      submit.disabled = false;
      if (reader.error) { status.textContent = 'อ่านรูปไม่ได้'; return; }
      photo = reader.result;
      status.textContent = '';
      showPhoto();
    };
    reader.readAsDataURL(image);
  });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (!name.value.trim() || submit.disabled) return;
    submit.disabled = true;
    await save({
      p_category_code: category.value, p_code: resource.value || null, p_name: name.value.trim(),
      p_description: description.value.trim(), p_position: position.value.trim(),
      p_photo: photo, p_capacity: capacity.disabled ? null : Number(capacity.value)
    });
    submit.disabled = false;
  });
  loadCategory();
}
