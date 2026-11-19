export function renderListResources(panel, categories, resources, save) {
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
  form.append(preview, remove, submit);
  panel.append(form, status);
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
    const rows = resources.filter(row => row.category_code === category.value);
    resource.replaceChildren(new Option('+ เพิ่มรายการใหม่', ''), ...rows.map(row => new Option(row.name, row.code)));
    loadResource();
  }
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
