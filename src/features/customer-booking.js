function ensureCurrentCategory(){
  const list=visibleCategories();
  if(!list.length){currentCategory='';return}
  if(!list.some(c=>c.id===currentCategory)) currentCategory=list[0].id;
}
function setDefaultDate(){const inp=$('bookingDate'); if(inp && !inp.value){inp.value=today(); inp.min=today();}}
function categoryTitle(cat){return `${TEMPLATE_META[cat.template]?.icon||'📌'} ${cat.name}`}
function inputState(){
  const data={
    date:$('bookingDate')?.value||today(),
    start:$('startTime')?.value||'18:00',
    duration:Number($('durationHours')?.value||0),
    guests:Number($('guestsCount')?.value||0),
    tickets:Number($('ticketQty')?.value||0)
  };
  data.end=data.duration?addHours(data.start,data.duration):'';
  return data;
}
function timeToMin(t){ const [h,m]=String(t||'00:00').split(':').map(Number); return h*60+m }
function overlaps(startA,endA,startB,endB){
  if(!endA || !endB) return startA===startB;
  return timeToMin(startA) < timeToMin(endB) && timeToMin(startB) < timeToMin(endA);
}
function addHours(time,hours){
  const [hh,mm]=String(time||'00:00').split(':').map(Number);
  const total=hh*60+mm+Number(hours)*60;
  const newH=((Math.floor(total/60))%24+24)%24;
  const newM=((total%60)+60)%60;
  return `${String(newH).padStart(2,'0')}:${String(newM).padStart(2,'0')}`;
}
function resourceBookingState(resourceId){
  const state=inputState();
  const bookings=getBookings().filter(b=>b.categoryId===currentCategory&&b.resourceId===resourceId&&b.date===state.date&&!['cancelled','completed'].includes(b.status)&&overlaps(state.start,state.end,b.startTime,b.endTime));
  if(!bookings.length) return 'available';
  if(bookings.some(b=>b.status==='pending_payment')) return 'pending';
  return 'booked';
}
function chooseResource(id){selectedResourceId=id;renderCustomer()}
function selectedResource(){return getResources(currentCategory).find(r=>r.id===selectedResourceId)}
function calcAmount(cat,res,state){
  const unitBase=Number(cat.price||0);
  const fee=Number(cat.serviceFee||0);
  let qty=1;
  if(cat.template==='table') qty=Math.max(Number(state.guests||0),1);
  if(cat.template==='staff') qty=Math.max(Number(state.duration||0),1);
  if(cat.template==='vip') qty=Math.max(Number(state.duration||0),1);
  if(cat.template==='seat') qty=Math.max(Number(state.duration||0),1);
  if(cat.template==='ticket') qty=Math.max(Number(state.tickets||0),1);
  const subtotal=unitBase*qty;
  const total=subtotal+fee;
  return {qty,subtotal,total,fee};
}
function validateSelection(cat,res,state){
  if(!res) return 'กรุณาเลือกรายการที่ต้องการจอง';
  if(cat.template==='table' && !state.guests) return 'กรุณาเลือกจำนวนผู้ใช้บริการ';
  if(cat.template==='staff' && !state.duration) return 'กรุณาเลือกจำนวนชั่วโมง';
  if(cat.template==='vip' && (!state.guests || !state.duration)) return 'กรุณาเลือกจำนวนผู้ใช้บริการและจำนวนชั่วโมง';
  if(cat.template==='seat' && !state.duration) return 'กรุณาเลือกจำนวนชั่วโมง';
  if(cat.template==='ticket' && !state.tickets) return 'กรุณาเลือกจำนวนบัตร';
  if(['staff','vip','seat'].includes(cat.template) && !state.end) return 'กรุณากำหนดช่วงเวลา';
  if(['table','vip'].includes(cat.template) && res.capacity && state.guests>res.capacity) return 'จำนวนผู้ใช้บริการเกินความจุ';
  if(resourceBookingState(res.id)!=='available') return 'รายการนี้ไม่ว่างในรอบเวลาที่เลือก';
  return '';
}
function renderDynamicFields(cat,preserve={}){
  const template=cat.template;
  const fields=[];
  fields.push(`<div class="field"><label>วันที่ใช้บริการ</label><input id="bookingDate" type="date" onchange="renderCustomer()"></div>`);
  fields.push(`<div class="field"><label>${['staff','vip','seat'].includes(template)?'เวลาเริ่ม':'รอบเวลา'}</label><select id="startTime" onchange="renderCustomer()">${['10:00','12:00','14:00','16:00','18:00','20:00','22:00'].map(t=>`<option ${t==='18:00'?'selected':''}>${t}</option>`).join('')}</select></div>`);
  if(template==='table') fields.push(`<div class="field"><label>จำนวนผู้มาใช้บริการ</label><select id="guestsCount" onchange="renderCustomer()">${[1,2,4,6,8,10].map(n=>`<option value="${n}" ${n===2?'selected':''}>${n} คน</option>`).join('')}</select></div>`);
  if(template==='staff') fields.push(`<div class="field"><label>จำนวนชั่วโมง</label><select id="durationHours" onchange="renderCustomer()">${[1,2,3,4,5].map(n=>`<option value="${n}" ${n===1?'selected':''}>${n} ชั่วโมง</option>`).join('')}</select></div>`);
  if(template==='vip'){
    fields.push(`<div class="field"><label>จำนวนผู้มาใช้บริการ</label><select id="guestsCount" onchange="renderCustomer()">${[2,4,6,8,10].map(n=>`<option value="${n}" ${n===4?'selected':''}>${n} คน</option>`).join('')}</select></div>`);
    fields.push(`<div class="field"><label>จำนวนชั่วโมง</label><select id="durationHours" onchange="renderCustomer()">${[1,2,3,4,5].map(n=>`<option value="${n}" ${n===2?'selected':''}>${n} ชั่วโมง</option>`).join('')}</select></div>`);
  }
  if(template==='seat'){
    fields.push(`<div class="field"><label>จำนวนชั่วโมง</label><select id="durationHours" onchange="renderCustomer()">${[1,2,3,4,5,6].map(n=>`<option value="${n}" ${n===2?'selected':''}>${n} ชั่วโมง</option>`).join('')}</select></div>`);
    fields.push(`<div class="field"><label>ถึงเวลา</label><input id="endTimeView" disabled></div>`);
  }
  if(template==='staff') fields.push(`<div class="field"><label>ถึงเวลา</label><input id="endTimeView" disabled></div>`);
  if(template==='vip') fields.push(`<div class="field"><label>ถึงเวลา</label><input id="endTimeView" disabled></div>`);
  if(template==='ticket') fields.push(`<div class="field"><label>จำนวนบัตร</label><select id="ticketQty" onchange="renderCustomer()">${[1,2,3,4,5,6,8,10].map(n=>`<option value="${n}" ${n===2?'selected':''}>${n} ใบ</option>`).join('')}</select></div>`);
  $('dynamicFields').innerHTML=fields.join('');
  setDefaultDate();
  if($('bookingDate') && preserve.date) $('bookingDate').value=preserve.date;
  if($('startTime') && preserve.start) $('startTime').value=preserve.start;
  if($('durationHours') && preserve.duration) $('durationHours').value=String(preserve.duration);
  if($('guestsCount') && preserve.guests) $('guestsCount').value=String(preserve.guests);
  if($('ticketQty') && preserve.tickets) $('ticketQty').value=String(preserve.tickets);
  const state=inputState();
  if($('endTimeView')) $('endTimeView').value=state.end||'-';
}
function renderResourceArea(cat){
  const list=getResources(cat.id);
  const template=cat.template;
  const state=inputState();
  const people=state.guests;
  if(['table','seat'].includes(template)){
    const title=template==='table'?'เคาน์เตอร์ / จุดบริการ':'เวที / จุดกิจกรรม';
    const background=getConfig().layoutImages?.[cat.id];
    const bg=background?`background-image:linear-gradient(rgba(255,255,255,.27),rgba(255,255,255,.27)),url('${background}');background-size:cover;background-position:center;`:'';
    const dims=getLayoutSize(cat.id);
    const decor=layoutDecorations(cat.id);
    const html=`<div class="layout-shell"><div class="plan" style="${bg}width:${dims.width}px;height:${dims.height}px"><div class="anchor" style="${decor.length?'display:none':''}">${title}</div>${decor.map(decorHtml).join('')}${list.map(r=>{
      const s=resourceBookingState(r.id);
      const disabled=(s!=='available')||(template==='table' && r.capacity && people>r.capacity);
      const cls=['resource',s,selectedResourceId===r.id?'selected':''].filter(Boolean).join(' ');
      const note=template==='table'?`${r.capacity} ที่นั่ง`:'เลือกได้';
      return `<button class="${cls}" style="left:${r.x}%;top:${r.y}%;width:${r.w||84}px;height:${r.h||72}px" ${disabled?'disabled':''} onclick="chooseResource('${r.id}')"><b>${esc(r.id)}</b><small>${esc(note)}</small></button>`;
    }).join('')}<div class="entrance" style="${decor.length?'display:none':''}">${template==='table'?'ทางเข้า':'ทางออก'}</div></div></div>`;
    $('resourceArea').innerHTML=html;
    return;
  }
  $('resourceArea').innerHTML=`<div class="resource-grid">${list.map(r=>{
    const s=resourceBookingState(r.id);
    const disabled=(s!=='available') || ((template==='vip') && r.capacity && state.guests>r.capacity);
    const cls=['card-btn',s,selectedResourceId===r.id?'selected':''].filter(Boolean).join(' ');
    const avatar=r.photo?`<img src="${esc(r.photo)}" alt="${esc(r.name)}">`:esc(r.icon||'📌');
    const stateLabel=s==='pending'?'<span class="badge pending">จองรอชำระ</span>':(s==='booked'?'<span class="badge booked">จองแล้ว</span>':'');
    const detail=template==='vip'?`${esc(r.desc)} • รองรับ ${r.capacity} คน`:esc(r.desc||'');
    return `<button class="${cls}" ${disabled?'disabled':''} onclick="chooseResource('${r.id}')"><span class="avatar">${avatar}</span><span><strong>${esc(r.name)}</strong><small>${detail}</small><span class="price">${money(cat.price)} ${template==='ticket'?'/ ใบ':(template==='table'?'/ คน':(template==='staff'||template==='vip'||template==='seat'?'/ ชั่วโมง':''))}</span>${stateLabel}</span></button>`;
  }).join('')}</div>`;
}
function renderSummary(cat){
  const res=selectedResource();
  const state=inputState();
  if($('endTimeView')) $('endTimeView').value=state.end||'-';
  const calc=res?calcAmount(cat,res,state):{qty:0,subtotal:0,total:0,fee:Number(cat.serviceFee||0)};
  const paymentText=cat.paymentMode==='deposit'?'มัดจำ':'ชำระเต็ม';
  const detailLabel=cat.template==='table'?'จำนวนผู้ใช้บริการ':cat.template==='staff'?'จำนวนชั่วโมง':cat.template==='vip'?'จำนวนผู้ใช้บริการ / ชั่วโมง':cat.template==='seat'?'จำนวนชั่วโมง':'จำนวนบัตร';
  const detailValue=cat.template==='table'?`${state.guests||'-'} คน`:cat.template==='staff'?`${state.duration||'-'} ชั่วโมง`:cat.template==='vip'?`${state.guests||'-'} คน / ${state.duration||'-'} ชั่วโมง`:cat.template==='seat'?`${state.duration||'-'} ชั่วโมง`:`${state.tickets||'-'} ใบ`;
  $('summaryBox').innerHTML=`
    <div class="row"><span>หมวด</span><b>${esc(categoryTitle(cat))}</b></div>
    <div class="row"><span>รายการที่เลือก</span><b>${res?esc(res.name):'ยังไม่ได้เลือก'}</b></div>
    <div class="row"><span>วันที่ / เวลา</span><b>${esc(state.date)} · ${esc(state.start)}${state.end?` - ${esc(state.end)}`:''}</b></div>
    <div class="row"><span>${detailLabel}</span><b>${detailValue}</b></div>
    <div class="row"><span>รูปแบบชำระ</span><b>${paymentText}</b></div>
    <div class="row"><span>ราคาจอง</span><b>${money(calc.subtotal)}</b></div>
    <div class="row"><span>ค่าบริการ</span><b>${money(calc.fee)}</b></div>
    <div class="row total"><span>${paymentText==='มัดจำ'?'ยอดมัดจำ':'ยอดชำระรวม'}</span><b>${money(calc.total)}</b></div>`;
  $('submitBooking').disabled=!res;
}
function renderTabs(){
  ensureCurrentCategory();
  const list=visibleCategories();
  $('categoryTabs').innerHTML=list.length?list.map(c=>`<button class="${currentCategory===c.id?'active':''}" onclick="switchCategory('${c.id}')">${esc(TEMPLATE_META[c.template]?.icon||'📌')} ${esc(c.name)}</button>`).join(''):'<div class="empty" style="width:100%">ยังไม่มีหมวดที่เปิดให้จอง กรุณาเปิดหมวดจากหลังบ้านแอดมิน</div>';
}
function switchCategory(id){currentCategory=id;selectedResourceId='';$('paymentStep').classList.add('hidden');renderCustomer()}
function renderCustomer(){
  const previousCategory=currentCategory;
  ensureCurrentCategory();
  if(currentCategory!==previousCategory) selectedResourceId='';
  const preserve={
    date:$('bookingDate')?.value||today(),
    start:$('startTime')?.value||'18:00',
    duration:Number($('durationHours')?.value||0),
    guests:Number($('guestsCount')?.value||0),
    tickets:Number($('ticketQty')?.value||0)
  };
  renderTabs();
  if(!currentCategory){$('resourceArea').innerHTML='';$('summaryBox').innerHTML='<div class="empty">ยังไม่มีหมวดให้จอง</div>';return;}
  const cat=getCategory(currentCategory); const meta=TEMPLATE_META[cat.template];
  $('mainTitle').textContent=meta.title;
  $('mainDesc').textContent=meta.desc;
  renderDynamicFields(cat,preserve);
  const res=selectedResource();
  if(res){ const err=validateSelection(cat,res,inputState()); if(err && err.includes('ไม่ว่าง')) selectedResourceId=''; }
  renderResourceArea(cat);
  renderSummary(cat);
  renderMyBookings();
}
function createBooking(){
  const cat=getCategory(currentCategory);
  const res=selectedResource();
  const state=inputState();
  const error=validateSelection(cat,res,state);
  if(error) return toast(error);
  const name=$('customerName').value.trim();
  const phone=$('customerPhone').value.replace(/\s+/g,'').trim();
  if(!name) return toast('กรุณากรอกชื่อผู้จอง');
  if(!/^0\d{8,9}$/.test(phone)) return toast('กรุณากรอกเบอร์โทรศัพท์ไทย 9–10 หลัก');
  const calc=calcAmount(cat,res,state);
  const booking={
    id:'RF'+Date.now().toString(36).toUpperCase(),
    categoryId:cat.id,categoryName:cat.name,template:cat.template,
    resourceId:res.id,resourceName:res.name,
    date:state.date,startTime:state.start,endTime:state.end,duration:state.duration,
    guests:state.guests,tickets:state.tickets,
    name,phone,note:$('customerNote').value.trim(),
    paymentMode:cat.paymentMode,serviceFee:Number(cat.serviceFee||0),basePrice:Number(cat.price||0),amount:calc.total,
    status:calc.total>0?'pending_payment':cat.defaultStatus,postPaymentStatus:cat.defaultStatus,createdAt:new Date().toISOString()
  };
  const bookings=getBookings();
  bookings.unshift(booking); setBookings(bookings);
  $('lookupPhone').value=phone;
  $('customerName').value=''; $('customerPhone').value=''; $('customerNote').value='';
  selectedResourceId='';
  toast(`บันทึกคำขอจองสำเร็จ เลขจอง ${booking.id}`);
  renderCustomer();
  renderPaymentStep(booking.id);
}
function bookingText(b){
  if(b.template==='table') return `👥 ${b.guests} คน`;
  if(b.template==='staff') return `⏱️ ${b.duration} ชั่วโมง`;
  if(b.template==='vip') return `👥 ${b.guests} คน · ⏱️ ${b.duration} ชั่วโมง`;
  if(b.template==='seat') return `⏱️ ${b.duration} ชั่วโมง`;
  return `🎫 ${b.tickets} ใบ`;
}
function renderMyBookings(){
  const phone=$('lookupPhone').value.replace(/\s+/g,'').trim();
  const list=phone?getBookings().filter(b=>b.phone===phone):[];
  $('myBookings').innerHTML=list.length?list.map(b=>bookingCard(b,false)).join(''):'<div class="empty">กรอกเบอร์โทรเพื่อดูรายการจอง</div>';
}
