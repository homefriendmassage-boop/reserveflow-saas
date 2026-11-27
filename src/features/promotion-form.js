let formSequence = 0;

const formMarkup = `
<form id="offerForm" class="promotion-offer-form">
            <h2 id="offerTitle">สร้างโปรโมชั่น</h2>
            <input type="hidden" id="offerId">
            <label class="field"><span>ชื่อโปรโมชั่น</span><input id="name" required maxlength="120" placeholder="เช่น ตกกุ้ง 3 ชั่วโมง ฟรีเครื่องดื่ม"></label>
            <div class="promotion-pair">
              <label class="field"><span>จำนวนชั่วโมง</span><select id="hours"><option value="1">1 ชั่วโมง</option><option value="2">2 ชั่วโมง</option><option value="3" selected>3 ชั่วโมง</option><option value="4">4 ชั่วโมง</option><option value="5">5 ชั่วโมง</option></select></label>
              <label class="field"><span>ประเภทโปรโมชั่น</span><select id="mode"><option value="gift">แจกของแถม</option><option value="discount">ลดราคา</option></select></label>
            </div>
            <label class="field"><span>ราคาแพ็กเกจ (บาท)</span><input id="price" type="number" min="0" step=".01" required></label>
            <div id="giftFields" class="promotion-gift-fields">
              <label class="field"><span>ของแถม</span><input id="gift" placeholder="เช่น เครื่องดื่ม 1 แก้ว"></label>
              <label class="field"><span>มูลค่าของแถม (บาท)</span><input id="giftValue" type="number" min="0" step=".01" value="0"></label>
            </div>
            <label class="merchant-switch"><input type="checkbox" id="active" checked> เปิดแสดงโปรโมชั่นให้ลูกค้า</label>
            <details class="merchant-settings-panel">
              <summary>วันใช้งานและจำนวนสิทธิ์</summary>
              <div class="promotion-pair">
                <label class="field"><span>เปิดขายตั้งแต่ (เวลาไทย)</span><input id="startsAt" type="datetime-local"></label>
                <label class="field"><span>ปิดขายเมื่อ (เวลาไทย)</span><input id="endsAt" type="datetime-local"></label>
              </div>
              <label class="field"><span>จำนวนสิทธิ์ (เว้นว่างเพื่อไม่จำกัด)</span><input id="usageLimit" type="number" min="1" max="1000000"></label>
            </details>
            <section class="promotion-preview" aria-labelledby="previewLabel">
              <p id="previewLabel" class="sub">ตัวอย่างที่ลูกค้าจะเห็น</p>
              <h3 id="previewName"></h3>
              <p id="previewPrice" class="promotion-preview-price"></p>
              <p id="previewGift" class="promotion-preview-gift"></p>
              <p id="previewStatus" class="sub"></p>
            </section>
            <div class="inline-actions">
              <button class="btn primary" type="submit">บันทึกโปรโมชั่น</button>
              <button class="btn soft" id="clear" type="button">สร้างรายการใหม่</button>
            </div>
          </form>
          <p id="formFeedback" role="status"></p>
          <h2>โปรโมชั่นของร้าน</h2>
          <div class="inline-actions">
            <button id="loadDiscount" class="btn soft" type="button">ชุดโปรลดราคา 1–5 ชม.</button>
            <button id="loadGift" class="btn soft" type="button">ชุดโปรแถมเครื่องดื่ม/อาหาร</button>
          </div>
          <div id="offers"></div>
`;

