const thunderUrl = 'https://api.thunder.in.th/v2/verify/bank';

export async function verifySlip(payload: string, key: string, send = fetch) {
  const response = await send(thunderUrl, {
    method: 'POST', redirect: 'error',
    headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ payload }), signal: AbortSignal.timeout(12000)
  });
  if (!response.ok) {
    await response.body?.cancel();
    if (response.status === 429) return { outcome:'retry', providerState:'thunder_limit' };
    if ([401,403].includes(response.status)) return { outcome:'retry', providerState:'thunder_access' };
    return { outcome: response.status >= 500 ? 'retry' : 'not_verified' };
  }
  const body = await response.json();
  const data = body?.data;
  if (body?.success !== true) return { outcome: 'not_verified' };
  if (typeof data?.transRef !== 'string' || !data.transRef.trim() ||
      typeof data?.amount?.amount !== 'number' || !Number.isFinite(data.amount.amount)) return { outcome: 'retry' };

  // Only full PromptPay proxies are used for automatic receiver matching.
  const proxy = data.receiver?.account?.proxy;
  const account = typeof proxy?.account === 'string' ? proxy.account.replace(/[\s-]/g, '') : '';
  const mobile = proxy?.type === 'MSISDN'
    ? account.replace(/^(?:0066|\+66|66)([689][0-9]{8})$/, '0$1') : '';
  const nationalId = ['NATID','NATIONAL_ID'].includes(proxy?.type) && /^[0-9]{13}$/.test(account) ? account : null;
  const time = typeof data.date === 'string' && /(?:Z|[+-]\d{2}:\d{2})$/.test(data.date)
    ? Date.parse(data.date) : NaN;
  return {
    outcome: 'provider_verified',
    reference: data.transRef.trim(),
    amount: data.amount.amount,
    mobile: /^0[689][0-9]{8}$/.test(mobile) ? mobile : null,
    nationalId,
    paidAt: Number.isFinite(time) ? new Date(time).toISOString() : null
  };
}
