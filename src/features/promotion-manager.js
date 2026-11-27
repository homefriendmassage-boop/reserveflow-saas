import { cancelPromotionLogin, signInForPromotion } from './promotion-login.js';
import { SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
import { listMerchantShops } from '../data/supabase-store.js';
const client=window.supabase.createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY);
const $=id=>document.getElementById(id);
let offers=[],shops=[];
const say=t=>{$('feedback').textContent=t};
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
const contextShop = new URLSearchParams(location.search).get('shop');
const loginShopKey = 'reserveflow.promotion-shop';
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
  const shopId=$('shop').value;
  if (!shopId) return;
  const {data,error}=await client.from('rf_promotion_offers').select('id,name,hours,mode,price,gift_name,gift_value,active,starts_at,ends_at,usage_limit').eq('shop_id',shopId).order('hours').order('mode');
  if ($('shop').value !== shopId) return;
  if(error){say(error.message);return}
  offers=data||[];
  const root=$('offers');root.replaceChildren();
  if(!offers.length){const p=document.createElement('p');p.className='sub';p.textContent='ยังไม่มีแพ็กเกจโปรโมชั่นของร้านนี้';root.append(p)}
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
    };article.append(edit);root.append(article)
  }
}
async function save(input,shopId=$('shop').value){
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
  const shopId=$('shop').value;
  if (!shopId || e.submitter.disabled) return;
  e.submitter.disabled=true;
  try{
    const obj={id:$('offerId').value,name:$('name').value.trim(),hours:Number($('hours').value),
      mode:$('mode').value,price:Number($('price').value),gift:$('mode').value==='gift' ? $('gift').value.trim() : '',
      giftValue:$('mode').value==='gift' ? Number($('giftValue').value) : 0,active:$('active').checked,
      startsAt:fromThaiInput($('startsAt').value),endsAt:fromThaiInput($('endsAt').value),
      usageLimit:$('usageLimit').value ? Number($('usageLimit').value) : null};
    await save(obj,shopId);
    if ($('shop').value===shopId) { resetForm();say('บันทึกสำเร็จ');await load(); }
  }catch(error){if ($('shop').value===shopId) say('บันทึกไม่สำเร็จ: '+error.message)}
  finally { e.submitter.disabled=false; }
};
$('clear').onclick=resetForm;
async function applyPreset(type){
  if(!confirm('เพิ่มชุดแพ็กเกจตัวอย่างในร้านนี้ (ไม่ลบรายการเก่า) ใช่ไหม?'))return;
  const shopId=$('shop').value;
  const startingOffers=offers;
  say('กำลังบันทึกชุดโปรโมชั่น…');
  try{
    for(const [hours,price,name,gift='',giftValue=0] of presets[type]){
      const existing=startingOffers.find(o=>o.hours===hours&&o.mode===type);
      await save({id:existing?.id||null,name,hours,mode:type,price,gift,giftValue,active:true,startsAt:existing?.starts_at,endsAt:existing?.ends_at,usageLimit:existing?.usage_limit},shopId);
    }
    if ($('shop').value===shopId) {
      say('บันทึกชุดโปรโมชั่นเรียบร้อย · ลูกค้าเลือกได้หนึ่งโปรต่อรายการ');
      await load();
    }
  }catch(error){if ($('shop').value===shopId) say('บันทึกไม่สำเร็จ: '+error.message)}
}
$('loadDiscount').onclick=()=>applyPreset('discount');
$('loadGift').onclick=()=>applyPreset('gift');
function selectShop() {
  const shop = shops.find(item=>item.id===$('shop').value);
  $('shopEditor').classList.toggle('hidden',!shop);
  $('backToShop').href = shop ? './merchant.html?' + new URLSearchParams({shop:shop.slug}) : './merchant.html';
  const url = new URL(location.href);
  if (shop) url.searchParams.set('shop',shop.slug);
  else url.searchParams.delete('shop');
  history.replaceState(history.state,'',url);
  resetForm();
  offers = [];
  $('offers').replaceChildren();
  say('');
  if (shop) void load();
}
$('shop').onchange = selectShop;
$('loginLine').onclick = async () => {
  if (contextShop) sessionStorage.setItem(loginShopKey,contextShop);
  try {
    const {error}=await signInForPromotion(client,'promotion-manager.html');
    if (error) throw error;
  } catch {
    cancelPromotionLogin();
    $('authStatus').textContent='เข้าสู่ระบบ LINE ไม่สำเร็จ กรุณาลองใหม่';
  }
};

async function init() {
  const {data}=await client.auth.getUser();
  const logged=!!data.user;
  $('loginLine').classList.toggle('hidden',logged);
  $('editor').classList.toggle('hidden',!logged);
  if (!logged) {
    $('authStatus').textContent='ใช้ LINE บัญชีเจ้าของร้านหรือแอดมินที่ได้รับสิทธิ์';
    return;
  }
  try {
    shops=(await listMerchantShops(client)).filter(s=>['owner','admin'].includes(s.role));
    const requested=contextShop || sessionStorage.getItem(loginShopKey);
    sessionStorage.removeItem(loginShopKey);
    const selected=requested ? shops.find(s=>s.slug===requested) : shops.length===1 ? shops[0] : null;
    $('shop').replaceChildren(new Option('เลือกร้านค้า',''),...shops.map(s=>new Option(s.name,s.id)));
    $('shop').value=selected?.id || '';
    $('authStatus').textContent='';
    selectShop();
    if (!shops.length) say('บัญชี LINE นี้ยังไม่มีสิทธิ์จัดการโปรโมชั่นของร้าน');
    else if (requested && !selected) say('บัญชี LINE นี้ไม่มีสิทธิ์เข้าร้านตามลิงก์');
  } catch {
    say('โหลดร้านค้าไม่สำเร็จ กรุณาเปิดหน้านี้ใหม่');
  }
}
await init();
