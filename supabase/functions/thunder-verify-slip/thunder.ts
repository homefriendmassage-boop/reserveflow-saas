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

  // Only a complete mobile proxy identifies the configured PromptPay receiver.
  const proxy = data.receiver?.account?.proxy;
  const account = typeof proxy?.account === 'string' ? proxy.account.replace(/[\s-]/g, '') : '';
  const mobile = proxy?.type === 'MSISDN'
    ? account.replace(/^(?:0066|\+66|66)([689][0-9]{8})$/, '0$1') : '';
  const bankAccount = data.receiver?.account?.bank?.account;
  const receiverAccount = typeof bankAccount === 'string' ? bankAccount.replace(/[\s-]/g, '') : '';
  const name = data.receiver?.account?.name;
  const receiverNames = [typeof name === 'string' ? name : name?.th, name?.en]
    .filter((value): value is string => typeof value === 'string' && value.trim().length > 0);
  const time = typeof data.date === 'string' && /(?:Z|[+-]\d{2}:\d{2})$/.test(data.date)
    ? Date.parse(data.date) : NaN;
  return {
    outcome: 'provider_verified',
    reference: data.transRef.trim(),
    amount: data.amount.amount,
    receiverAccount: /^[0-9]{6,20}$/.test(receiverAccount) ? receiverAccount : null,
    receiverNames,
    mobile: /^0[689][0-9]{8}$/.test(mobile) ? mobile : null,
    paidAt: Number.isFinite(time) ? new Date(time).toISOString() : null
  };
}
