import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
const client=window.supabase.createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY);
const $=id=>document.getElementById(id);
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
let currentToken='',stream=null,reading=false,redeeming=false;
const message=t=>{$('feedback').textContent=t};
function tokenFrom(input){
  try {
    const url=new URL(input);
    return url.searchParams.get('code')||url.searchParams.get('token')||url.hash.slice(1);
  }catch{return input.trim()}
}
function show(data){
  const dl=$('details');dl.replaceChildren();
  for(const [k,v] of [['โปรโมชั่น',data.offer],['ของแถม',data.gift||'—'],['ชั่วโมง',String(data.hours||'')],['สถานะ',data.status],['วันหมดอายุ',new Date(data.expires_at).toLocaleString('th-TH')]]){
    const p=document.createElement('p');p.textContent=k+': '+v;dl.append(p);
  }
  dl.classList.remove('hidden');
  $('confirm').classList.toggle('hidden',!data.valid);
  if(!data.valid)message(data.status==='redeemed'?'คูปองนี้รับสิทธิ์ไปแล้ว ไม่สามารถใช้ซ้ำได้':'คูปองหมดอายุหรือไม่สามารถใช้ได้');
  else message('ตรวจสอบผ่าน กรุณาตรวจรายละเอียดกับลูกค้าก่อนกดยืนยันรับสิทธิ์');
}
async function preview(){
  $('confirm').classList.add('hidden');$('details').classList.add('hidden');
  const token=tokenFrom($('voucherInput').value);
  if(!UUID.test(token)){message('รหัส QR ไม่ถูกต้อง');return}
  currentToken=token;message('กำลังตรวจสอบกับเซิร์ฟเวอร์…');
  const {data,error}=await client.rpc('rf_preview_promotion_voucher',{p_token:token});
  if(error){message('ตรวจสิทธิ์ไม่สำเร็จ: '+error.message);return}
  show(data);
}
$('preview').onclick=preview;
$('confirm').onclick=async()=>{
  if(redeeming||!currentToken||!confirm('ยืนยันว่าลูกค้าได้รับของแถม/ใช้สิทธิ์จริงแล้ว? การกระทำนี้ย้อนกลับไม่ได้'))return;
  redeeming=true;$('confirm').disabled=true;message('กำลังบันทึกการรับสิทธิ์…');
  try{
    const {data,error}=await client.rpc('rf_redeem_promotion_voucher',{p_token:currentToken});
    if(error)throw error;
    if(data?.ok){message('บันทึกใช้สิทธิ์เรียบร้อยแล้ว · ระบบจะส่ง LINE แจ้งยืนยันเมื่อบริการแจ้งเตือนทำงาน');await preview()}
    else{message(data?.reason==='ALREADY_REDEEMED'?'คูปองถูกใช้ไปแล้ว':data?.reason==='EXPIRED'?'คูปองหมดอายุ':'ไม่สามารถใช้สิทธิ์ได้');await preview()}
  }catch(e){message('ยืนยันไม่สำเร็จ: '+e.message)}
  finally{redeeming=false;$('confirm').disabled=false}
};
$('loginForm').onsubmit=async e=>{e.preventDefault();const f=new FormData(e.currentTarget);
  const {error}=await client.auth.signInWithPassword({email:f.get('email'),password:f.get('password')});
  if(error)$('authStatus').textContent=error.message;else await checkAuth();
};
$('lineLogin').onclick=async()=>{
  const {error}=await client.auth.signInWithOAuth({provider:'custom:line-manual',options:{redirectTo:location.href}});
  if(error)$('authStatus').textContent=error.message;
};
async function checkAuth(){
  const {data}=await client.auth.getUser();const ready=!!data.user;
  $('loginForm').classList.toggle('hidden',ready);$('lineLogin').classList.toggle('hidden',ready);
  $('scanner').classList.toggle('hidden',!ready);
  $('authStatus').textContent=ready?'เข้าสู่ระบบแล้ว · ตรวจสอบสิทธิ์พนักงานอีกครั้งเมื่อสแกน':'กรุณาเข้าสู่ระบบด้วยบัญชีพนักงานของร้าน';
  if(ready){const initial=new URLSearchParams(location.search).get('code');if(initial&&UUID.test(initial)){$('voucherInput').value=initial;await preview()}}
}
async function closeCamera(){reading=false;if(stream){stream.getTracks().forEach(t=>t.stop());stream=null}$('video').style.display='none'}
$('stop').onclick=closeCamera;
$('camera').onclick=async()=>{
  if(!('BarcodeDetector'in window)){message('เบราว์เซอร์นี้ไม่รองรับการสแกน QR ผ่านกล้อง กรุณาใช้เครื่องสแกน QR ปกติแล้ววางลิงก์ในช่อง');return}
  try{
    await closeCamera();
    stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:'environment'}});
    const video=$('video');video.srcObject=stream;video.style.display='block';await video.play();
    const detector=new BarcodeDetector({formats:['qr_code']});reading=true;message('นำ QR ให้อยู่ในกรอบกล้อง');
    while(reading){
      const found=await detector.detect(video).catch(()=>[]);
      if(found.length){const token=tokenFrom(found[0].rawValue);if(UUID.test(token)){$('voucherInput').value=token;await closeCamera();await preview();break}}
      await new Promise(resolve=>setTimeout(resolve,220));
    }
  }catch(e){await closeCamera();message('เปิดกล้องไม่ได้: '+e.message)}
};
window.addEventListener('pagehide',closeCamera);
await checkAuth();
