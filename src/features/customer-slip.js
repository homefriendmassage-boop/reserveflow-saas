export function enableSlipAttachment(client, bookingId, phone) {
  const section = document.getElementById('bookingSlip');
  const form = document.getElementById('bookingSlipForm');
  const file = document.getElementById('bookingSlipFile');
  const preview = document.getElementById('bookingSlipPreview');
  const status = document.getElementById('bookingSlipStatus');
  const submit = form.querySelector('button');
  let image = '';
  let selection = 0;
  section.classList.remove('hidden');
  file.addEventListener('change', () => {
    const current = ++selection;
    image = '';
    submit.disabled = true;
    preview.classList.add('hidden');
    preview.removeAttribute('src');
    status.textContent = '';
    const chosen = file.files[0];
    if (!chosen) return;
    if (chosen.size > 1024 * 1024 || !['image/jpeg','image/png','image/webp'].includes(chosen.type)) {
      file.value = '';
      status.textContent = 'กรุณาเลือกไฟล์ JPG, PNG หรือ WebP ขนาดไม่เกิน 1 MB';
      return;
    }
    const reader = new FileReader();
    reader.onloadend = () => {
      if (current !== selection) return;
      if (reader.error) {
        status.textContent = 'อ่านรูปไม่ได้ กรุณาเลือกภาพใหม่';
        return;
      }
      image = reader.result;
      preview.src = image;
      preview.classList.remove('hidden');
      submit.disabled = false;
    };
    reader.readAsDataURL(chosen);
  });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (!image || submit.disabled) return;
    submit.disabled = file.disabled = true;
    status.textContent = 'กำลังส่งสลิป…';
    try {
      const { error } = await client.rpc('attach_customer_booking_slip', {
        p_booking_id: bookingId, p_phone: phone, p_image: image
      });
      if (error) throw error;
      status.textContent = 'ส่งรูปสลิปแล้ว · รอร้านตรวจ';
      submit.classList.add('hidden');
    } catch (error) {
      status.textContent = ({
        SLIP_BOOKING_UNAVAILABLE: 'รายการจองนี้รับสลิปไม่ได้แล้ว กรุณาติดต่อร้าน',
        SLIP_ALREADY_ATTACHED: 'รายการจองนี้มีสลิปแล้ว กรุณาติดต่อร้านหากต้องการเปลี่ยน'
      })[error.message] || (error.code === 'PGRST202' ? 'ร้านยังไม่ได้เปิดใช้การแนบสลิป' : 'ส่งรูปไม่ได้ กรุณาลองอีกครั้ง');
      submit.disabled = file.disabled = false;
    }
  });
}
