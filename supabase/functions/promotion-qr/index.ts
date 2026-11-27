import QRCode from 'npm:qrcode@1.5.4';
import { createClient } from 'npm:@supabase/supabase-js@2.98.0';
const site=Deno.env.get('PROMOTION_SITE_URL') ?? 'https://homefriendmassage-boop.github.io/reserveflow-saas/';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
const publicDb=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_ANON_KEY')!,{auth:{persistSession:false}});
const cacheHeaders={'Cache-Control':'no-store, max-age=0','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'};
let windowStart=Date.now(), requests=0;
const perToken=new Map<string,number>();
Deno.serve(async(req)=>{
  if(req.method!=='GET')return new Response('Method not allowed',{status:405,headers:cacheHeaders});
  const params=new URL(req.url).searchParams;
  const booking=params.has('booking');
  const code=(params.get(booking?'booking':'code')||'').toLowerCase();
  if(!UUID.test(code))return new Response('Invalid code',{status:400,headers:cacheHeaders});
  if(Date.now()-windowStart>=60000){windowStart=Date.now();requests=0;perToken.clear();}
  const count=(perToken.get(code)||0)+1;
  if(++requests>240||count>30)return new Response('Retry later',{status:429,headers:{...cacheHeaders,'Retry-After':'60'}});
  perToken.set(code,count);
  const {data,error}=booking
    ? await publicDb.rpc('get_customer_booking_pass',{p_token:code})
    : await db.rpc('rf_promotion_qr_available',{p_token:code});
  if(error){
    console.error('QR lookup failed',{kind:booking?'booking':'promotion',code:error.code});
    return new Response('Unavailable',{status:503,headers:cacheHeaders});
  }
  if(!data || (booking && (data.status!=='confirmed' || !UUID.test(data.scan_token || '')))){
    return new Response('Unavailable',{status:410,headers:cacheHeaders});
  }
  const url=new URL(booking?'merchant.html':'promotion-redeem.html',site);
  url.hash=booking ? new URLSearchParams({scan:data.scan_token}).toString() : code;
  const dataUrl=await QRCode.toDataURL(url.href,{width:520,margin:4,errorCorrectionLevel:'M'});
  const bytes=Uint8Array.from(atob(dataUrl.split(',')[1]),c=>c.charCodeAt(0));
  return new Response(bytes,{headers:{...cacheHeaders,'Content-Type':'image/png'}});
});
