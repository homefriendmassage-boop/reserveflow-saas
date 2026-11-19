let layoutCategoryId='table';
let editItemId='';
let editDecorId='';
let dragInfo=null;
const ASPECTS={wide:{width:960,height:540},portrait:{width:540,height:720},square:{width:700,height:700}};
const DECOR_TYPES={door:'🚪 ประตู',stage:'🎤 เวที',restroom:'🚻 ห้องน้ำ',entrance:'➡️ ทางเข้า',exit:'⬅️ ทางออก',wall:'▰ ผนัง',label:'ข้อความอิสระ'};
function getLayoutSize(id){
  const value=getConfig().layoutSizes?.[id];
  return value&&value.width&&value.height?value:{aspect:'wide',...ASPECTS.wide};
}
function layoutDecorations(id){return getConfig().layoutDecor?.[id]||[]}
function decorHtml(d){return `<div class="decor-block kind-${esc(d.type)}" style="left:${Number(d.x)}%;top:${Number(d.y)}%;width:${Number(d.w)}px;height:${Number(d.h)}px">${esc(d.label)}</div>`}
function changeLayoutAspect(aspect){
  if(!layoutCategoryId)return;
  const cfg=getConfig();cfg.layoutSizes=cfg.layoutSizes||{};
  const old=getLayoutSize(layoutCategoryId);
  cfg.layoutSizes[layoutCategoryId]={aspect,...(ASPECTS[aspect]||{width:old.width,height:old.height})};
  setConfig(cfg);renderLayoutAdmin();renderCustomer();
}
function updateLayoutSize(){
  if(!layoutCategoryId)return;
  const cfg=getConfig();cfg.layoutSizes=cfg.layoutSizes||{};
  const width=Math.max(320,Math.min(1600,Number($('layoutWidth').value)||960));
  const height=Math.max(280,Math.min(1600,Number($('layoutHeight').value)||540));
  cfg.layoutSizes[layoutCategoryId]={aspect:'custom',width,height};
  setConfig(cfg);renderLayoutAdmin();renderCustomer();toast('บันทึกขนาดผังแล้ว');
}
function layoutAddDecor(){
  if(!layoutCategoryId)return;
  const kind=$('newDecorType').value;if(!DECOR_TYPES[kind])return toast('กรุณาเลือกประเภทบล็อก');
  const cfg=getConfig();cfg.layoutDecor=cfg.layoutDecor||{};
  const list=cfg.layoutDecor[layoutCategoryId]||[];
  const id='D'+Date.now().toString(36);
  list.push({id,type:kind,label:DECOR_TYPES[kind],x:50,y:50,w:kind==='wall'?210:130,h:kind==='wall'?26:58});
  cfg.layoutDecor[layoutCategoryId]=list;setConfig(cfg);
  editDecorId=id;editItemId='';renderLayoutAdmin();renderCustomer();toast('เพิ่มบล็อกแล้ว ลากไปวางตำแหน่งได้เลย');
}
function layoutDecorUpdate(key,value){
  const cfg=getConfig();const item=cfg.layoutDecor?.[layoutCategoryId]?.find(x=>x.id===editDecorId);
  if(!item)return;
  if(['w','h'].includes(key)) value=Math.max(20,Math.min(800,Number(value)||20));
  if(['x','y'].includes(key)) value=Math.max(1,Math.min(99,Number(value)||1));
  item[key]=value;setConfig(cfg);renderLayoutAdmin();renderCustomer();
}
function layoutDeleteDecor(){
  if(!editDecorId||!confirm('ลบบล็อกประกอบผังนี้?'))return;
  const cfg=getConfig();cfg.layoutDecor[layoutCategoryId]=layoutDecorations(layoutCategoryId).filter(x=>x.id!==editDecorId);
  editDecorId='';setConfig(cfg);renderLayoutAdmin();renderCustomer();
}
function layoutDecorPointerDown(e){
  if(e.button!==0)return;
  const target=e.currentTarget;editDecorId=target.dataset.decorId;editItemId='';
  const r=layoutDecorations(layoutCategoryId).find(a=>a.id===editDecorId);
  const rect=$('layoutCanvas').getBoundingClientRect();
  dragInfo={type:'decor',id:editDecorId,originX:r.x,originY:r.y,startX:e.clientX,startY:e.clientY,rect,el:target};
  target.setPointerCapture(e.pointerId);
  target.addEventListener('pointermove',layoutPointerMove);
  target.addEventListener('pointerup',layoutPointerEnd,{once:true});
  target.addEventListener('pointercancel',layoutPointerEnd,{once:true});
  e.preventDefault();
}

