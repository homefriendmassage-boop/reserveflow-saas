const assert = (condition: unknown, message: string) => {
  if (!condition) throw new Error(message);
};

Deno.test("public voucher image only serves live one-time tokens",async () => {
  Deno.env.set("SUPABASE_URL","https://reserveflow-test.invalid");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY","test-key");
  Deno.env.set("PROMOTION_SITE_URL","https://preview.invalid/");
  const realServe=Deno.serve;
  const realFetch=globalThis.fetch;
  let handler!: (r:Request)=>Promise<Response>;
  let available=true;
  let lookups=0;
  Deno.serve=((callback:typeof handler)=>{handler=callback;}) as typeof Deno.serve;
  globalThis.fetch=async(input,init)=>{
    const request=new Request(input,init);
    assert(new URL(request.url).pathname.endsWith("rf_promotion_qr_available"),"Unexpected external request");
    lookups++;
    return Response.json(available);
  };
  try {
    await import("../functions/promotion-qr/index.ts");
    const request=(code:string)=>new Request("https://reserveflow-test.invalid/functions/v1/promotion-qr?code="+code);
    const token="85510000-0000-4000-8000-000000000009";
    assert((await handler(request("bad"))).status===400 && lookups===0,"Malformed token reached the database");
    const image=await handler(request(token));
    assert(image.status===200 && image.headers.get("content-type")==="image/png","QR image not generated");
    assert(image.headers.get("cache-control")?.includes("no-store"),"QR can be cached");
    const bytes=new Uint8Array(await image.arrayBuffer());
    assert(bytes.slice(0,8).join(",")==="137,80,78,71,13,10,26,10","Output is not PNG");
    available=false;
    assert((await handler(request(token))).status===410,"Used or expired token still returns an image");
    let result:Response|undefined;
    for(let i=0;i<30;i++)result=await handler(request(token));
    assert(result?.status===429,"Rate limit missing");
  } finally {
    Deno.serve=realServe;
    globalThis.fetch=realFetch;
  }
});
