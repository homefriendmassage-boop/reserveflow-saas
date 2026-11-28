const thunderUrl = 'https://api.thunder.in.th/v2/verify/bank';

function fullAccount(value: unknown) {
  const account = typeof value === 'string' ? value.replace(/[\s-]/g, '') : '';
  return /^[0-9]{6,20}$/.test(account) ? account : null;
}

function nameParts(name: string) {
  return name.normalize('NFC').trim().toLowerCase()
    .replace(/^(นางสาว|นาง|นาย|น\.ส\.)\s*/u,'')
    .replace(/^(mr|mrs|ms|miss)(\.\s*|\s+)/u,'')
    .split(/\s+/u);
}

function agreesWithAbbreviatedName(slipName: string, registeredName: string) {
  const slip = nameParts(slipName);
  const registered = nameParts(registeredName);
  if (slip.length < 2 || slip.length !== registered.length) return false;
  const tail = slip.at(-1)!;
  const surname = registered.at(-1)!;
  const visible = /^(\p{L})(?:[.*•]+)?$/u.exec(tail)?.[1];
  return Boolean(visible && surname.startsWith(visible) && surname.length > visible.length
    && slip.slice(0,-1).every((part,index) => part === registered[index]));
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

  // Mobile and national-ID proxies identify PromptPay independently of bank accounts.
  const proxy = data.receiver?.account?.proxy;
  const account = typeof proxy?.account === 'string' ? proxy.account.replace(/[\s-]/g, '') : '';
  const mobile = proxy?.type === 'MSISDN'
    ? account.replace(/^(?:0066|\+66|66)([689][0-9]{8})$/, '0$1') : '';
  const bankIdentifier = data.receiver?.account?.bank;
  // V2 can return TOKEN or DUMMY identifiers in the same field as BANKAC.
  const rawAccount = bankIdentifier?.type === 'BANKAC' ? fullAccount(bankIdentifier.account) : null;
  const matched = matchAccount ? result?.matchedAccount : null;
  const matchedNumber = fullAccount(matched?.bankNumber);
  const rawProxy = proxy?.type === 'NATID' && /^\d{13}$/.test(account) ? account
    : /^0[689][0-9]{8}$/.test(mobile) ? mobile : null;
  const matchedIsPromptPay = [matched?.bank?.shortCode,matched?.bank?.nameEn,matched?.bank?.nameTh]
    .some(value => typeof value === 'string' && /^(promptpay|พร้อมเพย์)$/i.test(value.replace(/\s/g,'')));
  const matchedProxy = matchedIsPromptPay ? matchedNumber : null;
  const proxyConflict = rawProxy && matchedProxy && rawProxy !== matchedProxy;
  const receiverPromptPay = rawProxy ?? matchedProxy;
  const bankNumber = rawAccount && rawAccount !== receiverPromptPay ? rawAccount : null;
  const matchedBank = matchedIsPromptPay ? null : matchedNumber;
  const receiverAccount = bankNumber && matchedBank && bankNumber !== matchedBank
    ? null : bankNumber ?? matchedBank;
  const name = data.receiver?.account?.name;
  const presentName = (value: unknown): value is string => typeof value === 'string' && value.trim().length > 0;
  const slipNames = [typeof name === 'string' ? name : name?.th, name?.en].filter(presentName);
  // Only use registered names for the identifier this response actually verified.
  const matchedIdentifierAgrees = !proxyConflict && Boolean(matchedNumber) &&
    (receiverAccount ? !matchedIsPromptPay && receiverAccount === matchedNumber
      : matchedIsPromptPay && receiverPromptPay === matchedNumber && !bankNumber);
  const namePairs = [[typeof name === 'string' ? name : name?.th,matched?.nameTh],[name?.en,matched?.nameEn]];
  const receiverNames = matchedIdentifierAgrees
    ? (slipNames.length ? namePairs.flatMap(([slip,registered]) => {
      if (!presentName(slip)) return [];
      return presentName(registered) && agreesWithAbbreviatedName(slip,registered) ? [registered] : [slip];
    }) : [matched.nameTh,matched.nameEn].filter(presentName))
    : slipNames;
  const time = typeof data.date === 'string' && /(?:Z|[+-]\d{2}:\d{2})$/.test(data.date)
    ? Date.parse(data.date) : NaN;
  return {
    outcome: 'provider_verified',
    reference,
    amount,
    receiverAccount: proxyConflict ? null : receiverAccount,
    receiverPromptPay: proxyConflict || (bankNumber && !receiverAccount) ? null : receiverPromptPay,
    receiverNames,
    mobile: /^0[689][0-9]{8}$/.test(mobile) ? mobile : null,
    paidAt: Number.isFinite(time) ? new Date(time).toISOString() : null
  };
}
