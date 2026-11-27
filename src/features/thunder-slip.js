export async function checkThunderSlip(client, bookingId, phone) {
  const { data, error } = await client.functions.invoke('thunder-verify-slip', {
    body: { booking_id: bookingId, ...(phone ? { phone } : {}) }
  });
  if (error) throw error;
  return data;
}

export function thunderStatus(result) {
  const amount = Number(result?.amount);
  const amountText = Number.isFinite(amount) && amount > 0
    ? ' · ยอดในสลิป ' + new Intl.NumberFormat('th-TH', { style: 'currency', currency: 'THB' }).format(amount)
    : '';
  const messages = {
    confirmed: 'ตรวจผ่านและยืนยันการจองแล้ว',
    amount_review: 'ระบบพบรายการโอน แต่ยอดไม่ตรง · รอแอดมินยืนยัน',
    receiver_review: 'สลิปไม่ผ่าน · ยืนยันชื่อผู้รับ เลขบัญชี หรือเวลาโอนไม่ได้',
    duplicate_review: 'เลขอ้างอิงนี้ผูกกับรายการจองอื่นแล้ว · รอแอดมินตรวจ',
    booking_review: 'ตรวจพบรายการโอน · รอแอดมินตรวจสถานะจอง',
    qr_unreadable: 'ระบบอ่าน QR ไม่ได้ · รอแอดมินตรวจรูปสลิป',
    not_verified: 'ระบบยังยืนยันรายการนี้ไม่ได้ · รอแอดมินตรวจ',
    thunder_limit: 'ระบบตรวจสลิปอัตโนมัติจำกัดการตรวจในขณะนี้ · กรุณาลองใหม่',
    thunder_access: 'ระบบตรวจสลิปอัตโนมัติปฏิเสธสิทธิ์ · ติดต่อผู้ดูแล',
    manual_review: 'รอร้านตรวจสอบสลิปโอนเข้าบัญชีธนาคาร',
    no_credit: 'เครดิตตรวจสลิปหมด · รอร้านตรวจด้วยตนเอง',
    checking: 'ระบบกำลังตรวจสลิป',
    retry: 'ยังไม่มีผลยืนยันจากระบบตรวจสลิป · กดตรวจสลิปอีกครั้ง',
    provider_timeout: 'ระบบตรวจสลิปตอบกลับช้าเกินกำหนด · กรุณาลองตรวจใหม่',
    provider_unavailable: 'ระบบตรวจสลิปยังติดต่อไม่ได้ · กรุณาลองตรวจใหม่',
    provider_response_incomplete: 'ระบบตรวจสลิปส่งข้อมูลยอดหรือเลขอ้างอิงมาไม่ครบ · กรุณาลองตรวจใหม่',
    verification_save_unavailable: 'ระบบบันทึกผลตรวจสลิปไม่ได้ · ให้ผู้ดูแลดู Logs ของตัวตรวจสลิป',
    receiver_account_unavailable: 'ระบบตรวจสลิปไม่ได้รับเลขบัญชีผู้รับแบบเต็ม จึงยืนยันรายการไม่ได้',
    receiver_name_unavailable: 'ระบบตรวจสลิปไม่ได้รับชื่อผู้รับ จึงยืนยันรายการไม่ได้',
    unavailable: 'เปิดข้อมูลตรวจสลิปไม่ได้ · กรุณาลองใหม่หรือติดต่อผู้ดูแล',
    not_configured: 'ระบบตรวจสลิปอัตโนมัติยังไม่พร้อม · รอแอดมินตรวจ'
  };
  return (messages[result?.state] || 'ส่งสลิปแล้ว · รอแอดมินตรวจ') + amountText;
}

export function addThunderCheck(container, client, bookingId, initial, refresh) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'btn soft small';
  button.textContent = 'ตรวจสลิป';
  const feedback = document.createElement('p');
  feedback.setAttribute('role', 'status');
  feedback.textContent = thunderStatus({ state: initial.verification_state, amount: initial.verified_amount });
  container.append(button, feedback);

  button.addEventListener('click', async () => {
    button.disabled = true;
    feedback.textContent = 'กำลังตรวจสลิป…';
    try {
      const result = await checkThunderSlip(client, bookingId);
      feedback.textContent = thunderStatus(result);
      if (['confirmed','amount_review'].includes(result?.state) && initial.verification_state !== result.state) await refresh();
    } catch {
      feedback.textContent = 'ตรวจสลิปไม่ได้ กรุณาลองตรวจใหม่';
    } finally {
      button.disabled = false;
    }
  });
}
