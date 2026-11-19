const slug = new URLSearchParams(location.search).get('shop') || 'demo-one';
const bookingPage = new URL('./book.html', location.href);
bookingPage.searchParams.set('shop', slug);
location.replace(bookingPage);
