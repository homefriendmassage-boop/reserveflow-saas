const assert = (condition: unknown, message: string) => {
  if (!condition) throw new Error(message);
};

Deno.test("worker authenticates Cron, routes by shop and reports accepted LINE responses", async () => {
  Deno.env.set("SUPABASE_URL", "https://reserveflow-test.invalid");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-key");
  Deno.env.set("PROMOTION_WORKER_SECRET", "test-cron-secret");
  Deno.env.set("PROMOTION_SITE_URL", "https://preview.invalid/");
  const realServe = Deno.serve;
  const realFetch = globalThis.fetch;
  let handler!: (request: Request) => Promise<Response>;
  let mode=200;
  let claims=0;
  let finish: Record<string,unknown> | undefined;
  const id="85510000-0000-4000-8000-000000000099";
  const lease="85510000-0000-4000-8000-000000000019";
  const token="85510000-0000-4000-8000-000000000009";
  Deno.serve = ((callback: typeof handler) => { handler=callback; }) as typeof Deno.serve;
  globalThis.fetch = async (input,init) => {
    const request=new Request(input,init);
    const url=new URL(request.url);
    if (url.hostname==="reserveflow-test.invalid") {
      if (url.pathname.endsWith("rf_claim_promotion_events")) {
        claims++;
        return Response.json([{ id,lease_id:lease,token,kind:"issued",shop_name:"Test shop",
          offer_name:"Gift offer",gift_name:"Drink",expires_at:"2027-01-01",line_user_id:"U"+"1".repeat(32),
          access_token:"shop-specific-test-token" }]);
      }
      if (url.pathname.endsWith("rf_finish_promotion_event")) {
        finish=await request.json();
        return Response.json(true);
      }
    }
    assert(url.hostname==="api.line.me","Unexpected outgoing request");
    assert(request.headers.get("authorization")==="Bearer shop-specific-test-token","Wrong OA token");
    assert(request.headers.get("x-line-retry-key")===id,"Unstable retry key");
    const body=await request.json();
    assert(body.to==="U"+"1".repeat(32),"Wrong customer");
    const flex=JSON.stringify(body.messages);
    assert(flex.includes("https://preview.invalid/promotion-pass.html#"+token),"Wrong customer CTA");
    assert(flex.includes("/functions/v1/promotion-qr?code="),"Missing QR image");
    return new Response(null,{status:mode,headers:mode===409 ? {"x-line-accepted-request-id":"accepted-id"} : {}});
  };
  try {
    await import("../functions/promotion-line-worker/index.ts");
    const workerRequest=(secret?: string)=>new Request("https://reserveflow-test.invalid/functions/v1/promotion-line-worker",{
      method:"POST",headers:secret ? {"x-promotion-worker-secret":secret} : {},
    });
    assert((await handler(workerRequest())).status===403 && claims===0,"Public worker can claim");
    for (const [status,expected] of [[500,false],[409,true],[200,true]] as const) {
      mode=status;
      const result=await (await handler(workerRequest("test-cron-secret"))).json();
      assert(finish?.p_sent===expected && finish?.p_lease_id===lease,"Delivery state or lease wrong");
      assert(result.sent===Number(expected),"Reported delivery before LINE acceptance");
    }
  } finally {
    Deno.serve=realServe;
    globalThis.fetch=realFetch;
  }
});
