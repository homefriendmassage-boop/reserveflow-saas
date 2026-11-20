import { renderListResources } from './merchant-list-resources.js?v=slips-1';
import { decorTypes, floorGeometry, legacyFloor, sampleTableFloor, templatePositions } from './floor-design.js';

function node(tag, text = '') {
  const element = document.createElement(tag);
  element.textContent = text;
  return element;
}

function field(form, text, control) {
  const label = node('label');
  label.className = 'field';
  label.append(node('span', text), control);
  form.append(label);
  return control;
}

function input(type, value, min, max) {
  const control = node('input');
  control.type = type;
  control.value = value;
  if (min != null) control.min = min;
  if (max != null) control.max = max;
  control.required = true;
  return control;
}

function button(text, type = 'button') {
  const result = node('button', text);
  result.type = type;
  result.className = 'btn soft small';
  return result;
}

function select(options) {
  const control = node('select');
  control.replaceChildren(...options.map(([value, label]) => new Option(label, value)));
  return control;
}

function panel(title) {
  const section = node('section');
  section.className = 'panel';
  section.append(node('h2', title));
  return section;
}

const templates = [['table','โต๊ะ'],['staff','พนักงาน'],['vip','ห้อง VIP'],['seat','ที่นั่ง'],['ticket','บัตร']];

