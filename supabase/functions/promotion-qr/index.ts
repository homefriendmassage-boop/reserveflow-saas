import QRCode from 'npm:qrcode@1.5.4';
import { createClient } from 'npm:@supabase/supabase-js@2.98.0';
const site='https://homefriendmassage-boop.github.io/reserveflow-saas/';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
Deno.serve(async(req)=>{
  if(req.method!=='GET')return new Response('Method not allowed',{status:405});
  const code=new URL(req.url).searchParams.get('code')||'';
  if(!UUID.test(code))return new Response('Invalid code',{status:400,headers:{'Cache-Control':'no-store'}});
  const {data,error}=await db.from('rf_promotion_vouchers').select('status,expires_at').eq('token',code).maybeSingle();
  if(error||!data)return new Response('Not found',{status:404,headers:{'Cache-Control':'no-store'}});
  if(data.status!=='issued'||new Date(data.expires_at)<=new Date())return new Response('Used or expired',{status:410,headers:{'Cache-Control':'no-store'}});
  const url=new URL('promotion-redeem.html',site);url.searchParams.set('code',code);
  const dataUrl=await QRCode.toDataURL(url.href,{width:520,margin:3,errorCorrectionLevel:'M'});
  const binary=atob(dataUrl.split(',')[1]);const bytes=Uint8Array.from(binary,c=>c.charCodeAt(0));
  return new Response(bytes,{headers:{'Content-Type':'image/png','Cache-Control':'no-store, max-age=0','X-Content-Type-Options':'nosniff'}});
});