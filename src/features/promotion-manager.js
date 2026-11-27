import { SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
import { listMerchantShops } from '../data/supabase-store.js';
const client=window.supabase.createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY);
const $=id=>document.getElementById(id);
let offers=[],shops=[];
const say=t=>{$('feedback').textContent=t};
const thb=n=>Number(n||0).toLocaleString('th-TH',{style:'currency',currency:'THB'});
const presets={
 discount:[[1,120,'ตกกุ้ง 1 ชั่วโมง'],[2,220,'ตกกุ้ง 2 ชั่วโมง'],[3,300,'ตกกุ้ง 3 ชั่วโมง'],[4,380,'ตกกุ้ง 4 ชั่วโมง'],[5,450,'ตกกุ้ง 5 ชั่วโมง']],
 gift:[[1,120,'ตกกุ้ง 1 ชั่วโมง','',0],[2,240,'ตกกุ้ง 2 ชั่วโมง ฟรีน้ำดื่ม','น้ำดื่ม 1 ขวด',10],
 [3,360,'ตกกุ้ง 3 ชั่วโมง ฟรีเครื่องดื่ม','เครื่องดื่ม 1 แก้ว มูลค่าไม่เกิน 40 บาท',40],
 [4,480,'ตกกุ้ง 4 ชั่วโมง ฟรีของทานเล่น','ของทานเล่น 1 จาน มูลค่าไม่เกิน 59 บาท',59],
 [5,600,'ตกกุ้ง 5 ชั่วโมง ฟรีอาหาร','อาหาร 1 จาน มูลค่าไม่เกิน 89 บาท',89]]
};
function resetForm(){for(const key of ['offerId','name','gift'])$(key).value='';$('hours').value='3';$('mode').value='gift';$('price').value='360';$('giftValue').value='0';$('active').value='true'}
async function load(){
  const shopId=$('shop').value;
  const {data,error}=await client.from('rf_promotion_offers').select('id,name,hours,mode,price,gift_name,gift_value,active').eq('shop_id',shopId).order('hours').order('mode');
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
      $('giftValue').value=o.gift_value;$('active').value=String(o.active);
      $('offerForm').scrollIntoView({behavior:'smooth'});
    };article.append(edit);root.append(article)
  }
}
async function save(input){
  const {error}=await client.rpc('rf_save_promotion_offer',{
    p_shop_id:$('shop').value,p_id:input.id||null,p_name:input.name,p_hours:input.hours,
    p_mode:input.mode,p_price:input.price,p_gift_name:input.gift||null,
    p_gift_value:input.giftValue||0,p_active:input.active
  });
  if(error)throw error;
}
$('offerForm').onsubmit=async e=>{
  e.preventDefault();try{
    const obj={id:$('offerId').value,name:$('name').value.trim(),hours:Number($('hours').value),
      mode:$('mode').value,price:Number($('price').value),gift:$('gift').value.trim(),
      giftValue:Number($('giftValue').value),active:$('active').value==='true'};
    await save(obj);resetForm();say('บันทึกสำเร็จ');await load();
  }catch(e){say('บันทึกไม่สำเร็จ: '+e.message)}
};
$('clear').onclick=resetForm;
async function applyPreset(type){
  if(!confirm('เพิ่มชุดแพ็กเกจตัวอย่างในร้านนี้ (ไม่ลบรายการเก่า) ใช่ไหม?'))return;
  say('กำลังบันทึกชุดโปรโมชั่น…');
  try{
    for(const [hours,price,name,gift='',giftValue=0] of presets[type]){
      const existing=offers.find(o=>o.hours===hours&&o.mode===type);
      await save({id:existing?.id||null,name,hours,mode:type,price,gift,giftValue,active:true});
    }
    say('บันทึกชุดโปรโมชั่นเรียบร้อย · โปรสองแบบอาจแสดงพร้อมกัน จึงต้องกำหนดกติกาเลือกแพ็กเกจที่หน้าลูกค้าก่อนใช้งานจริง');
    await load();
  }catch(e){say('บันทึกไม่สำเร็จ: '+e.message)}
}
$('loadDiscount').onclick=()=>applyPreset('discount');
$('loadGift').onclick=()=>applyPreset('gift');
$('shop').onchange=()=>{resetForm();load()};
$('login').onsubmit=async e=>{
  e.preventDefault();const f=new FormData(e.currentTarget);
  const {error}=await client.auth.signInWithPassword({email:f.get('email'),password:f.get('password')});
  if(error)$('authStatus').textContent=error.message;else await init();
};
$('loginLine').onclick=async()=>{
  const {error}=await client.auth.signInWithOAuth({provider:'custom:line-manual',options:{redirectTo:location.href}});
  if(error)$('authStatus').textContent=error.message;
};
async function init(){
  const {data}=await client.auth.getUser();const logged=!!data.user;
  $('login').classList.toggle('hidden',logged);$('loginLine').classList.toggle('hidden',logged);
  $('editor').classList.toggle('hidden',!logged);
  if(!logged){$('authStatus').textContent='กรุณาล็อกอินด้วยบัญชีร้านค้า';return}
  try{
    shops=(await listMerchantShops(client)).filter(s=>['owner','admin'].includes(s.role));
    $('shop').replaceChildren(...shops.map(s=>new Option(s.name,s.id)));
    if(!shops.length){say('บัญชีนี้ไม่มีสิทธิ์ owner/admin สำหรับจัดโปรโมชั่น');return}
    $('authStatus').textContent='เข้าสู่ระบบแล้ว';await load();
  }catch(e){say('โหลดร้านค้าไม่สำเร็จ: '+e.message)}
}
await init();
