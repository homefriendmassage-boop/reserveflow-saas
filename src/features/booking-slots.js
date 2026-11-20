export function bookingTimeOptions() {
  return Array.from({ length: 25 }, (_, index) => {
    const hour = 10 + Math.floor(index / 2);
    const label = `${hour}:${index % 2 ? '30' : '00'}`;
    return new Option(label, label);
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
