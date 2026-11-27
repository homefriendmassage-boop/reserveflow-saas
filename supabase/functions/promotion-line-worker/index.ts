import { createClient } from 'npm:@supabase/supabase-js@2.98.0';
const site='https://homefriendmassage-boop.github.io/reserveflow-saas/';
const supabaseUrl=Deno.env.get('SUPABASE_URL')||'';
const lineToken=Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN')||'';
const secret=Deno.env.get('PROMOTION_WORKER_SECRET')||'';
const db=createClient(supabaseUrl,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
type Job={id:string;lease_id:string;kind:'issued'|'redeemed';token:string;shop_name:string;offer_name:string;gift_name:string|null;expires_at:string;line_user_id:string};
function flex(job:Job){
  const row=(label:string,value:string)=>({type:'box',layout:'horizontal',spacing:'sm',contents:[
    {type:'text',text:label,size:'sm',color:'#72809C',flex:2,wrap:true},
    {type:'text',text:value,size:'sm',weight:'bold',color:'#203052',flex:3,wrap:true}
  ]});
  const issued=job.kind==='issued';
  const baseUrl=new URL('promotion-redeem.html',site);baseUrl.searchParams.set('code',job.token);
  const qrUrl=new URL('functions/v1/promotion-qr',supabaseUrl+'/');
  qrUrl.searchParams.set('code',job.token);
  return {type:'flex',altText:issued?'🎁 คูปองสิทธิพิเศษ · '+job.shop_name:'✅ ยืนยันการรับสิทธิ์เรียบร้อย',
    contents:{type:'bubble',size:'mega',
      header:{type:'box',layout:'vertical',backgroundColor:issued?'#24458E':'#16795E',paddingAll:'20px',spacing:'sm',contents:[
        {type:'text',text:'ReserveFlow • MEMBER PRIVILEGE',size:'xs',color:'#DCE8FF',weight:'bold'},
        {type:'text',text:issued?'🎁 คูปองของคุณพร้อมแล้ว':'✅ รับสิทธิ์เรียบร้อย',weight:'bold',size:'xl',color:'#FFFFFF',wrap:true},
        {type:'text',text:job.shop_name,size:'sm',color:'#F3F6FF',wrap:true}
      ]},
      body:{type:'box',layout:'vertical',spacing:'md',contents:[
        {type:'text',text:job.offer_name,weight:'bold',size:'lg',color:'#203052',wrap:true},
        ...(job.gift_name?[row('ของแถม',job.gift_name)]:[]),
        ...(issued?[
          {type:'image',url:qrUrl.href,size:'full',aspectMode:'fit',aspectRatio:'1:1'},
          {type:'text',text:'แสดง QR ให้พนักงานสแกน แล้วกดยืนยันรับสิทธิ์เท่านั้น · ใช้ได้ครั้งเดียว',size:'xs',color:'#697790',wrap:true},
          row('หมดอายุ',new Date(job.expires_at).toLocaleString('th-TH',{timeZone:'Asia/Bangkok'}))
        ]:[
          {type:'text',text:'พนักงานยืนยันการรับสิทธิ์แล้ว QR เดิมถูกปิดใช้งานทันที และไม่สามารถนำกลับมาใช้ซ้ำได้',size:'sm',color:'#16795E',wrap:true}
        ])
      ]},
      ...(issued?{footer:{type:'box',layout:'vertical',contents:[{type:'button',style:'primary',color:'#405FC7',action:{type:'uri',label:'เปิดคูปองของฉัน',uri:baseUrl.href}}]}}:{})
    }};
}
function constantTime(a:string,b:string){if(a.length!==b.length)return false;let d=0;for(let i=0;i<a.length;i++)d|=a.charCodeAt(i)^b.charCodeAt(i);return d===0}
Deno.serve(async req=>{
 if(req.method!=='POST')return new Response('Method not allowed',{status:405});
 if(!secret||!lineToken)return new Response('Not configured',{status:503});
 if(!constantTime(req.headers.get('x-promotion-worker-secret')||'',secret))return new Response('Forbidden',{status:403});
 const {data,error}=await db.rpc('rf_claim_promotion_events',{p_limit:10});
 if(error)return Response.json({error:'claim_failed'},{status:500});
 let sent=0,failed=0;
 for(const job of (data||[]) as Job[]){
   let success=false,details='';
   try{
     const resp=await fetch('https://api.line.me/v2/bot/message/push',{method:'POST',headers:{
       'Authorization':'Bearer '+lineToken,'Content-Type':'application/json','X-Line-Retry-Key':job.id
     },body:JSON.stringify({to:job.line_user_id,messages:[flex(job)]}),signal:AbortSignal.timeout(12000)});
     success=resp.ok || (resp.status===409 && resp.headers.has('x-line-accepted-request-id'));
     details=success?'':String(resp.status);
     await resp.body?.cancel();
   }catch(e){details=String(e)}
   const {error:finishError}=await db.rpc('rf_finish_promotion_event',{
     p_id:job.id,p_lease_id:job.lease_id,p_sent:success,p_error:details
   });
   if(finishError || !success)failed++;else sent++;
 }
 return Response.json({handled:(data||[]).length,sent,failed});
});