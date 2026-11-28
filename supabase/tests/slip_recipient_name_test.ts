import { verifySlip } from '../functions/thunder-verify-slip/thunder.ts';

async function recipientNames(slipName: string, registeredName: string, matchedNumber: string) {
  const result = await verifySlip('fixture', 'fixture', async () => Response.json({
    success: true,
    data: {
      matchedAccount: { bankNumber: matchedNumber, bank: { nameTh:'พร้อมเพย์' }, nameTh: registeredName },
      rawSlip: {
        transRef: 'fixture-reference', amount: { amount: 240 }, date:'2026-11-27T23:22:00+07:00',
        receiver: { account: { name: { th: slipName }, proxy: { type:'NATID', account:'1234567890123' } } }
      }
    }
  }), true);
  return result.receiverNames;
}

Deno.test('a matching full identifier allows completion of an abbreviated surname', async () => {
  const names = await recipientNames('นายสมชาย ใ', 'สมชาย ใจดี', '1234567890123');
  if (names?.join(',') !== 'สมชาย ใจดี') throw new Error('Expected the registered full name');
});

Deno.test('contradictory names or identifiers do not supply an alternative full name', async () => {
  for (const [slipName, matchedNumber] of [
    ['นายสมชาย ใจอื่น','1234567890123'],
    ['นายบุญช่วย ใ','1234567890123'],
    ['นายสมชาย ใ','1234567890124']
  ]) {
    const names = await recipientNames(slipName, 'สมชาย ใจดี', matchedNumber);
    if (names?.join(',') !== slipName) throw new Error('Unexpected substitution of the slip name');
  }
});