const toThaiInput = value => value ? new Date(Date.parse(value)+7*3600000).toISOString().slice(0,16) : '';
const fromThaiInput = value => value ? value+'+07:00' : null;
const thb=n=>Number(n||0).toLocaleString('th-TH',{style:'currency',currency:'THB'});
const presets={
 discount:[[1,120,'ตกกุ้ง 1 ชั่วโมง'],[2,220,'ตกกุ้ง 2 ชั่วโมง'],[3,300,'ตกกุ้ง 3 ชั่วโมง'],[4,380,'ตกกุ้ง 4 ชั่วโมง'],[5,450,'ตกกุ้ง 5 ชั่วโมง']],
 gift:[[2,240,'ตกกุ้ง 2 ชั่วโมง ฟรีน้ำดื่ม','น้ำดื่ม 1 ขวด',10],
 [3,360,'ตกกุ้ง 3 ชั่วโมง ฟรีเครื่องดื่ม','เครื่องดื่ม 1 แก้ว มูลค่าไม่เกิน 40 บาท',40],
 [4,480,'ตกกุ้ง 4 ชั่วโมง ฟรีของทานเล่น','ของทานเล่น 1 จาน มูลค่าไม่เกิน 59 บาท',59],
 [5,600,'ตกกุ้ง 5 ชั่วโมง ฟรีอาหาร','อาหาร 1 จาน มูลค่าไม่เกิน 89 บาท',89]]
};
export function mountPromotionForm(root, client, shopId, {platform=false}={}) {
  root.innerHTML=formMarkup;
  const prefix='promotion-form-'+(++formSequence)+'-';
  const controls=new Map();
  for (const part of root.querySelectorAll('[id]')) {
    controls.set(part.id,part);
    part.id=prefix+part.id;
  }
  for (const part of root.querySelectorAll('[aria-labelledby]')) {
    part.setAttribute('aria-labelledby',prefix+part.getAttribute('aria-labelledby'));
  }
  const $=id=>controls.get(id);
  let offers=[];
  const say=value=>{ $('formFeedback').textContent=value; };
  function updatePreview() {
    const gift = $('mode').value === 'gift';
    $('giftFields').classList.toggle('hidden',!gift);
    $('gift').required = gift;
    $('previewName').textContent = $('name').value.trim() || 'ชื่อโปรโมชั่น';
    $('previewPrice').textContent = $('price').value === '' ? '—' : thb($('price').value) + ' / ' + $('hours').value + ' ชั่วโมง';
    $('previewGift').textContent = gift && $('gift').value.trim() ? 'ฟรี ' + $('gift').value.trim() : '';
    $('previewStatus').textContent = $('active').checked ? 'เปิดแสดงเมื่อตรงตามเงื่อนไขของโปร' : 'ปิดการแสดงโปรโมชั่น';
  }
  function resetForm() {
    $('offerForm').reset();
    $('offerId').value = '';
    $('offerTitle').textContent = 'สร้างโปรโมชั่น';
    updatePreview();
  }
  $('offerForm').addEventListener('input',updatePreview);
  $('offerForm').addEventListener('change',updatePreview);

  async function load(){
    const {data,error}=await (platform
      ? client.rpc('rf_platform_promotion_offers',{p_shop_id:shopId})
      : client.from('rf_promotion_offers').select('id,name,hours,mode,price,gift_name,gift_value,active,starts_at,ends_at,usage_limit')
        .eq('shop_id',shopId).order('hours').order('mode'));
    if (!root.isConnected) return;
    if(error){say(platform && error.code==='PGRST202' ? 'รัน SQL โปรโมชั่น 05 เพื่อเปิดฟอร์มสำหรับ Superadmin' : 'โหลดโปรโมชั่นไม่สำเร็จ');return}
    offers=data||[];
    const list=$('offers');list.replaceChildren();
    if(!offers.length){const p=document.createElement('p');p.className='sub';p.textContent='ยังไม่มีแพ็กเกจโปรโมชั่นของร้านนี้';list.append(p)}
    for(const o of offers){
      const article=document.createElement('article');article.className='booking';
      const heading=document.createElement('h3');heading.textContent=o.name;article.append(heading);
      const summary=document.createElement('p');summary.textContent=`${o.hours} ชั่วโมง · ${thb(o.price)} · ${o.mode==='gift'?'ของแถม '+(o.gift_name||''):'ส่วนลด'} · ${o.active?'เปิดใช้งาน':'ปิดใช้งาน'}`;article.append(summary);
      const edit=document.createElement('button');edit.className='btn soft small';edit.textContent='แก้ไข';edit.onclick=()=>{
        $('offerId').value=o.id;$('name').value=o.name;$('hours').value=o.hours;
        $('mode').value=o.mode;$('price').value=o.price;$('gift').value=o.gift_name||'';
        $('giftValue').value=o.gift_value;$('active').checked=o.active;
        $('startsAt').value=toThaiInput(o.starts_at);$('endsAt').value=toThaiInput(o.ends_at);$('usageLimit').value=o.usage_limit ?? '';
        $('offerTitle').textContent = 'แก้ไขโปรโมชั่น';
        updatePreview();
        $('offerForm').scrollIntoView({behavior:'smooth'});
      };article.append(edit);list.append(article)
    }
  }
  async function save(input){
    const {error}=await client.rpc('rf_save_promotion_offer',{
      p_shop_id:shopId,p_id:input.id||null,p_name:input.name,p_hours:input.hours,
      p_mode:input.mode,p_price:input.price,p_gift_name:input.gift||null,
      p_gift_value:input.giftValue||0,p_active:input.active,p_starts_at:input.startsAt||null,
      p_ends_at:input.endsAt||null,p_usage_limit:input.usageLimit||null
    });
    if(error)throw error;
  }
  $('offerForm').onsubmit=async e=>{
    e.preventDefault();
    if (e.submitter.disabled) return;
    e.submitter.disabled=true;
    try{
      const obj={id:$('offerId').value,name:$('name').value.trim(),hours:Number($('hours').value),
        mode:$('mode').value,price:Number($('price').value),gift:$('mode').value==='gift' ? $('gift').value.trim() : '',
        giftValue:$('mode').value==='gift' ? Number($('giftValue').value) : 0,active:$('active').checked,
        startsAt:fromThaiInput($('startsAt').value),endsAt:fromThaiInput($('endsAt').value),
        usageLimit:$('usageLimit').value ? Number($('usageLimit').value) : null};
      await save(obj);
      if (root.isConnected) { resetForm();say('บันทึกสำเร็จ');await load(); }
    }catch(error){if (root.isConnected) say('บันทึกไม่สำเร็จ: '+error.message)}
    finally { e.submitter.disabled=false; }
  };
  $('clear').onclick=resetForm;
  async function applyPreset(type){
    if(!confirm('เพิ่มชุดแพ็กเกจตัวอย่างในร้านนี้ (ไม่ลบรายการเก่า) ใช่ไหม?'))return;
    const startingOffers=offers;
    say('กำลังบันทึกชุดโปรโมชั่น…');
    try{
      for(const [hours,price,name,gift='',giftValue=0] of presets[type]){
        const existing=startingOffers.find(o=>o.hours===hours&&o.mode===type);
        await save({id:existing?.id||null,name,hours,mode:type,price,gift,giftValue,active:true,startsAt:existing?.starts_at,endsAt:existing?.ends_at,usageLimit:existing?.usage_limit});
      }
      if (root.isConnected) {
        say('บันทึกชุดโปรโมชั่นเรียบร้อย · ลูกค้าเลือกได้หนึ่งโปรต่อรายการ');
        await load();
      }
    }catch(error){if (root.isConnected) say('บันทึกไม่สำเร็จ: '+error.message)}
  }
  $('loadDiscount').onclick=()=>applyPreset('discount');
  $('loadGift').onclick=()=>applyPreset('gift');
  resetForm();
  void load();
}

export function mountInlinePromotion(categoryContainer,client,shopId,options) {
  const section=document.createElement('details');
  section.className='merchant-settings-panel inline-promotion';
  const heading=document.createElement('summary');
  heading.textContent='สร้างโปรโมชั่นแบบแพ็กเกจ';
  const content=document.createElement('div');
  section.append(heading,content);
  const categoryPanel=categoryContainer.querySelector('[data-section="categories"]');
  if (categoryPanel) categoryPanel.insertBefore(section,categoryPanel.children[2] || null);
  else categoryContainer.prepend(section);
  section.addEventListener('toggle',()=>{
    if (section.open && !content.childElementCount) mountPromotionForm(content,client,shopId,options);
  });
}
