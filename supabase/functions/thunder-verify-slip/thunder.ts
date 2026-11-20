const thunderUrl = 'https://api.thunder.in.th/v2/verify/bank';

export async function verifySlip(payload: string, key: string, expectedAmount: number, send = fetch) {
  const response = await send(thunderUrl, {
    method: 'POST',
    redirect: 'error',
    headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ payload }),
    signal: AbortSignal.timeout(12000)
  });
  if (!response.ok) {
    await response.body?.cancel();
    return { result: response.status === 429 || response.status >= 500 || [401,403].includes(response.status)
      ? 'provider_unavailable' : 'not_verified' };
  }
  const body = await response.json();
  const data = body?.data;
  if (body?.success !== true) return { result: 'not_verified' };
  if (typeof data?.transRef !== 'string' || !data.transRef.trim() ||
      typeof data?.amount?.amount !== 'number' || !Number.isFinite(data.amount.amount)) {
    return { result: 'provider_unavailable' };
  }
  const safeText = (value: unknown) => typeof value === 'string' ? value.slice(0, 200) : '';
  return {
    result: Math.round(data.amount.amount * 100) === Math.round(expectedAmount * 100) ? 'amount_matches' : 'amount_differs',
    amount: data.amount.amount,
    reference: safeText(data.transRef),
    receiverBank: safeText(data.receiver?.bank?.short),
    receiverName: safeText(data.receiver?.account?.name?.th)
  };
}
