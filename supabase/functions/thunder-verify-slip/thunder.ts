const thunderUrl = 'https://api.thunder.in.th/v2/verify/bank';

function fullAccount(value: unknown) {
  const account = typeof value === 'string' ? value.replace(/[\s-]/g, '') : '';
  return /^[0-9]{6,20}$/.test(account) ? account : null;
}

export async function verifySlip(payload: string, key: string, send = fetch, matchAccount = false) {
  const response = await send(thunderUrl, {
    method: 'POST', redirect: 'error',
    headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ payload, ...(matchAccount ? { matchAccount:true } : {}) }), signal: AbortSignal.timeout(12000)
  });
  if (!response.ok) {
    await response.body?.cancel();
    if (response.status === 429) return { outcome:'retry', providerState:'thunder_limit' };
    if ([401,403].includes(response.status)) return { outcome:'retry', providerState:'thunder_access' };
    return response.status >= 500 ? { outcome:'retry', providerState:'provider_unavailable' } : { outcome:'not_verified' };
  }
  let body;
  try {
    body = await response.json();
  } catch {
    return {outcome:'retry',providerState:'provider_response_incomplete'};
  }
  const result = body?.data;
  const data = result?.rawSlip ?? result;
  if (body?.success !== true) return { outcome: 'not_verified' };
  const reference = typeof data?.transRef === 'string' ? data.transRef.trim() : '';
  if (!reference || reference.length > 200) return {outcome:'retry',providerState:'provider_reference_unavailable'};

  // Accept a JSON number or a decimal string without guessing currency or units.
  const rawAmount = typeof data.amount === 'object' && data.amount !== null
    ? data.amount.amount : data.amount;
  const amount = typeof rawAmount === 'number' ? rawAmount
    : typeof rawAmount === 'string' && /^\d{1,10}(?:\.\d{1,2})?$/.test(rawAmount.trim())
      ? Number(rawAmount.trim()) : NaN;
  if (!Number.isFinite(amount) || amount <= 0 || amount > 9999999999.99)
    return {outcome:'retry',providerState:'provider_amount_unavailable'};

  // Only a complete mobile proxy identifies the configured PromptPay receiver.
  const proxy = data.receiver?.account?.proxy;
  const account = typeof proxy?.account === 'string' ? proxy.account.replace(/[\s-]/g, '') : '';
  const mobile = proxy?.type === 'MSISDN'
    ? account.replace(/^(?:0066|\+66|66)([689][0-9]{8})$/, '0$1') : '';
  const rawAccount = fullAccount(data.receiver?.account?.bank?.account);
  const matched = matchAccount ? result?.matchedAccount : null;
  const matchedNumber = fullAccount(matched?.bankNumber);
  const receiverAccount = rawAccount && matchedNumber && rawAccount !== matchedNumber
    ? null : rawAccount ?? matchedNumber;
  const name = data.receiver?.account?.name;
  const candidates = rawAccount
    ? [typeof name === 'string' ? name : name?.th, name?.en]
    : matchedNumber ? [matched.nameTh, matched.nameEn] : [];
  const receiverNames = candidates
    .filter((value): value is string => typeof value === 'string' && value.trim().length > 0);
  const time = typeof data.date === 'string' && /(?:Z|[+-]\d{2}:\d{2})$/.test(data.date)
    ? Date.parse(data.date) : NaN;
  return {
    outcome: 'provider_verified',
    reference,
    amount,
    receiverAccount,
    receiverNames,
    mobile: /^0[689][0-9]{8}$/.test(mobile) ? mobile : null,
    paidAt: Number.isFinite(time) ? new Date(time).toISOString() : null
  };
}
