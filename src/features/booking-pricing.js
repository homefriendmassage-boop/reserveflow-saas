const hourlyTemplates = new Set(['seat','staff','vip']);

export function isHourlyBooking(template) {
  return hourlyTemplates.has(template);
}

export function bookingPrice(category, quantity) {
  const rate = Math.round(Number(category.price) * 100);
  const base = rate * Number(quantity);
  const fee = Math.round(Number(category.service_fee || 0) * 100);
  let subtotal = base;
  let packageHours = 0;
  if (isHourlyBooking(category.template)) {
    for (const [hours,price] of Object.entries(category.hour_promotions || {})) {
      const duration = Number(hours);
      if (duration > quantity) continue;
      const candidate = Math.round(Number(price)*100) + (quantity-duration)*rate;
      if (candidate < subtotal || (candidate === subtotal && packageHours && duration > packageHours)) {
        subtotal = candidate;
        packageHours = duration;
      }
    }
  }
  return { total:(subtotal+fee)/100, savings:(base-subtotal)/100, packageHours,
    extraHours:packageHours ? Number(quantity)-packageHours : 0 };
}
