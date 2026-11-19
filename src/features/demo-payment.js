function findBooking(id){return getBookings().find(b=>b.id===id)}
function qrRender(target,payload){
  target.innerHTML='';
  if(typeof QRCode==='function'){
    new QRCode(target,{text:payload,width:164,height:164,colorDark:'#17233e',colorLight:'#ffffff',correctLevel:QRCode.CorrectLevel.M});
  }else{
    target.innerHTML='<div style="padding:12px;color:#b56f12;font-size:12px">ไม่สามารถโหลดตัวสร้าง QR ได้เมื่อออฟไลน์<br>ใช้เลขการจองตรวจสอบในเดโมแทน</div>';
  }
}
function renderPaymentStep(id){
  const b=findBooking(id);if(!b)return;
  const shop=getConfig().shop||DEFAULT_CONFIG.shop;
  const accountReady=!!(shop.bankName&&shop.bankNumber&&shop.bankOwner);
  const el=$('paymentStep');el.classList.remove('hidden');
  el.innerHTML=`<div class="payment-panel"><h3>💳 ขั้นตอนชำระเงิน • ${esc(b.id)}</h3>
    <div class="row"><span>ชื่อร้าน</span><b>${esc(shop.name)}</b></div>
    <div class="row"><span>รูปแบบ</span><b>${b.paymentMode==='deposit'?'มัดจำ':'ชำระเต็ม'}</b></div>
    <div class="row total"><span>ยอดชำระ</span><b>${money(b.amount)}</b></div>
    ${accountReady?`<p style="margin:14px 0 4px">บัญชีธนาคารสำหรับโอนเงิน</p><div class="row"><span>ธนาคาร</span><b>${esc(shop.bankName)}</b></div><div class="row"><span>ชื่อบัญชี</span><b>${esc(shop.bankOwner)}</b></div><div class="row"><span>เลขบัญชี</span><b>${esc(shop.bankNumber)}</b></div>`:
       '<div class="notice" style="margin-top:12px">ยังไม่ได้ตั้งค่าบัญชีรับเงิน กรุณาให้ร้านตั้งค่าจากหลังบ้านก่อน ไม่ควรโอนเงิน</div>'}
    ${shop.promptpayId?`<div class="row"><span>พร้อมเพย์ร้าน</span><b>${esc(shop.promptpayId)}</b></div>`:''}
    <div class="notice">เดโมไม่สร้าง QR พร้อมเพย์สำหรับโอนเงินจริง เพื่อป้องกันการโอนผิดบัญชี การเชื่อม Payment QR จริงต้องใช้ข้อมูลที่ผ่านการตรวจสอบและยืนยันยอดจากเซิร์ฟเวอร์</div>
    <div class="field"><label>แนบรูปสลิปโอนเงิน (ทดลอง)</label><input type="file" id="slipFile" accept="image/png,image/jpeg,image/webp"></div>
    <button class="btn primary full" style="margin-top:12px" onclick="submitSlip('${b.id}')" ${accountReady?'':'disabled'}>📎 ส่งสลิปให้ตรวจสอบ (จำลอง)</button>
    <div class="note">การส่งในเดโมเปลี่ยนสถานะเป็น “รอตรวจสลิป” เท่านั้น ไม่ได้ติดต่อ API หรือตรวจเงินเข้าจริง</div>
  </div>`;
  el.scrollIntoView({behavior:'smooth',block:'nearest'});
}
function submitSlip(id){
  const file=$('slipFile')?.files?.[0];if(!file)return toast('กรุณาแนบไฟล์สลิป');
  if(!['image/jpeg','image/png','image/webp'].includes(file.type))return toast('รองรับไฟล์ JPG PNG WebP');
  if(file.size>550*1024)return toast('เดโมรับสลิปไม่เกิน 550 KB เพื่อเก็บในเครื่อง');
  const reader=new FileReader();reader.onload=()=>{
    const data=getBookings(),b=data.find(x=>x.id===id);
    if(!b || b.status!=='pending_payment')return toast('รายการนี้ไม่อยู่ในสถานะรอชำระ');
    b.slipName=file.name;b.slipImage=reader.result;b.status='slip_review';
    try{setBookings(data)}catch(e){return toast('รูปใหญ่เกินพื้นที่เบราว์เซอร์ ลองย่อภาพก่อน')}
    $('paymentStep').classList.add('hidden');renderCustomer();toast('แนบสลิปแล้ว • รอผลตรวจสอบ (จำลอง)');
  };reader.readAsDataURL(file);
}
function demoApproveSlip(id){
  if(!confirm('ยืนยันผลสลิปผ่านในเดโม? ไม่มีการตรวจ API หรือยอดเงินจริง'))return;
  const data=getBookings(),b=data.find(x=>x.id===id);
  if(!b||b.status!=='slip_review')return;
  b.paymentVerified=true;b.paymentSource='DEMO_ONLY';b.status=b.postPaymentStatus==='pending_confirm'?'pending_confirm':'confirmed';
  setBookings(data);renderCustomer();renderAdmin();toast('จำลองการตรวจผ่านแล้ว • ออกบัตร QR ได้ (ไม่ได้ส่ง LINE จริง)');
}
function customerConfirm(id){
  const data=getBookings(),b=data.find(x=>x.id===id);
  if(!b||b.status!=='pending_confirm'||!b.paymentVerified)return toast('ยังไม่สามารถคอนเฟิร์มได้');
  b.status='confirmed';setBookings(data);renderCustomer();toast('คอนเฟิร์มแล้ว เปิดบัตร QR ได้ในรายการจอง');
}
function demoRejectSlip(id){
  const data=getBookings(),b=data.find(x=>x.id===id);
  if(!b||b.status!=='slip_review')return;
  b.status='pending_payment';b.paymentVerified=false;b.slipImage='';b.slipName='';
  setBookings(data);renderCustomer();renderAdmin();toast('จำลองผลสลิปไม่ผ่านแล้ว');
}
function viewSlip(id){const b=findBooking(id);if(!b?.slipImage)return toast('ไม่พบรูป');const w=window.open('','_blank');if(!w)return toast('อนุญาตหน้าต่างใหม่เพื่อดูรูป');w.document.write(`<img src="${b.slipImage}" style="max-width:95vw;max-height:95vh;object-fit:contain">`);w.document.close()}
function openTicket(id){
  const b=findBooking(id);if(!b||!b.paymentVerified||!['confirmed','checked_in','completed'].includes(b.status))return toast('ยังไม่สามารถออกบัตรได้');
  const el=$('paymentStep');el.classList.remove('hidden');
  el.innerHTML=`<div class="ticket"><h3>🎫 บัตรยืนยันการจอง (เดโม)</h3><p>${esc(b.name)} · ${esc(b.categoryName)}</p><b>${esc(b.resourceName)}</b><p>📅 ${esc(b.date)} · ${esc(b.startTime)}${b.endTime?' - '+esc(b.endTime):''}</p><div id="ticketQrTarget" class="qr-target"></div><p style="text-align:center"><b>${esc(b.id)}</b></p><div class="notice">QR สำหรับเดโมเท่านั้น ไม่ใช่บัตรสิทธิ์ออนไลน์ที่ตรวจสอบด้วยเซิร์ฟเวอร์ และยังไม่ได้ส่งเข้า LINE</div></div>`;
  qrRender($('ticketQrTarget'),`RESERVEFLOW-DEMO:${b.id}`);
  el.scrollIntoView({behavior:'smooth',block:'nearest'});
}
