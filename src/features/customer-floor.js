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

export function renderFloor(plan, resources, resourceField, template, showNextAvailable) {
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
    button.style.setProperty('--floor-label-length', Math.max(2, [...resource.name].length * .56));
    const name = document.createElement('strong');
    name.textContent = resource.name;
    const availability = document.createElement('small');
    availability.className = 'floor-availability';
    button.append(name, availability);
    position(button, floorGeometry(table, index), height, width);
    button.addEventListener('click', () => {
      if (button.dataset.occupied === 'true') {
        showNextAvailable?.(resource);
        return;
      }
      resourceField.value = resource.code;
      resourceField.dispatchEvent(new Event('input'));
    });
    button.dataset.code = resource.code;
    paintAvailability(button, table);
    return [button];
  });
  floor.replaceChildren(...labels, ...buttons);
  floor.classList.remove('hidden');
  status.dataset.availability = ({ seat: 'เลือกที่นั่งว่างจากผัง', vip: 'เลือกห้องว่างจากผัง', table: 'เลือกโต๊ะว่างจากผัง' })[template];
  status.textContent = status.dataset.availability + ' หรือกดจุดที่จองแล้วเพื่อดูเวลาว่างถัดไป';
  highlightTable(resourceField.value);
}

function paintAvailability(button, table) {
  const state = table.availability || (table.occupied ? 'booked' : 'available');
  button.dataset.occupied = String(Boolean(table.occupied));
  if (table.occupied) {
    button.classList.remove('selected');
    button.setAttribute('aria-pressed','false');
  }
  for (const name of ['booked', 'review', 'unpaid', 'selecting', 'in_use']) button.classList.toggle(name, state === name);
  const status = button.querySelector('.floor-availability');
  status.dataset.availability = ({
    booked: 'จองแล้ว', in_use: 'กำลังใช้งาน', review: 'รอตรวจสลิป', unpaid: 'รอชำระ', selecting: 'กำลังเลือก'
  })[state] || 'ว่าง';
  status.textContent = button.classList.contains('selected') && button.dataset.occupied !== 'true'
    ? 'คุณเลือกอยู่' : status.dataset.availability;
  button.title = button.querySelector('strong').textContent + ' · ' + status.textContent + (button.dataset.occupied === 'true' ? ' · กดดูเวลาว่างถัดไป' : '');
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
    const selected = button.dataset.code === code && button.dataset.occupied !== 'true';
    button.classList.toggle('selected', selected);
    const status = button.querySelector('.floor-availability');
    status.textContent = selected ? 'คุณเลือกอยู่' : status.dataset.availability;
    button.title = button.querySelector('strong').textContent + ' · ' + status.textContent + (button.dataset.occupied === 'true' ? ' · กดดูเวลาว่างถัดไป' : '');
    button.setAttribute('aria-pressed', String(selected));
  }
}
