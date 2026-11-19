function bookingCard(b,admin=false){
  let quick='';
  if(admin){
    const next=[];
    if(b.status==='slip_review'){}
    if(b.status==='pending_confirm' && (b.paymentVerified || b.amount===0)) next.push(['confirmed','ยืนยันการจอง','success']);
    if(b.status==='pending_payment' && b.amount===0) next.push(['confirmed','ยืนยันการจองฟรี','success']);
    if(b.status==='confirmed') next.push(['checked_in','เช็กอิน','soft']);
    if(b.status==='checked_in') next.push(['completed','ปิดงาน','soft']);
    if(!['completed','cancelled'].includes(b.status)) next.push(['cancelled','ยกเลิก','danger']);
    quick=`<div class="actions">${next.map(n=>`<button class="btn small ${n[2]}" onclick="changeStatus('${b.id}','${n[0]}')">${n[1]}</button>`).join('')}
      <select onchange="if(this.value) changeStatus('${b.id}',this.value)" style="height:36px;border:1px solid var(--line);border-radius:9px;padding:0 8px"><option value="">เปลี่ยนสถานะ...</option>${Object.entries(STATUS_LABEL).map(([k,v])=>`<option value="${k}">${v}</option>`).join('')}</select>
    </div>`;
  } else {
    if(['pending_payment','pending_confirm'].includes(b.status)) quick=`<div class="actions"><button class="btn small danger" onclick="changeStatus('${b.id}','cancelled')">ยกเลิกคำขอ</button></div>`;
  }
  if(admin && b.status==='slip_review') quick+=`<div class="actions"><button class="btn small success" onclick="demoApproveSlip('${b.id}')">✓ จำลองผล API: สลิปผ่าน</button><button class="btn small danger" onclick="demoRejectSlip('${b.id}')">✕ จำลองผล API: ไม่ผ่าน</button></div>`;
  if(!admin && b.status==='pending_payment') quick+=`<div class="actions"><button class="btn small soft" onclick="renderPaymentStep('${b.id}')">ดูวิธีชำระ/แนบสลิป</button></div>`;
  if(!admin && b.status==='pending_confirm' && b.paymentVerified) quick+=`<div class="actions"><button class="btn small success" onclick="customerConfirm('${b.id}')">ยืนยันการจองของฉัน</button></div>`;
  if(!admin && ['confirmed','checked_in','completed'].includes(b.status) && b.paymentVerified) quick+=`<div class="actions"><button class="btn small success" onclick="openTicket('${b.id}')">🎫 เปิดบัตรพร้อม QR</button></div>`;
  if(admin && b.slipName)quick+=`<p>📎 สลิปแนบ: ${esc(b.slipName)} ${b.slipImage?`<button class="btn small soft" onclick="viewSlip('${b.id}')">ดูรูปสลิป</button>`:''}</p>`;
  return `<article class="booking"><div class="booking-head"><div><h3>${esc(b.resourceName)} <span style="font-size:11px;color:#8590a6">${esc(b.id)}</span></h3><p>📌 ${esc(b.categoryName)} · 📅 ${esc(b.date)} · ${esc(b.startTime)}${b.endTime?` - ${esc(b.endTime)}`:''}</p><p>${bookingText(b)} · 💳 ${money(b.amount)} (${b.paymentMode==='deposit'?'มัดจำ':'ชำระเต็ม'})</p><p>👤 ${esc(b.name)} · ${esc(b.phone)} ${b.note?'· '+esc(b.note):''}</p></div><span class="status ${b.status}">${STATUS_LABEL[b.status]||b.status}</span></div>${quick}</article>`;
}