export function renderMerchantSettings(container, { categoryContainer, categories, resources, layouts, owner, save, reload }) {
  const message = node('p');
  message.setAttribute('role', 'status');
  let saving = false;

  async function persist(rpc, args, section, categoryCode, resourceCode, blockIndex) {
    if (saving) return;
    const floorPicker = container.querySelector('[data-floor-category]');
    if (floorPicker) floorPicker.disabled = true;
    const feedbackArea = section === 'categories' ? categoryContainer : container;
    const feedback = feedbackArea.querySelector(`[data-section="${section}"] [role=status]`);
    saving = true;
    feedback.textContent = 'กำลังบันทึก…';
    try {
      const result = await save(rpc, args);
      const selectedCode = rpc === 'save_merchant_floor_item' ? result || resourceCode : resourceCode;
      await reload();
      const replacement = (section === 'categories' ? categoryContainer : container).querySelector(`[data-section="${section}"]`);
      const categorySelect = replacement?.querySelector(section === 'resources' ? '[data-list-category]' : '[data-floor-category]');
      if (categorySelect && categoryCode) {
        categorySelect.value = categoryCode;
        categorySelect.dispatchEvent(new Event('change'));
        const resourceSelect = replacement.querySelector(section === 'resources' ? '[data-list-resource]' : '[data-floor-item]');
        const savedOption = [...resourceSelect.options].find(option =>
          selectedCode ? option.value === selectedCode :
            rpc === 'save_merchant_list_resource' && option.value && option.text === args.p_name);
        if (savedOption) {
          resourceSelect.value = savedOption.value;
          resourceSelect.dispatchEvent(new Event('change'));
        }
        if (blockIndex != null) replacement.querySelectorAll('.editor-decor')[blockIndex]?.click();
      }
      const freshMessage = feedbackArea.querySelector(`[data-section="${section}"] [role=status]`);
      if (freshMessage) freshMessage.textContent = rpc === 'archive_merchant_list_resource' ? 'ลบออกจากหน้าจองแล้ว' : 'บันทึกแล้ว';
      return true;
    } catch (error) {
      feedback.textContent = error?.message === 'RESOURCE_NAME_EXISTS'
        ? 'ชื่อนี้มีอยู่แล้วในหมวดนี้ กรุณาใช้ชื่ออื่น'
        : error?.message === 'INVALID_TABLE_POSITION' && rpc === 'save_merchant_floor_item' &&
          (args.p_width < 24 || args.p_height < 24 || args.p_width > 320 || args.p_height > 320 ||
            args.p_x < 5 || args.p_y < 5 || args.p_x > 95 || args.p_y > 95)
          ? 'ฐานข้อมูลร้านยังจำกัดขนาดผัง กรุณารัน SQL ปรับขนาดผัง (ไฟล์ 14) แล้วลองอีกครั้ง'
        : error?.code === '23503' && args.p_design?.remove_item
        ? 'ลบจุดไม่ได้ เพราะจุดนี้มีประวัติการจอง'
        : error?.code === 'PGRST202' ? 'ต้องอัปเดต SQL ระบบผังก่อนใช้เครื่องมือนี้'
          : 'บันทึกไม่ได้ กรุณาตรวจข้อมูลและสิทธิ์ของบัญชี';
    } finally {
      saving = false;
      if (floorPicker) floorPicker.disabled = false;
    }
  }

  categoryContainer.replaceChildren();
  if (owner) {
    const categoryPanel = panel('ตั้งค่าหมวดการจอง');
    const hint = node('p', 'แก้ชื่อหมวด การแสดงผล ราคา ค่าบริการ และลำดับที่ลูกค้าเห็น');
    hint.className = 'sub';
    categoryPanel.append(hint);
    categoryPanel.dataset.section = 'categories';
    if (categories.length) {
      const header = node('div');
      header.className = 'merchant-category-header';
      header.setAttribute('aria-hidden', 'true');
      header.append(...['ชื่อหมวด', 'แม่แบบ', 'แสดงผล', 'ราคาเริ่มต้น', 'ค่าบริการ', 'ลำดับ', 'ย้ายลำดับ', 'จัดการ'].map(label => node('span', label)));
      categoryPanel.append(header);
    }
    for (const category of [...categories, null]) {
      const form = node('form');
      form.className = category ? 'fields merchant-category-row' : 'fields merchant-category-add';
      const name = field(form, 'ชื่อหมวด', input('text', category?.name ?? ''));
      name.maxLength = 100;
      const type = field(form, 'แม่แบบ', select(templates));
      type.value = category?.template || 'table';
      type.disabled = Boolean(category);
      const visible = field(form, 'แสดงผล', select([['true','แสดง'],['false','ซ่อน']]));
      visible.value = String(category?.visible ?? true);
      const price = field(form, 'ราคาเริ่มต้น', input('number', category?.price ?? 0, 0, 99999999.99));
      const fee = field(form, 'ค่าบริการ', input('number', category?.service_fee ?? 0, 0, 99999999.99));
      price.step = fee.step = '0.01';
      const order = field(form, 'ลำดับ', input('number', category?.sort_order ?? Math.min(10000, (categories.at(-1)?.sort_order ?? 0) + 1), 0, 10000));
      if (category) {
        const actions = node('div');
        actions.className = 'inline-actions';
        const index = categories.indexOf(category);
        for (const [direction, label] of [[-1, '↑ ขึ้น'], [1, '↓ ลง']]) {
          const move = button(label);
          move.disabled = !categories[index + direction];
          move.setAttribute('aria-label', label + ' ' + category.name);
          move.addEventListener('click', () => void persist('move_merchant_category', {
            p_code: category.code, p_direction: direction
          }, 'categories'));
          actions.append(move);
        }
        form.append(actions);
      }
      form.append(button(category ? 'บันทึกหมวด' : '+ เพิ่มหมวดใหม่', 'submit'));
      form.addEventListener('submit', event => {
        event.preventDefault();
        void persist('save_merchant_category', {
          p_code: category?.code ?? null, p_name: name.value.trim(), p_template: type.value,
          p_visible: visible.value === 'true', p_price: Number(price.value), p_fee: Number(fee.value),
          p_order: Number(order.value)
        }, 'categories');
      });
      categoryPanel.append(form);
    }
    categoryPanel.append(message);
    categoryContainer.append(categoryPanel);
  }

  const floorPanel = panel('🗺️ ออกแบบผังโต๊ะ ที่นั่ง และห้อง');
  floorPanel.dataset.section = 'floor';
  const floorCategories = categories.filter(category => ['table', 'seat', 'vip'].includes(category.template));
  if (floorCategories.length) {
    const categoryArea = node('div');
    categoryArea.className = 'layout-tools';
    const category = field(categoryArea, 'แก้ผังหมวด', select(floorCategories.map(item => [item.code, item.name])));
    category.dataset.floorCategory = '';
    const frame = node('div');
    frame.className = 'layout-size-controls';
    const aspect = field(frame, 'รูปแบบกรอบผัง', select([['custom','กำหนดเอง'],['portrait','แนวตั้ง (3:4)'],['wide','แนวนอน (16:9)'],['square','สี่เหลี่ยมจัตุรัส']]));
    const width = field(frame, 'ความกว้าง (px)', input('number', 960, 1));
    const height = field(frame, 'ความสูง (px)', input('number', 540, 1));
    const saveFrame = button('บันทึกผัง');
    const template = field(categoryArea, 'รูปแบบ Template', select([
      ['grid','ตารางแถวและคอลัมน์'], ['rows','เรียงเป็นแถว'], ['columns','เรียงเป็นคอลัมน์'],
      ['u','รูปตัว U'], ['circle','ครึ่งวงกลม / รอบเวที']
    ]));
    const grid = button('ใช้ Template');
    const canvas = node('div');
    canvas.className = 'plan customer-plan merchant-floor-canvas';

    const editor = node('form');
    editor.className = 'fields';
    const item = field(editor, 'จุดจอง', select([]));
    item.dataset.floorItem = '';
    const name = field(editor, 'ชื่อจุดจอง', input('text', ''));
    name.maxLength = 100;
    const capacity = field(editor, 'จำนวนคนสูงสุดต่อจุด', input('number', 1, 1, 100));
    const x = field(editor, 'ซ้าย → ขวา (%)', input('number', 50, 0, 100));
    const y = field(editor, 'บน → ล่าง (%)', input('number', 50, 0, 100));
    const itemWidth = field(editor, 'กว้าง (px)', input('number', 84, 1));
    const itemHeight = field(editor, 'สูง (px)', input('number', 72, 1));
    const addItem = button('+ เพิ่มจุดจอง');
    const clone = button('คัดลอกจุดที่เลือก');
    const saveItem = button('บันทึกจุดจอง');
    categoryArea.append(grid, addItem, clone);
    const upload = field(categoryArea, 'ภาพผังพื้นหลัง (JPG/PNG/WebP)', node('input'));
    upload.type = 'file';
    upload.accept = 'image/jpeg,image/png,image/webp';
    const clearBackground = button('ลบภาพพื้นหลัง');
    clearBackground.className = 'btn danger small';
    const sample = button('ใช้ผังตัวอย่าง 6 โต๊ะ');
    const restore = button('กู้ผังเดิมจากเบราว์เซอร์นี้');
    const restoreHelp = node('p');
    restoreHelp.className = 'sub';
    categoryArea.append(clearBackground, restore, sample);
    const deleteItem = button('ลบจุดนี้');
    deleteItem.className = 'btn danger small';
    editor.append(saveItem, deleteItem);
    const decorType = field(frame, 'ชนิดบล็อกประกอบผัง', select(decorTypes));
    const addDecor = button('+ เพิ่มบล็อก');
    frame.append(addDecor, saveFrame);
    const blockEditor = node('form');
    blockEditor.className = 'fields merchant-block-editor hidden';
    const blockType = field(blockEditor, 'ประเภทบล็อก', select(decorTypes));
    const blockName = field(blockEditor, 'ข้อความบนบล็อก', input('text', ''));
    blockName.maxLength = 80;
    const blockWidth = field(blockEditor, 'กว้าง (px)', input('number', 130, 1));
    const blockHeight = field(blockEditor, 'สูง (px)', input('number', 58, 1));
    const blockX = field(blockEditor, 'ตำแหน่ง X (%)', input('number', 50, 0, 100));
    const blockY = field(blockEditor, 'ตำแหน่ง Y (%)', input('number', 50, 0, 100));
    for (const control of [blockX, blockY, blockWidth, blockHeight, x, y]) control.step = 'any';
    const removeDecor = button('ลบบล็อกนี้');
    removeDecor.className = 'btn danger small';
    blockEditor.append(button('บันทึกบล็อก', 'submit'), removeDecor);
    let activeBlock = -1;
    let background;
    let recovery;
    let items = [];
    let decor = [];
    let dragging;

    function place(element, geometry, columns = 960, rows = 540) {
      element.style.setProperty('--table-x', Number(geometry.x) + '%');
      element.style.setProperty('--table-y', Number(geometry.y) + '%');
      element.style.width = Number(geometry.w) / columns * 100 + '%';
      element.style.height = Number(geometry.h) / rows * 100 + '%';
    }

    function draw() {
      const columns = Number(width.value) || 960;
      const rows = Number(height.value) || 540;
      canvas.style.setProperty('--floor-width', columns);
      canvas.style.setProperty('--floor-height', rows);
      canvas.style.setProperty('--floor-max-width', columns + 'px');
      canvas.style.backgroundImage = background ? `url("${background}")` : '';
      const blocks = decor.map((block, index) => {
        const label = button(block.label);
        label.className = 'decor-block editor-decor kind-' + (decorTypes.some(([key]) => key === block.type) ? block.type : 'label');
        label.classList.toggle('active', index === activeBlock);
        place(label, block, columns, rows);
        label.addEventListener('click', () => selectBlock(index));
        bindDrag(label, block, (next, moved) => {
          decor[index] = next;
          selectBlock(index);
          if (moved) void saveDesign({ decorations: decor }, index);
        });
        return label;
      });
      const tiles = items.map((resource, index) => {
        const selected = resource.code === item.value;
        const tile = button('');
        tile.append(node('strong', resource.name));
        tile.setAttribute('aria-label', resource.name);
        tile.className = 'resource' + (selected ? ' selected' : '');
        const geometry = selected ? { x: Number(x.value), y: Number(y.value), w: Number(itemWidth.value), h: Number(itemHeight.value) }
          : floorGeometry(resource.display, index);
        place(tile, geometry, columns, rows);
        tile.addEventListener('click', () => {
          item.value = resource.code;
          loadItem();
        });
        if (!resource.pending) bindDrag(tile, geometry, (next, moved) => {
          item.value = resource.code;
          if (moved) resource.display = next;
          loadItem();
          if (moved) void saveSelectedItem();
        });
        return tile;
      });
      canvas.replaceChildren(...blocks, ...tiles);
    }

    function bindDrag(element, geometry, finish) {
      let next = geometry;
      element.addEventListener('pointerdown', event => {
        if (event.button !== 0 || dragging || saving) return;
        dragging = { id: event.pointerId, left: event.clientX, top: event.clientY, moved: false };
        element.setPointerCapture(event.pointerId);
      });
      element.addEventListener('pointermove', event => {
        if (dragging?.id !== event.pointerId) return;
        const dx = event.clientX - dragging.left;
        const dy = event.clientY - dragging.top;
        if (Math.abs(dx) + Math.abs(dy) < 4 && !dragging.moved) return;
        dragging.moved = true;
        const bounds = canvas.getBoundingClientRect();
        const clamp = value => Math.max(0, Math.min(100, Math.round(value * 10) / 10));
        next = { ...geometry, x: clamp(Number(geometry.x) + dx * 100 / bounds.width),
          y: clamp(Number(geometry.y) + dy * 100 / bounds.height) };
        place(element, next, Number(width.value), Number(height.value));
      });
      element.addEventListener('pointerup', event => {
        if (dragging?.id !== event.pointerId) return;
        const moved = dragging.moved;
        dragging = undefined;
        if (moved) finish(next, true);
      });
      element.addEventListener('pointercancel', event => {
        if (dragging?.id !== event.pointerId) return;
        dragging = undefined;
        draw();
      });
    }

    function selectBlock(index) {
      activeBlock = index;
      item.value = '';
      editor.classList.add('hidden');
      blockEditor.classList.remove('hidden');
      const block = decor[index];
      blockType.value = decorTypes.some(([key]) => key === block.type) ? block.type : 'label';
      blockName.value = block.label;
      [blockX.value, blockY.value, blockWidth.value, blockHeight.value] = [block.x, block.y, block.w, block.h];
      clone.disabled = true;
      draw();
    }

    function loadItem() {
      activeBlock = -1;
      blockEditor.classList.add('hidden');
      const resource = items.find(row => row.code === item.value);
      const geometry = floorGeometry(resource?.display, items.indexOf(resource));
      editor.classList.toggle('hidden', !resource || Boolean(resource.pending));
      name.value = resource?.name ?? '';
      capacity.value = resource?.capacity ?? 1;
      [x.value, y.value, itemWidth.value, itemHeight.value] = [geometry.x, geometry.y, geometry.w, geometry.h];
      clone.disabled = !resource || Boolean(resource.pending);
      draw();
    }

    function setItemOptions(selected = '') {
      item.replaceChildren(new Option('เลือกจุดบนผัง', ''),
        ...items.map(resource => new Option(resource.name, resource.code)));
      item.value = selected;
      loadItem();
    }

    function loadFloor() {
      const data = layouts.find(layout => layout.category_code === category.value);
      width.value = data?.width ?? 960;
      height.value = data?.height ?? 540;
      const dimensions = width.value + '×' + height.value;
      aspect.value = { '540×720': 'portrait', '960×540': 'wide', '700×700': 'square' }[dimensions] || 'custom';
      decor = Array.isArray(data?.decorations) ? [...data.decorations] : [];
      background = data?.background_image;
      items = resources.filter(resource => resource.category_code === category.value);
      const definition = floorCategories.find(row => row.code === category.value);
      sample.classList.toggle('hidden', definition.template !== 'table');
      recovery = legacyFloor(definition);
      restore.disabled = !recovery;
      restoreHelp.textContent = recovery
        ? `พบผังเดิมที่เก็บในเบราว์เซอร์นี้ ${recovery.items.length} จุด`
        : 'หากผังเดิมสร้างในหน้าเดโม ให้เปิดหน้านี้ด้วยเบราว์เซอร์และโปรไฟล์เดิมเพื่อกู้ผัง';
      setItemOptions();
    }

    const saveDesign = (design, blockIndex) => persist('update_merchant_floor_design', {
      p_category_code: category.value, p_design: design
    }, 'floor', category.value, item.value, blockIndex);

    function saveFrameSize() {
      if (saving || !width.reportValidity() || !height.reportValidity()) return;
      void saveDesign({ width: Number(width.value), height: Number(height.value) });
    }
    saveFrame.addEventListener('click', saveFrameSize);
    grid.addEventListener('click', () => {
      if (items.length && !saving && confirm('จัดตำแหน่งจุดทั้งหมดตาม Template นี้หรือไม่?')) {
        void saveDesign({ items: templatePositions([...items].sort((a, b) => a.code.localeCompare(b.code)), template.value) });
      }
    });
    sample.addEventListener('click', () => {
      if (!saving && confirm('ใช้ผังตัวอย่าง 6 โต๊ะ? ระบบจะจัดตำแหน่ง T01–T06 ตามตัวอย่างและเก็บโต๊ะอื่นไว้')) {
        void saveDesign(sampleTableFloor(items, decor));
      }
    });
    restore.addEventListener('click', () => {
      if (recovery && !saving && confirm('กู้ผังเดิมลงหมวดนี้? จุดรหัสเดียวกันจะใช้ตำแหน่งและข้อมูลจากผังเดิม')) {
        void saveDesign(recovery);
      }
    });
    upload.addEventListener('change', () => {
      const file = upload.files[0];
      if (!file || saving) return;
      if (file.size > 700 * 1024 || !['image/jpeg','image/png','image/webp'].includes(file.type)) {
        floorPanel.querySelector('[role=status]').textContent = 'ใช้ภาพ JPG, PNG หรือ WebP ขนาดไม่เกิน 700 KB';
        upload.value = '';
        return;
      }
      const reader = new FileReader();
      const target = category.value;
      reader.onload = () => {
        if (target === category.value && floorPanel.isConnected) void saveDesign({ background: reader.result });
      };
      reader.readAsDataURL(file);
    });
    clearBackground.addEventListener('click', () => { if (background && !saving) void saveDesign({ background: null }); });
    aspect.addEventListener('change', () => {
      const size = { portrait: [540,720], wide: [960,540], square: [700,700] }[aspect.value];
      if (size) [width.value, height.value] = size;
      draw();
      if (size) saveFrameSize();
    });
    addDecor.addEventListener('click', async () => {
      if (saving || decor.length >= 100) return;
      const type = decorType.value;
      const block = { type, label: decorType.selectedOptions[0].text, x: 50, y: 50, w: 130, h: 58 };
      decor.push(block);
      selectBlock(decor.length - 1);
      if (!await saveDesign({ decorations: decor }, activeBlock)) {
        decor.pop();
        loadItem();
      }
    });
    removeDecor.addEventListener('click', async () => {
      if (activeBlock < 0 || saving) return;
      const index = activeBlock;
      const remaining = decor.filter((_, i) => i !== index);
      await saveDesign({ decorations: remaining });
    });
    blockEditor.addEventListener('submit', event => {
      event.preventDefault();
      if (activeBlock < 0 || saving || !blockName.value.trim()) return;
      const updated = { ...decor[activeBlock], type: blockType.value, label: blockName.value.trim(),
        x: Number(blockX.value), y: Number(blockY.value), w: Number(blockWidth.value), h: Number(blockHeight.value) };
      void saveDesign({ decorations: decor.map((block, index) => index === activeBlock ? updated : block) }, activeBlock);
    });
    item.addEventListener('change', loadItem);
    category.addEventListener('change', loadFloor);
    for (const control of [width, height, x, y, itemWidth, itemHeight]) control.addEventListener('input', draw);

    function savePoint(code, label, seats, geometry) {
      return persist('save_merchant_floor_item', {
        p_category_code: category.value, p_code: code, p_name: label, p_capacity: seats,
        p_x: Math.round(geometry.x), p_y: Math.round(geometry.y),
        p_width: Math.round(geometry.w), p_height: Math.round(geometry.h)
      }, 'floor', category.value, code);
    }

    function saveSelectedItem() {
      if (!item.value || !editor.reportValidity() || !name.value.trim()) return;
      if (items.some(row => row.code !== item.value && row.name.trim().toLowerCase() === name.value.trim().toLowerCase())) {
        floorPanel.querySelector('[role=status]').textContent = 'ชื่อนี้มีอยู่แล้วในหมวดนี้ กรุณาใช้ชื่ออื่น';
        name.focus();
        return;
      }
      return savePoint(item.value, name.value.trim(), Number(capacity.value), {
        x: Number(x.value), y: Number(y.value), w: Number(itemWidth.value), h: Number(itemHeight.value)
      });
    }

    async function addPoint(copy) {
      if (saving) return;
      const kind = floorCategories.find(row => row.code === category.value).template;
      const prefix = ({ table: 'โต๊ะ', seat: 'ที่นั่ง', vip: 'ห้อง' })[kind];
      let sequence = items.length + 1;
      while (items.some(resource => resource.name === prefix + ' ' + sequence)) sequence++;
      const original = items.find(row => row.code === item.value);
      if (copy && !original) return;
      const geometry = floorGeometry(original?.display, items.indexOf(original));
      const base = ((original?.name || '').slice(0, 85) + ' (สำเนา)').trim();
      let copyName = base;
      let copyIndex = 2;
      while (items.some(row => row.name.trim().toLowerCase() === copyName.toLowerCase())) copyName = base + ' ' + copyIndex++;
      const temp = {
        code: 'F-pending', pending: true,
        name: copy ? copyName : prefix + ' ' + sequence,
        capacity: copy ? original.capacity ?? (kind === 'seat' ? 1 : 4) : kind === 'seat' ? 1 : 4,
        display: copy ? { ...geometry, x: geometry.x + (geometry.x > 87 ? -8 : 8), y: geometry.y + (geometry.y > 90 ? -5 : 5) }
          : { x: 50, y: 50, w: 84, h: 72 }
      };
      items.push(temp);
      setItemOptions(temp.code);
      if (!await savePoint(null, temp.name, temp.capacity, temp.display)) {
        items = items.filter(resource => resource !== temp);
        setItemOptions(original?.code);
      }
    }
    addItem.addEventListener('click', () => void addPoint(false));
    clone.addEventListener('click', () => void addPoint(true));
    deleteItem.addEventListener('click', () => {
      if (item.value && !saving && confirm('ลบจุดจองที่เลือกหรือไม่?')) void saveDesign({ remove_item: item.value });
    });
    saveItem.addEventListener('click', () => editor.requestSubmit());
    editor.addEventListener('submit', event => {
      event.preventDefault();
      void saveSelectedItem();
    });
    const hint = node('p', 'เลือกจุดเพื่อแก้ชื่อ ขนาด หรือตำแหน่ง แล้วกดบันทึกจุดจอง คัดลอกเพื่อเพิ่มจุดใหม่จากค่าที่บันทึกไว้');
    hint.className = 'sub';
    floorPanel.append(hint, categoryArea, restoreHelp, frame, canvas, editor, blockEditor);
    loadFloor();
  } else {
    floorPanel.append(node('p', 'เพิ่มหมวดโต๊ะหรือที่นั่งเพื่อเริ่มสร้างผัง'));
  }
  floorPanel.append(message.cloneNode());
  container.replaceChildren(floorPanel);
  const listCategories = categories.filter(row => ['staff', 'ticket'].includes(row.template));
  if (listCategories.length) {
    const listPanel = panel('จัดการพนักงานและโซนบัตร');
    listPanel.dataset.section = 'resources';
    renderListResources(listPanel, listCategories, resources, args =>
      persist('save_merchant_list_resource', args, 'resources', args.p_category_code, args.p_code),
    args => persist('archive_merchant_list_resource', args, 'resources', args.p_category_code));
    container.prepend(listPanel);
  }
}
