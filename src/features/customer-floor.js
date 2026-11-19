const floor = document.getElementById('bookingFloor');
const section = document.getElementById('bookingFloorSection');
const status = document.getElementById('floorStatus');

function bounded(value, fallback, min, max) {
  const number = Number(value ?? fallback);
  return Number.isFinite(number) ? Math.max(min, Math.min(max, number)) : fallback;
}

function position(element, item, height, width, index = 0) {
  element.style.setProperty('--table-x', bounded(item.x, 15 + index % 4 * 23, 5, 95) + '%');
  element.style.setProperty('--table-y', bounded(item.y, 16 + Math.floor(index / 4) * 13, 5, 95) + '%');
  element.style.width = bounded(item.w, 84, 25, width) / width * 100 + '%';
  element.style.height = bounded(item.h, 60, 25, height) / height * 100 + '%';
}

export function showFloorMessage(message, visible = true) {
  section.classList.toggle('hidden', !visible);
  floor.classList.add('hidden');
  floor.replaceChildren();
  status.textContent = message;
}

export function renderFloor(plan, resources, resourceField, template) {
  const width = bounded(plan.width, 960, 320, 1600);
  const rows = Math.ceil(plan.tables.filter(table => table.x == null || table.y == null).length / 4);
  const height = Math.max(bounded(plan.height, 540, 280, 1600), rows * 70 + 80);
  floor.style.setProperty('--floor-width', width);
  floor.style.setProperty('--floor-max-width', width + 'px');
  floor.style.setProperty('--floor-height', height);
  const labels = plan.decorations.map(item => {
    const label = document.createElement('span');
    label.className = 'floor-label';
    label.textContent = item.label;
    position(label, item, height, width);
    return label;
  });
  const tables = new Map(plan.tables.map(table => [table.code, table]));
  let unpositioned = 0;
  const buttons = resources.flatMap(resource => {
    const table = tables.get(resource.code);
    if (!table) return [];
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'resource';
    button.disabled = table.occupied;
    const name = document.createElement('strong');
    name.textContent = resource.code;
    const availability = document.createElement('small');
    availability.textContent = table.occupied ? 'จองแล้ว' : 'ว่าง';
    button.append(name, availability);
    if (table.x == null || table.y == null) {
      const index = unpositioned++;
      position(button, { ...table, x: null, y: (Math.floor(index / 4) * 70 + 60) / height * 100 }, height, width, index);
    } else {
      position(button, table, height, width);
    }
    button.addEventListener('click', () => {
      resourceField.value = resource.code;
      resourceField.dispatchEvent(new Event('input'));
    });
    button.dataset.code = resource.code;
    button.classList.toggle('booked', table.occupied);
    return [button];
  });
  floor.replaceChildren(...labels, ...buttons);
  floor.classList.remove('hidden');
  status.textContent = template === 'seat' ? 'เลือกที่นั่งว่างจากผัง' : 'เลือกโต๊ะว่างจากผัง';
  highlightTable(resourceField.value);
}

export function highlightTable(code) {
  for (const button of floor.querySelectorAll('button[data-code]')) {
    const selected = button.dataset.code === code && !button.disabled;
    button.classList.toggle('selected', selected);
    button.setAttribute('aria-pressed', String(selected));
  }
}
