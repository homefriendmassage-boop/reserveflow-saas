import { cancelPromotionLogin, signInForPromotion } from './promotion-login.js';
import { SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';
import { mountPromotionForm } from './promotion-form.js';
import { listMerchantShops } from '../data/supabase-store.js';
const client=window.supabase.createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY);
const $=id=>document.getElementById(id);
let shops=[];
const say=t=>{$('feedback').textContent=t};
const contextShop = new URLSearchParams(location.search).get('shop');
const loginShopKey = 'reserveflow.promotion-shop';
function selectShop() {
  const shop = shops.find(item=>item.id===$('shop').value);
  $('shopEditor').classList.toggle('hidden',!shop);
  $('backToShop').href = shop ? './merchant.html?' + new URLSearchParams({shop:shop.slug}) : './merchant.html';
  const url = new URL(location.href);
  if (shop) url.searchParams.set('shop',shop.slug);
  else url.searchParams.delete('shop');
  history.replaceState(history.state,'',url);
  $('shopEditor').replaceChildren();
  say('');
  if (shop) mountPromotionForm($('shopEditor'),client,shop.id);
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