function layoutCategories(){return getConfig().categories.filter(c=>['table','seat'].includes(c.template))}
function layoutSelectCategory(id){layoutCategoryId=id;editItemId='';editDecorId='';renderLayoutAdmin()}
function layoutResources(){return getResources(layoutCategoryId)}
function layoutWrite(fn){
  const cfg=getConfig();
  if(!cfg.resources[layoutCategoryId]) cfg.resources[layoutCategoryId]=deep(cfg.resources[getCategory(layoutCategoryId).template]||[]);
  fn(cfg.resources[layoutCategoryId]);
  setConfig(cfg);
  renderLayoutAdmin();
  renderCustomer();
}
function renderLayoutAdmin(){
  const categories=layoutCategories();
  if(!categories.some(c=>c.id===layoutCategoryId)) layoutCategoryId=categories[0]?.id||'';
  const select=$('layoutCategory');
  if(!select)return;
  select.innerHTML=categories.map(c=>`<option value="${c.id}" ${c.id===layoutCategoryId?'selected':''}>${esc(c.name)}</option>`).join('');
  if(!layoutCategoryId){$('layoutCanvas').innerHTML='<div class="empty">ยังไม่มีหมวดผัง</div>';return}
  const resources=layoutResources();
  const size=getLayoutSize(layoutCategoryId);
  $('layoutAspect').value=size.aspect||'custom';
  $('layoutWidth').value=size.width;
  $('layoutHeight').value=size.height;
  $('layoutCanvas').style.width=size.width+'px';
  $('layoutCanvas').style.height=size.height+'px';
  const decor=layoutDecorations(layoutCategoryId);
  const bg=getConfig().layoutImages?.[layoutCategoryId];
  $('layoutCanvas').style.backgroundImage=bg?`linear-gradient(rgba(255,255,255,.27),rgba(255,255,255,.27)),url('${bg}')`:'';
  $('layoutCanvas').style.backgroundSize=bg?'cover':'5% 10%';
  $('layoutCanvas').style.backgroundPosition='center';
  $('layoutCanvas').innerHTML=decor.map(d=>`<div class="decor-block editor-decor kind-${esc(d.type)} ${d.id===editDecorId?'active':''}" data-decor-id="${esc(d.id)}" style="left:${Number(d.x)}%;top:${Number(d.y)}%;width:${Number(d.w)}px;height:${Number(d.h)}px">${esc(d.label)}</div>`).join('')+resources.map(r=>`<div class="edit-item ${r.id===editItemId?'active':''}" data-id="${esc(r.id)}" style="left:${Number(r.x||50)}%;top:${Number(r.y||50)}%;width:${Number(r.w||84)}px;height:${Number(r.h||72)}px"><b>${esc(r.id)}</b><small>${esc(r.name)}</small></div>`).join('');
  const current=resources.find(r=>r.id===editItemId);
  if($('copyLayoutButton')) $('copyLayoutButton').disabled=!current;
  const activeDecor=decor.find(d=>d.id===editDecorId);
  $('layoutSettings').innerHTML=activeDecor?`
  <div class="field"><label>ประเภทบล็อก</label><select onchange="layoutDecorUpdate('type',this.value)">${Object.entries(DECOR_TYPES).map(([k,v])=>`<option value="${k}" ${activeDecor.type===k?'selected':''}>${v}</option>`).join('')}</select></div>
  <div class="field"><label>ข้อความบนบล็อก</label><input value="${esc(activeDecor.label)}" onchange="layoutDecorUpdate('label',this.value)"></div>
  <div class="field"><label>กว้าง (px)</label><input type="number" min="20" max="800" value="${activeDecor.w}" onchange="layoutDecorUpdate('w',this.value)"></div>
  <div class="field"><label>สูง (px)</label><input type="number" min="20" max="800" value="${activeDecor.h}" onchange="layoutDecorUpdate('h',this.value)"></div>
  <div class="field"><label>ตำแหน่ง X (%)</label><input type="number" min="1" max="99" value="${activeDecor.x}" onchange="layoutDecorUpdate('x',this.value)"></div>
  <div class="field"><label>ตำแหน่ง Y (%)</label><input type="number" min="1" max="99" value="${activeDecor.y}" onchange="layoutDecorUpdate('y',this.value)"></div>
  <div class="field"><label>จัดการบล็อก</label><button class="btn danger small full" onclick="layoutDeleteDecor()">ลบบล็อกนี้</button></div>
  `:current?`
  <div class="field"><label>รหัส</label><input value="${esc(current.id)}" disabled></div>
  <div class="field"><label>ชื่อ</label><input value="${esc(current.name)}" onchange="layoutUpdate('name',this.value)"></div>
  <div class="field"><label>กว้าง (px)</label><input type="number" min="40" max="240" value="${Number(current.w||84)}" onchange="layoutUpdate('w',Number(this.value))"></div>
  <div class="field"><label>สูง (px)</label><input type="number" min="36" max="160" value="${Number(current.h||72)}" onchange="layoutUpdate('h',Number(this.value))"></div>
  <div class="field"><label>ตำแหน่ง X (%)</label><input type="number" min="5" max="95" value="${Number(current.x||50)}" onchange="layoutUpdate('x',Number(this.value))"></div>
  <div class="field"><label>ตำแหน่ง Y (%)</label><input type="number" min="5" max="95" value="${Number(current.y||50)}" onchange="layoutUpdate('y',Number(this.value))"></div>
  ${getCategory(layoutCategoryId)?.template==='table'?`<div class="field"><label>จำนวนที่นั่ง</label><input type="number" min="1" max="100" value="${Number(current.capacity||2)}" onchange="layoutUpdate('capacity',Number(this.value))"></div>`:''}
  <div class="field"><label>จัดการจุดจอง</label><div class="inline-actions"><button class="btn soft small" onclick="layoutCopy()">📋 คัดลอกจุดนี้</button><button class="btn danger small" onclick="layoutDelete()">ลบจุดนี้</button></div></div>
  `:'<div class="note">คลิกหรือแตะโต๊ะ/ที่นั่งเพื่อแก้ไข แล้วลากย้ายไปยังตำแหน่งใหม่ได้</div>';
  $('layoutCanvas').querySelectorAll('.edit-item').forEach(el=>el.addEventListener('pointerdown',layoutPointerDown));
  $('layoutCanvas').querySelectorAll('.editor-decor').forEach(el=>el.addEventListener('pointerdown',layoutDecorPointerDown));
}
function layoutUpdate(key,value){
  if(['w','h'].includes(key)) value=Math.max(key==='w'?40:36,Math.min(key==='w'?240:160,value||0));
  if(['x','y'].includes(key)) value=Math.max(5,Math.min(95,value||0));
  layoutWrite(arr=>{const r=arr.find(x=>x.id===editItemId);if(r)r[key]=value});
}
function layoutPointerDown(e){
  if(e.button!==0)return;
  const target=e.currentTarget;
  editItemId=target.dataset.id;editDecorId='';
  $('layoutCanvas').querySelectorAll('.edit-item').forEach(el=>el.classList.toggle('active',el===target));
  const r=layoutResources().find(a=>a.id===editItemId);
  const rect=$('layoutCanvas').getBoundingClientRect();
  dragInfo={id:editItemId,originX:r.x||50,originY:r.y||50,startX:e.clientX,startY:e.clientY,rect,el:target};
  target.setPointerCapture(e.pointerId);
  target.addEventListener('pointermove',layoutPointerMove);
  target.addEventListener('pointerup',layoutPointerEnd,{once:true});
  target.addEventListener('pointercancel',layoutPointerEnd,{once:true});
  e.preventDefault();
}
function layoutPointerMove(e){
  if(!dragInfo)return;
  const d=dragInfo;
  const x=Math.max(6,Math.min(94,d.originX+(e.clientX-d.startX)/d.rect.width*100));
  const y=Math.max(8,Math.min(92,d.originY+(e.clientY-d.startY)/d.rect.height*100));
  d.el.style.left=x.toFixed(1)+'%';d.el.style.top=y.toFixed(1)+'%';
}
function layoutPointerEnd(e){
  if(!dragInfo)return;
  const d=dragInfo;dragInfo=null;
  d.el.removeEventListener('pointermove',layoutPointerMove);
  const x=Number.parseFloat(d.el.style.left),y=Number.parseFloat(d.el.style.top);
  if(d.type==='decor'){
    const cfg=getConfig();const item=cfg.layoutDecor?.[layoutCategoryId]?.find(a=>a.id===d.id);
    if(item){item.x=Number(x.toFixed(1));item.y=Number(y.toFixed(1));setConfig(cfg);}
    renderLayoutAdmin();renderCustomer();
  }else{
    layoutWrite(arr=>{const r=arr.find(a=>a.id===d.id);if(r){r.x=Number(x.toFixed(1));r.y=Number(y.toFixed(1));}});
  }
}
function applyLayoutTemplate(){
  if(!layoutCategoryId)return;
  const type=$('layoutTemplate').value;
  layoutWrite(arr=>{
    const n=arr.length;
    arr.forEach((r,i)=>{
      let x=50,y=50;
      if(type==='grid'){
        const cols=Math.ceil(Math.sqrt(n*1.5)),rows=Math.ceil(n/cols),col=i%cols,row=Math.floor(i/cols);
        x=(col+1)*100/(cols+1);y=(row+1)*100/(rows+1);
      } else if(type==='rows'){
        const cols=Math.min(n,4),row=Math.floor(i/cols),c=i%cols,rows=Math.ceil(n/cols);
        x=(c+1)*100/(cols+1);y=(row+1)*100/(rows+1);
      } else if(type==='columns'){
        const rows=Math.min(n,4),col=Math.floor(i/rows),row=i%rows,cols=Math.ceil(n/rows);
        x=(col+1)*100/(cols+1);y=(row+1)*100/(rows+1);
      } else if(type==='u'){
        const t=n===1?0.5:i/(n-1);
        if(t<.33){x=16;y=20+t/.33*60}else if(t<.67){x=16+(t-.33)/.34*68;y=80}else{x=84;y=80-(t-.67)/.33*60}
      } else if(type==='circle'){
        const a=Math.PI+(Math.PI*(n===1?.5:i/(n-1)));
        x=50+34*Math.cos(a);y=57+33*Math.sin(a);
      }
      r.x=Number(x.toFixed(1));r.y=Number(y.toFixed(1));
    });
  });
  toast('จัดผังตาม Template แล้ว');
}
function layoutAdd(){
  if(!layoutCategoryId)return;
  const template=getCategory(layoutCategoryId)?.template;
  const arr=layoutResources();
  const existing=new Set(arr.map(r=>r.id));let idx=1;
  const prefix=template==='table'?'T':'A';
  while(existing.has(prefix+String(idx).padStart(2,'0')))idx++;
  const id=prefix+String(idx).padStart(2,'0');
  layoutWrite(items=>items.push({id,name:(template==='table'?'โต๊ะ ':'ที่นั่ง ')+id,capacity:template==='table'?4:1,x:50,y:50,w:84,h:72}));
  editItemId=id;renderLayoutAdmin();
}
function layoutCopy(){
  if(!layoutCategoryId || !editItemId) return toast('กรุณาเลือกโต๊ะหรือที่นั่งบนผังก่อนคัดลอก');
  const items=layoutResources();
  const source=items.find(r=>r.id===editItemId);
  if(!source) return toast('ไม่พบจุดจองที่เลือก');
  const used=new Set(items.map(r=>r.id));
  const match=String(source.id).match(/^([^0-9]*)([0-9]+)$/);
  const prefix=match?match[1]:(getCategory(layoutCategoryId)?.template==='table'?'T':'A');
  const digits=match?match[2].length:2;
  let next=1;
  while(used.has(prefix+String(next).padStart(digits,'0')))next++;
  const id=prefix+String(next).padStart(digits,'0');
  const copy=deep(source);
  copy.id=id;
  // Keep every visual and capacity setting, but give the clone a fresh identity.
  copy.name=String(source.name||source.id).includes(source.id)
    ?String(source.name).replace(source.id,id)
    :(getCategory(layoutCategoryId)?.template==='table'?'โต๊ะ ':'ที่นั่ง ')+id;
  // Offset clones so the admin can see and drag them independently.
  copy.x=Math.max(6,Math.min(94,Number(source.x||50)+9));
  copy.y=Math.max(8,Math.min(92,Number(source.y||50)+9));
  editItemId=id;
  editDecorId='';
  layoutWrite(arr=>arr.push(copy));
  toast(`คัดลอก ${source.id} เป็น ${id} แล้ว สามารถลากไปวางตำแหน่งใหม่ได้`);
}
function layoutDelete(){
  if(!editItemId || !confirm('ลบจุดจอง '+editItemId+' ออกจากผัง?'))return;
  const id=editItemId;
  if(getBookings().some(b=>b.categoryId===layoutCategoryId&&b.resourceId===id&&!['cancelled','completed'].includes(b.status)))return toast('มีรายการจองที่ยังใช้งานอยู่ ไม่สามารถลบได้');
  editItemId='';layoutWrite(items=>{const i=items.findIndex(r=>r.id===id);if(i>=0)items.splice(i,1)});
}


