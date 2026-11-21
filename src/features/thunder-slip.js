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
    amount_review: 'Thunder พบรายการโอน แต่ยอดไม่ตรง · รอแอดมินยืนยัน',
    receiver_review: 'Thunder พบรายการโอน · รอตรวจผู้รับหรือเวลาโอน',
    duplicate_review: 'เลขอ้างอิงนี้ผูกกับรายการจองอื่นแล้ว · รอแอดมินตรวจ',
    booking_review: 'ตรวจพบรายการโอน · รอแอดมินตรวจสถานะจอง',
    qr_unreadable: 'ระบบอ่าน QR ไม่ได้ · รอแอดมินตรวจรูปสลิป',
    not_verified: 'Thunder ยังยืนยันรายการนี้ไม่ได้ · รอแอดมินตรวจ',
    thunder_limit: 'Thunder จำกัดการตรวจในขณะนี้ · ตรวจโควต้าในบัญชี Thunder แล้วลองใหม่',
    thunder_access: 'Thunder ปฏิเสธสิทธิ์ · ตรวจ API Key และสิทธิ์ของบัญชี Thunder',
    no_credit: 'เครดิตตรวจสลิปหมด · รอร้านตรวจด้วยตนเอง',
    checking: 'ระบบกำลังตรวจสลิป',
    retry: 'ติดต่อ Thunder ไม่สำเร็จ · รอแอดมินตรวจ',
    not_configured: 'ร้านยังไม่ได้ตั้งค่า Thunder · รอแอดมินตรวจ'
  };
  return (messages[result?.state] || 'ส่งสลิปแล้ว · รอแอดมินตรวจ') + amountText;
}

export function addThunderCheck(container, client, bookingId, initial, refresh) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'btn soft small';
  button.textContent = 'ตรวจสลิปด้วย Thunder';
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
      if (result?.state === 'confirmed' && initial.verification_state !== 'confirmed') await refresh();
    } catch {
      feedback.textContent = 'ตรวจสลิปไม่ได้ กรุณาตรวจว่าติดตั้งฟังก์ชัน Thunder ใน Supabase แล้ว';
    } finally {
      button.disabled = false;
    }
  });
}
