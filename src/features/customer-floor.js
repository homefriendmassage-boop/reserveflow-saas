import { bounded, decorTypes, floorGeometry } from './floor-design.js';

const floor = document.getElementById('bookingFloor');
const section = document.getElementById('bookingFloorSection');
const status = document.getElementById('floorStatus');

function position(element, item, height, width, index = 0) {
  element.style.setProperty('--table-x', bounded(item.x, 15 + index % 4 * 23, 0, 100) + '%');
  element.style.setProperty('--table-y', bounded(item.y, 16 + Math.floor(index / 4) * 13, 0, 100) + '%');
  element.style.width = bounded(item.w, 84, 1) / width * 100 + '%';
  element.style.height = bounded(item.h, 60, 1) / height * 100 + '%';
}

export function showFloorMessage(message, visible = true) {
  section.classList.toggle('hidden', !visible);
  floor.classList.add('hidden');
  floor.replaceChildren();
  status.textContent = message;
}

export function renderFloor(plan, resources, resourceField, template) {
  const width = bounded(plan.width, 960, 1);
  const height = bounded(plan.height, 540, 1);
  floor.style.setProperty('--floor-width', width);
  floor.style.setProperty('--floor-max-width', width + 'px');
  floor.style.setProperty('--floor-height', height);
  floor.style.backgroundImage = plan.background ? 'url(' + JSON.stringify(plan.background) + ')' : '';
  floor.style.backgroundSize = plan.background ? 'cover' : '';
  const labels = plan.decorations.map(item => {
    const label = document.createElement('span');
    label.className = 'decor-block kind-' + (decorTypes.some(([key]) => key === item.type) ? item.type : 'label');
    label.textContent = item.label;
    position(label, item, height, width);
    return label;
  });
  const tables = new Map(plan.tables.map(table => [table.code, table]));
  const buttons = resources.flatMap((resource, index) => {
    const table = tables.get(resource.code);
    if (!table) return [];
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'resource';
    button.disabled = Boolean(table.occupied);
    const name = document.createElement('strong');
    name.textContent = resource.name;
    const availability = document.createElement('small');
    availability.className = 'floor-availability';
    button.append(name, availability);
    position(button, floorGeometry(table, index), height, width);
    button.addEventListener('click', () => {
      resourceField.value = resource.code;
      resourceField.dispatchEvent(new Event('input'));
    });
    button.dataset.code = resource.code;
    paintAvailability(button, table);
    return [button];
  });
  floor.replaceChildren(...labels, ...buttons);
  floor.classList.remove('hidden');
  status.textContent = ({ seat: 'เลือกที่นั่งว่างจากผัง', vip: 'เลือกห้องว่างจากผัง', table: 'เลือกโต๊ะว่างจากผัง' })[template];
  highlightTable(resourceField.value);
}

function paintAvailability(button, table) {
  const state = table.availability || (table.occupied ? 'booked' : 'available');
  button.disabled = Boolean(table.occupied);
  for (const name of ['booked', 'review', 'unpaid', 'selecting']) button.classList.toggle(name, state === name);
  button.querySelector('.floor-availability').textContent = ({
    booked: 'จองแล้ว', review: 'รอตรวจสลิป', unpaid: 'รอชำระ', selecting: 'กำลังเลือก'
  })[state] || 'ว่าง';
}

export function refreshFloorAvailability(plan) {
  const states = new Map(plan.tables.map(table => [table.code, table]));
  for (const button of floor.querySelectorAll('button[data-code]')) {
    const table = states.get(button.dataset.code);
    if (table) paintAvailability(button, table);
  }
}

export function highlightTable(code) {
  for (const button of floor.querySelectorAll('button[data-code]')) {
    const selected = button.dataset.code === code && !button.disabled;
    button.classList.toggle('selected', selected);
    button.setAttribute('aria-pressed', String(selected));
  }
}
