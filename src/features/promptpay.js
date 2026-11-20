// Thai QR Payment merchant-presented format, PromptPay proxy by mobile number.
export function promptPayPayload(mobile, amount) {
  if (!/^0[689][0-9]{8}$/.test(mobile || '') || !Number.isFinite(amount) || amount <= 0 || amount > 9999999999.99) {
    throw new Error('Invalid PromptPay payment details');
  }
  const field = (tag, value) => tag + String(value.length).padStart(2, '0') + value;
  const account = field('00', 'A000000677010111') + field('01', '0066' + mobile.slice(1));
  const payload = [
    field('00', '01'), field('01', '12'), field('29', account),
    field('58', 'TH'), field('53', '764'), field('54', amount.toFixed(2)), '6304'
  ].join('');
  let crc = 0xffff;
  for (const character of payload) {
    crc ^= character.charCodeAt(0) << 8;
    for (let bit = 0; bit < 8; bit++) crc = ((crc << 1) ^ (crc & 0x8000 ? 0x1021 : 0)) & 0xffff;
  }
  return payload + crc.toString(16).toUpperCase().padStart(4, '0');
}
