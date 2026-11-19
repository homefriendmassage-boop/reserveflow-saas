function renderAdmin(){
  renderShopSettings();
  renderCategoryTable();
  renderAdminFilters();
  renderAdminStats();
  renderAdminBookings();
  renderLayoutAdmin();
}
function renderCategoryTable(){
  const cfg=getConfig();
  $('categoryTable').innerHTML=cfg.categories.map(c=>`<tr>
    <td><input value="${esc(c.name)}" onchange="updateCategory('${c.id}','name',this.value)"></td>
    <td>${esc(TEMPLATE_META[c.template]?.title||c.template)}</td>
    <td><select onchange="updateCategory('${c.id}','visible',this.value==='true')"><option value="true" ${c.visible?'selected':''}>แสดง</option><option value="false" ${!c.visible?'selected':''}>ซ่อน</option></select></td>
    <td><input type="number" min="0" value="${Number(c.price||0)}" onchange="updateCategory('${c.id}','price',Number(this.value||0))"></td>
    <td><input type="number" min="0" value="${Number(c.serviceFee||0)}" onchange="updateCategory('${c.id}','serviceFee',Number(this.value||0))"></td>
    <td><select onchange="updateCategory('${c.id}','paymentMode',this.value)"><option value="deposit" ${c.paymentMode==='deposit'?'selected':''}>มัดจำ</option><option value="full" ${c.paymentMode==='full'?'selected':''}>ชำระเต็ม</option></select></td>
    <td><select onchange="updateCategory('${c.id}','defaultStatus',this.value)"><option value="pending_payment" ${c.defaultStatus==='pending_payment'?'selected':''}>จองรอชำระ</option><option value="pending_confirm" ${c.defaultStatus==='pending_confirm'?'selected':''}>รอลูกค้าคอนเฟิร์ม</option><option value="confirmed" ${c.defaultStatus==='confirmed'?'selected':''}>จองแล้ว</option></select></td>
    <td><div class="category-order"><button class="btn small soft" onclick="moveCategory('${c.id}',-1)" ${cfg.categories[0].id===c.id?'disabled':''}>↑ ขึ้น</button><button class="btn small soft" onclick="moveCategory('${c.id}',1)" ${cfg.categories[cfg.categories.length-1].id===c.id?'disabled':''}>↓ ลง</button></div></td>
    <td><div class="inline-actions"><button class="btn small danger" onclick="removeCategory('${c.id}')">ลบ</button></div></td>
  </tr>`).join('');
}
function moveCategory(id,direction){
  const cfg=getConfig();const index=cfg.categories.findIndex(c=>c.id===id);
  const target=index+direction;
  if(index<0||target<0||target>=cfg.categories.length)return;
  [cfg.categories[index],cfg.categories[target]]=[cfg.categories[target],cfg.categories[index]];
  setConfig(cfg);renderAdmin();renderCustomer();toast('ปรับลำดับหมวดที่ลูกค้าเห็นแล้ว');
}
function updateCategory(id,key,value){
  const cfg=getConfig();
  const row=cfg.categories.find(c=>c.id===id); if(!row) return;
  row[key]=value; setConfig(cfg);
  if(key==='visible' || key==='name') renderTabs();
  if(currentMode==='admin') renderAdmin();
  renderCustomer();
  toast('บันทึกการตั้งค่าหมวดแล้ว');
}
function removeCategory(id){
  if(!confirm('ต้องการลบหมวดนี้ออกจากเดโมหรือไม่?')) return;
  const cfg=getConfig();
  cfg.categories=cfg.categories.filter(c=>c.id!==id);
  delete cfg.resources[id];
  if(cfg.layoutDecor)delete cfg.layoutDecor[id];
  if(cfg.layoutSizes)delete cfg.layoutSizes[id];
  if(cfg.layoutImages)delete cfg.layoutImages[id];
  setConfig(cfg);
  let bookings=getBookings().filter(b=>b.categoryId!==id); setBookings(bookings);
  ensureCurrentCategory(); selectedResourceId='';
  renderCustomer(); renderAdmin(); toast('ลบหมวดเรียบร้อย');
}
function addCategory(){
  const name=$('newCatName').value.trim();
  const template=$('newCatTemplate').value;
  const price=Number($('newCatPrice').value||0);
  if(!name) return toast('กรุณากรอกชื่อหมวดใหม่');
  const cfg=getConfig();
  const id='cat_'+Date.now().toString(36);
  cfg.categories.push({id,name,template,visible:true,price,serviceFee:0,paymentMode:'deposit',defaultStatus:'pending_payment'});
  cfg.resources[id]=deep(DEFAULT_CONFIG.resources[template]).map((r,i)=>({ ...r, id:(template[0]||'X').toUpperCase()+String(i+1).padStart(2,'0'), name:r.name.replace(/T\d+|V\d+|A\d+|B\d+|E\d+|S\d+/g,'').trim() || r.name }));
  setConfig(cfg);
  $('newCatName').value=''; $('newCatPrice').value='';
  currentCategory=id; selectedResourceId='';
  renderCustomer(); renderAdmin(); toast('เพิ่มหมวดใหม่แล้ว');
}
function renderAdminFilters(){
  const cats=getConfig().categories;
  $('adminCategoryFilter').innerHTML='<option value="all">ทุกหมวด</option>'+cats.map(c=>`<option value="${c.id}">${esc(c.name)}</option>`).join('');
}
function renderAdminStats(){
  const data=getBookings();
  const stats=[
    ['ทั้งหมด',data.length],
    ['จองรอชำระ',data.filter(x=>x.status==='pending_payment').length],
    ['รอคอนเฟิร์ม',data.filter(x=>x.status==='pending_confirm').length],
    ['จองแล้ว/เช็กอิน',data.filter(x=>['confirmed','checked_in'].includes(x.status)).length]
  ];
  $('statCards').innerHTML=stats.map(s=>`<div class="stat"><strong>${s[1]}</strong><span>${s[0]}</span></div>`).join('');
}
function renderAdminBookings(){
  const cat=$('adminCategoryFilter').value;
  const status=$('adminStatusFilter').value;
  const q=$('adminSearch').value.trim().toLowerCase();
  let data=getBookings().filter(b=>
    (cat==='all'||b.categoryId===cat) &&
    (status==='all'||b.status===status) &&
    (!q || [b.id,b.name,b.phone,b.resourceName,b.categoryName].some(v=>String(v||'').toLowerCase().includes(q)))
  );
  $('adminBookings').innerHTML=data.length?data.map(b=>bookingCard(b,true)).join(''):'<div class="empty">ยังไม่มีรายการจองที่ตรงเงื่อนไข</div>';
}
function changeStatus(id,status){
  const data=getBookings();
  const booking=data.find(b=>b.id===id); if(!booking) return;
  if(!confirm(`ต้องการเปลี่ยนสถานะ ${booking.id} เป็น “${STATUS_LABEL[status]}” ใช่หรือไม่?`)) return;
  if(status==='confirmed' && booking.amount>0 && !booking.paymentVerified && booking.status!=='pending_confirm') return toast('ต้องตรวจสอบการชำระเงินก่อนออกบัตร');
  booking.status=status;
  setBookings(data);
  renderCustomer(); renderAdmin();
  toast('อัปเดตสถานะเรียบร้อย');
}
function resetAll(){
  $('paymentStep').classList.add('hidden');
  if(!confirm('ต้องการรีเซ็ตข้อมูลเดโมทั้งหมด (รายการจอง + การตั้งค่าหมวด) หรือไม่?')) return;
  resetDemoStore();
  currentCategory='table'; selectedResourceId='';
  renderCustomer(); renderAdmin(); toast('รีเซ็ตข้อมูลเดโมทั้งหมดแล้ว');
}

function renderShopSettings(){
  const shop=getConfig().shop||DEFAULT_CONFIG.shop;
  for(const [id,key] of [['shopName','name'],['shopCode','tenantId'],['bankName','bankName'],['bankOwner','bankOwner'],['bankNumber','bankNumber'],['promptpayId','promptpayId'],['saasPlan','plan']]){
    if($(id)) $(id).value=shop[key]||'';
  }
}
function saveShopSettings(){
  const cfg=getConfig();cfg.shop=cfg.shop||deep(DEFAULT_CONFIG.shop);
  for(const [id,key] of [['shopName','name'],['bankName','bankName'],['bankOwner','bankOwner'],['bankNumber','bankNumber'],['promptpayId','promptpayId'],['saasPlan','plan']]){
    cfg.shop[key]=$(id).value.trim();
  }
  setConfig(cfg);toast('บันทึกข้อมูลร้านและบัญชีรับเงินในเดโมแล้ว');
}
