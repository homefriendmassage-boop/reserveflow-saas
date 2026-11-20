export const passTokenPattern = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

export function renderPassDetails(list, pass) {
  const rows = [
    ['วันที่ใช้บริการ', pass.date],
    ['รายการที่จอง', [pass.category, pass.item].filter(Boolean).join(' · ')],
    ['ช่วงเวลาที่จอง', pass.period],
    ['จำนวนชั่วโมง', Number(pass.hours) + ' ชั่วโมง']
  ];
  if (pass.amount != null) rows.push(['รวมค่าจอง / บริการ',
    new Intl.NumberFormat('th-TH', { style: 'currency', currency: 'THB' }).format(pass.amount)]);
  list.replaceChildren(...rows.map(([name, value]) => {
    const row = document.createElement('div');
    const label = document.createElement('dt');
    const detail = document.createElement('dd');
    label.textContent = name;
    detail.textContent = value;
    row.append(label, detail);
    return row;
  }));
}

export function passStatus(pass) {
  return {
    cancelled: 'ยกเลิกแล้ว', checked_in: 'เช็กอินแล้ว', completed: 'ใช้บริการแล้ว'
  }[pass.status] || (pass.expired ? 'หมดเวลาใช้บัตร'
    : pass.status === 'confirmed' ? 'ยืนยันการจองแล้ว' : 'รอยืนยันการจอง');
}
