export function addThunderCheck(container, client, bookingId, image) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'btn soft small';
  button.textContent = 'ตรวจ QR ด้วย Thunder';
  const feedback = document.createElement('p');
  feedback.setAttribute('role', 'status');
  container.append(button, feedback);

  button.addEventListener('click', async () => {
    button.disabled = true;
    feedback.textContent = 'กำลังอ่าน QR และตรวจสลิป…';
    try {
      await image.decode();
      const canvas = document.createElement('canvas');
      const scale = Math.min(1, 1800 / Math.max(image.naturalWidth, image.naturalHeight));
      canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
      canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
      const context = canvas.getContext('2d', { willReadFrequently: true });
      context.drawImage(image, 0, 0, canvas.width, canvas.height);
      const pixels = context.getImageData(0, 0, canvas.width, canvas.height);
      const QR = window.jsQR(pixels.data, pixels.width, pixels.height);
      if (!QR?.data) {
        feedback.textContent = 'อ่าน QR ไม่ได้ ให้ตรวจจากสลิปต้นฉบับที่เห็น QR ชัดเจน';
        return;
      }
      const { data, error } = await client.functions.invoke('thunder-verify-slip', {
        body: { booking_id: bookingId, payload: QR.data.trim() }
      });
      if (error) throw error;
      const messages = {
        not_configured: 'ยังไม่ได้ตั้งค่า THUNDER_API_KEY ใน Supabase',
        not_verified: 'Thunder ยังยืนยันรายการนี้ไม่ได้',
        provider_unavailable: 'ติดต่อ Thunder ไม่สำเร็จ กรุณาตรวจบัญชี API หรือลองอีกครั้ง'
      };
      if (data.result === 'amount_matches' || data.result === 'amount_differs') {
        const amount = new Intl.NumberFormat('th-TH', { style: 'currency', currency: 'THB' }).format(data.amount);
        feedback.textContent = [
          data.result === 'amount_matches' ? 'Thunder พบรายการและยอดตรง' : 'Thunder พบรายการแต่ยอดไม่ตรง',
          amount, [data.receiverBank, data.receiverName].filter(Boolean).join(' '),
          'เลขอ้างอิง ' + data.reference, 'ตรวจผู้รับและรายการซ้ำก่อนยืนยันการจอง'
        ].filter(Boolean).join(' · ');
      } else {
        feedback.textContent = messages[data.result] || 'ยังตรวจสลิปไม่ได้';
      }
    } catch {
      feedback.textContent = 'ตรวจสลิปไม่ได้ กรุณาตรวจว่าติดตั้งฟังก์ชัน Thunder ใน Supabase แล้ว';
    } finally {
      button.disabled = false;
    }
  });
}
