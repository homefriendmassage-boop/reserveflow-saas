import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '../data/supabase-config.js';

const share = document.getElementById('shareFlex');
const shareLink = document.getElementById('shareLink');
const status = document.getElementById('shareStatus');
const signup = new URL('./merchant.html', location.href);
signup.searchParams.set('signup','1');

function setReferral() {
  const params = new URLSearchParams(location.search);
  const state = new URLSearchParams((params.get('liff.state') || '').split('?')[1] || '');
  const ref = params.get('ref') || state.get('ref');
  if (/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(ref || '')) {
    signup.searchParams.set('ref',ref);
  }
  shareLink.href = 'https://line.me/R/share?text=' + encodeURIComponent('สมัครร้านค้าบน ReserveFlow\n' + signup.href);
}

setReferral();
async function initialize() {
  try {
    const client = window.supabase.createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY,{
      auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}
    });
    const {data:liffId,error} = await client.rpc('platform_referral_share_liff');
    if (error || !liffId) throw new Error('LIFF unavailable');
    await window.liff.init({liffId});
    setReferral();
    if (!window.liff.isApiAvailable('shareTargetPicker')) {
      status.textContent = 'เปิดหน้านี้ในแอป LINE เพื่อแชร์เป็น Flex หรือกดแชร์ลิงก์ได้เลย';
      return;
    }
    share.classList.remove('hidden');
    status.textContent = 'กดปุ่มเพื่อเลือกรายชื่อเพื่อนหรือกลุ่มใน LINE';
    share.onclick = async () => {
      share.disabled = true;
      try {
        const result = await window.liff.shareTargetPicker([{
          type:'flex',altText:'สมัครร้านค้าบน ReserveFlow',
          contents:{
            type:'bubble',
            body:{type:'box',layout:'vertical',spacing:'md',contents:[
              {type:'text',text:'ReserveFlow',weight:'bold',size:'xl',color:'#303C80'},
              {type:'text',text:'สมัครใช้งานระบบจองสำหรับร้านค้า',wrap:true},
              {type:'text',text:'ทดลองใช้ฟรี 7 วัน',wrap:true}
            ]},
            footer:{type:'box',layout:'vertical',contents:[
              {type:'button',style:'primary',color:'#404FBA',action:{type:'uri',label:'เปิดใบสมัคร',uri:signup.href}}
            ]}
          }
        }]);
        status.textContent = result?.status === 'success' ? 'ส่ง Flex แล้ว' : 'ยังไม่ได้ส่ง';
      } catch {
        status.textContent = 'เปิดตัวเลือกรายชื่อไม่ได้ ลองอีกครั้งหรือแชร์ลิงก์';
      } finally {
        share.disabled = false;
      }
    };
  } catch {
    status.textContent = 'แชร์เป็น Flex ยังไม่พร้อม สามารถแชร์ลิงก์ใบสมัครได้';
  }
}
void initialize();