// Demo storefront settings; production requires tenant-aware authenticated API.
function uploadLayoutBackground(input){
  const file=input.files?.[0];if(!file)return;
  if(!['image/jpeg','image/png','image/webp'].includes(file.type))return toast('รองรับ JPG PNG หรือ WebP เท่านั้น');
  if(file.size>700*1024)return toast('เดโมจำกัดภาพพื้นหลังไม่เกิน 700 KB');
  const reader=new FileReader();reader.onload=()=>{
    const cfg=getConfig();cfg.layoutImages=cfg.layoutImages||{};
    cfg.layoutImages[layoutCategoryId]=reader.result;
    try{setConfig(cfg)}catch(e){return toast('พื้นที่จัดเก็บในเบราว์เซอร์เต็ม กรุณาลดขนาดภาพ')}
    renderLayoutAdmin();renderCustomer();toast('อัปโหลดภาพพื้นหลังผังแล้ว');
  };reader.readAsDataURL(file);
}
function clearLayoutBackground(){
  if(!layoutCategoryId)return;
  const cfg=getConfig();if(cfg.layoutImages)delete cfg.layoutImages[layoutCategoryId];
  setConfig(cfg);renderLayoutAdmin();renderCustomer();toast('ลบภาพพื้นหลังแล้ว');
}
