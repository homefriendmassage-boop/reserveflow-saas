export function bookingTimeOptions() {
  return Array.from({ length: 25 }, (_, index) => {
    const hour = 10 + Math.floor(index / 2);
    const label = `${hour}:${index % 2 ? '30' : '00'}`;
    return new Option(label, label);
  });
}

export function dateAtShop(timezone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit'
  }).formatToParts(new Date()).map(part => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}
