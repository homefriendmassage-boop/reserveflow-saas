export function bookingTimeOptions() {
  return Array.from({ length: 48 }, (_, index) => {
    const hour = (6 + Math.floor(index / 2)) % 24;
    const time = String(hour).padStart(2, '0') + (index % 2 ? ':30' : ':00');
    return new Option(time, time);
  });
}

export function dateAtShop(timezone, instant = new Date()) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit'
  }).formatToParts(instant).map(part => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

export function timeAtShop(timezone, instant = new Date()) {
  return new Intl.DateTimeFormat('en-GB', {
    timeZone: timezone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23'
  }).format(instant);
}

export function nextBookingDate(date) {
  const next = new Date(date + 'T00:00:00Z');
  next.setUTCDate(next.getUTCDate() + 1);
  return next.toISOString().slice(0,10);
}


export function businessDateAtShop(timezone, instant = new Date()) {
  const date = dateAtShop(timezone, instant);
  if (timeAtShop(timezone, instant) >= '06:00') return date;
  const previous = new Date(date + 'T00:00:00Z');
  previous.setUTCDate(previous.getUTCDate() - 1);
  return previous.toISOString().slice(0,10);
}

export function calendarSlotDate(date, time) {
  return date && time && time < '06:00' ? nextBookingDate(date) : date;
}
