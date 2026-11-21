export function bindSlipImage(input, choose, preview, onChange) {
  let revision = 0;
  const reset = () => {
    revision++;
    input.value = '';
    preview.classList.add('hidden');
    preview.removeAttribute('src');
    choose.textContent = 'เลือกรูปสลิป';
  };
  choose.onclick = () => input.click();
  input.onchange = async () => {
    const file = input.files[0];
    reset();
    onChange('');
    if (!file) return;
    const step = revision;
    if (!['image/jpeg','image/png','image/webp'].includes(file.type) || file.size > 1024*1024) {
      onChange('', 'เลือกรูป JPG, PNG หรือ WebP ขนาดไม่เกิน 1 MB');
      return;
    }
    try {
      const image = await new Promise((resolve,reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
      const testImage = new Image();
      testImage.src = image;
      await testImage.decode();
      if (step !== revision) return;
      preview.src = image;
      preview.classList.remove('hidden');
      choose.textContent = 'เปลี่ยนรูปสลิป';
      onChange(image);
    } catch {
      if (step === revision) onChange('', 'เปิดรูปไม่ได้ กรุณาเลือกรูปสลิปใหม่');
    }
  };
  return reset;
}
