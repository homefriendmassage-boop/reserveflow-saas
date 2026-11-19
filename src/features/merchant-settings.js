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
  const section = node('details');
  section.className = 'merchant-settings-panel';
  section.append(node('summary', title));
  return section;
}

const templates = [['table','โต๊ะ'],['staff','พนักงาน'],['vip','ห้อง VIP'],['seat','ที่นั่ง'],['ticket','บัตร']];

export function renderMerchantSettings(container, { categories, resources, layouts, owner, save, reload }) {
  const message = node('p');
  message.setAttribute('role', 'status');
  let saving = false;

  async function persist(rpc, args, section, categoryCode, resourceCode) {
    if (saving) return;
    saving = true;
    message.textContent = 'กำลังบันทึก…';
    try {
      await save(rpc, args);
      await reload();
      const replacement = container.querySelector(`[data-section="${section}"]`);
      if (replacement) replacement.open = true;
      const categorySelect = replacement?.querySelector('[data-floor-category]');
      if (categorySelect && categoryCode) {
        categorySelect.value = categoryCode;
        categorySelect.dispatchEvent(new Event('change'));
        const resourceSelect = replacement.querySelector('[data-floor-item]');
        if (resourceCode && [...resourceSelect.options].some(option => option.value === resourceCode)) {
          resourceSelect.value = resourceCode;
          resourceSelect.dispatchEvent(new Event('change'));
        }
      }
      const freshMessage = container.querySelector('[role=status]');
      if (freshMessage) freshMessage.textContent = 'บันทึกแล้ว';
    } catch {
      message.textContent = 'บันทึกไม่ได้ กรุณาตรวจข้อมูลและสิทธิ์ของบัญชี';
    } finally {
      saving = false;
    }
  }

  const panels = [];
  if (owner) {
    const categoryPanel = panel('ตั้งค่าหมวดการจอง');
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
    panels.push(categoryPanel);
  }

  const floorPanel = panel('ออกแบบผังโต๊ะและที่นั่ง');
  floorPanel.dataset.section = 'floor';
  const floorCategories = categories.filter(category => ['table', 'seat'].includes(category.template));
  if (floorCategories.length) {
    const categoryArea = node('div');
    categoryArea.className = 'fields';
    const category = field(categoryArea, 'แก้ผังหมวด', select(floorCategories.map(item => [item.code, item.name])));
    category.dataset.floorCategory = '';
    const frame = node('div');
    frame.className = 'fields';
    const aspect = field(frame, 'รูปแบบกรอบผัง', select([['custom','กำหนดเอง'],['portrait','แนวตั้ง (3:4)'],['wide','แนวนอน (16:9)'],['square','สี่เหลี่ยมจัตุรัส']]));
    const width = field(frame, 'ความกว้าง (px)', input('number', 960, 320, 1600));
    const height = field(frame, 'ความสูง (px)', input('number', 540, 280, 1600));
    const saveFrame = button('บันทึกผัง');
    const grid = button('ใช้ Template ตาราง');
    frame.append(saveFrame, grid);
    const canvas = node('div');
    canvas.className = 'plan customer-plan merchant-floor-canvas';

    const editor = node('form');
    editor.className = 'fields';
    const item = field(editor, 'จุดจอง', select([]));
    item.dataset.floorItem = '';
    const name = field(editor, 'ชื่อจุดจอง', input('text', ''));
    name.maxLength = 100;
    const capacity = field(editor, 'ความจุ', input('number', 1, 1, 100));
    const x = field(editor, 'ซ้าย → ขวา (%)', input('number', 50, 5, 95));
    const y = field(editor, 'บน → ล่าง (%)', input('number', 50, 5, 95));
    const itemWidth = field(editor, 'กว้าง (px)', input('number', 84, 24, 320));
    const itemHeight = field(editor, 'สูง (px)', input('number', 72, 24, 320));
    const tools = node('div');
    tools.className = 'inline-actions';
    const addItem = button('+ เพิ่มจุดจอง');
    const clone = button('คัดลอกจุดที่เลือก');
    const saveItem = button('บันทึกจุดจอง');
    tools.append(addItem, clone, saveItem);
    const decorBar = node('div');
    decorBar.className = 'fields';
    const decorName = field(decorBar, 'ชื่อบล็อกผัง', input('text', ''));
    decorName.maxLength = 80;
    const addDecor = button('+ เพิ่มบล็อก');
    const removeDecor = button('นำบล็อกสุดท้ายออก');
    decorBar.append(addDecor, removeDecor);
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
      const blocks = decor.map(block => {
        const label = node('span', block.label);
        label.className = 'merchant-floor-label';
        place(label, block, columns, rows);
        return label;
      });
      const tiles = items.map((resource, index) => {
        const selected = resource.code === item.value;
        const tile = button(resource.name);
        tile.className = 'resource' + (selected ? ' selected' : '');
        const defaults = { x: 17 + (index % 3) * 33, y: 20 + Math.floor(index / 3) * 14, w: 84, h: 72 };
        place(tile, selected ? { x: x.value, y: y.value, w: itemWidth.value, h: itemHeight.value }
          : { ...defaults, ...resource.display }, columns, rows);
        tile.addEventListener('click', () => {
          if (resource.code === item.value) return;
          item.value = resource.code;
          loadItem();
        });
        tile.addEventListener('pointerdown', event => {
          if (event.button !== 0 || dragging) return;
          item.value = resource.code;
          loadItem(false);
          dragging = { id: event.pointerId, left: event.clientX, top: event.clientY, x: Number(x.value), y: Number(y.value) };
          tile.setPointerCapture(event.pointerId);
        });
        tile.addEventListener('pointermove', event => {
          if (dragging?.id !== event.pointerId) return;
          const bounds = canvas.getBoundingClientRect();
          const clamp = value => Math.max(5, Math.min(95, Math.round(value)));
          x.value = clamp(dragging.x + (event.clientX - dragging.left) * 100 / bounds.width);
          y.value = clamp(dragging.y + (event.clientY - dragging.top) * 100 / bounds.height);
          place(tile, { x: x.value, y: y.value, w: itemWidth.value, h: itemHeight.value }, columns, rows);
        });
        for (const event of ['pointerup','pointercancel']) tile.addEventListener(event, pointer => {
          if (dragging?.id !== pointer.pointerId) return;
          dragging = undefined;
          draw();
        });
        return tile;
      });
      canvas.replaceChildren(...blocks, ...tiles);
    }

    function loadItem(redraw = true) {
      const resource = items.find(row => row.code === item.value);
      const index = Math.max(0, items.indexOf(resource));
      name.value = resource?.name ?? '';
      capacity.value = resource?.capacity ?? 1;
      x.value = resource?.display?.x == null ? (resource ? 17 + (index % 3) * 33 : 50) : Math.round(resource.display.x);
      y.value = resource?.display?.y == null ? (resource ? Math.min(95, 20 + Math.floor(index / 3) * 14) : 50) : Math.round(resource.display.y);
      itemWidth.value = resource?.display?.w ?? 84;
      itemHeight.value = resource?.display?.h ?? 72;
      clone.disabled = !resource;
      if (redraw) draw();
    }

    function loadFloor() {
      const data = layouts.find(layout => layout.category_code === category.value);
      width.value = data?.width ?? 960;
      height.value = data?.height ?? 540;
      aspect.value = 'custom';
      decor = Array.isArray(data?.decorations) ? [...data.decorations] : [];
      items = resources.filter(resource => resource.category_code === category.value);
      item.replaceChildren(...items.map(resource => new Option(resource.name, resource.code)), new Option('+ เพิ่มจุดจอง', ''));
      loadItem();
    }

    const saveFloor = applyGrid => {
      if (!width.reportValidity() || !height.reportValidity()) return;
      void persist('save_merchant_floor', {
        p_category_code: category.value, p_width: Number(width.value), p_height: Number(height.value),
        p_grid: applyGrid, p_decorations: decor
      }, 'floor', category.value, item.value);
    };
    saveFrame.addEventListener('click', () => saveFloor(false));
    grid.addEventListener('click', () => saveFloor(true));
    aspect.addEventListener('change', () => {
      const size = { portrait: [540,720], wide: [960,540], square: [700,700] }[aspect.value];
      if (size) [width.value, height.value] = size;
      draw();
    });
    addDecor.addEventListener('click', () => {
      if (!decorName.reportValidity() || !decorName.value.trim() || decor.length >= 30) return;
      decor.push({ label: decorName.value.trim(), x: 50, y: 12 + (decor.length % 5) * 10, w: 140, h: 36 });
      decorName.value = '';
      draw();
    });
    removeDecor.addEventListener('click', () => { decor.pop(); draw(); });
    item.addEventListener('change', loadItem);
    category.addEventListener('change', loadFloor);
    for (const control of [width, height, x, y, itemWidth, itemHeight]) control.addEventListener('input', draw);
    addItem.addEventListener('click', () => {
      item.value = '';
      loadItem();
      name.focus();
    });
    saveItem.addEventListener('click', () => editor.requestSubmit());
    clone.addEventListener('click', () => {
      item.value = '';
      name.value = (name.value + ' (สำเนา)').slice(0, 100);
      name.focus();
      x.value = Math.min(95, Number(x.value) + 8);
      clone.disabled = true;
      draw();
    });
    editor.addEventListener('submit', event => {
      event.preventDefault();
      void persist('save_merchant_floor_item', {
        p_category_code: category.value, p_code: item.value || null, p_name: name.value.trim(),
        p_capacity: Number(capacity.value), p_x: Number(x.value), p_y: Number(y.value),
        p_width: Number(itemWidth.value), p_height: Number(itemHeight.value)
      }, 'floor', category.value, item.value);
    });
    const hint = node('p', 'เลือกหรือลากโต๊ะบนผัง แล้วกดบันทึกจุดจอง');
    hint.className = 'sub';
    floorPanel.append(categoryArea, frame, tools, hint, canvas, editor, decorBar);
    loadFloor();
  } else {
    floorPanel.append(node('p', 'เพิ่มหมวดโต๊ะหรือที่นั่งเพื่อเริ่มสร้างผัง'));
  }
  panels.push(floorPanel, message);
  container.replaceChildren(...panels);
}
