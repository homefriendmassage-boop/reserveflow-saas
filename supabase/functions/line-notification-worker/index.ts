import { createClient } from 'npm:@supabase/supabase-js@2.98.0';
import { fixedTimeMatch, lineMessage } from '../_shared/line.ts';

const site = 'https://homefriendmassage-boop.github.io/reserveflow-saas/';

type Delivery = {
  id: string;
  target: string;
  kind: string;
  payload: Record<string, string>;
  lease_id: string;
};

Deno.serve(async request => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const workerSecret = Deno.env.get('LINE_WORKER_SECRET');
  const accessToken = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN');
  if (!workerSecret || !accessToken) return new Response('Not configured', { status: 503 });
  if (!fixedTimeMatch(workerSecret, request.headers.get('x-rf-worker-secret') || '')) {
    return new Response('Forbidden', { status: 403 });
  }
  const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data, error } = await client.rpc('claim_line_notifications');
  if (error) return new Response('Could not claim jobs', { status: 500 });
  const results = await Promise.allSettled((data as Delivery[]).map(async job => {
    let status = 0;
    let delivered = false;
    try {
      const response = await fetch('https://api.line.me/v2/bot/message/push', {
        method: 'POST',
        headers: {
          Authorization: 'Bearer ' + accessToken,
          'Content-Type': 'application/json',
          'X-Line-Retry-Key': job.id
        },
        body: JSON.stringify({ to: job.target, messages: [lineMessage(job.kind, job.payload, site)] }),
        signal: AbortSignal.timeout(10000)
      });
      status = response.status;
      delivered = response.ok || (status === 409 && response.headers.has('x-line-accepted-request-id'));
      await response.body?.cancel();
    } catch {
      // A retry uses the same LINE retry key, even if the prior response was lost.
    }
    const result = await client.rpc('finish_line_notification', {
      p_id: job.id, p_lease_id: job.lease_id, p_status: status,
      p_delivered: delivered, p_retry: !status || status === 429 || status >= 500
    });
    if (result.error) throw result.error;
    return delivered;
  }));
  const failed = results.filter(result => result.status === 'rejected').length;
  return Response.json({
    handled: results.length,
    accepted: results.filter(result => result.status === 'fulfilled' && result.value).length,
    update_failures: failed
  }, { status: failed ? 500 : 200 });
});
