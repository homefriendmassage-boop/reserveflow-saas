export async function initBookingLiff(client, shopSlug) {
  try {
    const {data:liffId,error} = await client.rpc('shop_booking_liff',{p_shop_slug:shopSlug});
    if (error || !liffId) return null;
    if (!window.liff) {
      await new Promise((resolve,reject) => {
        const script = document.createElement('script');
        script.src = 'https://static.line-scdn.net/liff/edge/2/sdk.js';
        const timeout = setTimeout(reject,8000);
        script.onload = () => { clearTimeout(timeout); resolve(); };
        script.onerror = () => { clearTimeout(timeout); reject(); };
        document.head.append(script);
      });
    }
    await window.liff.init({liffId});
    return window.liff;
  } catch {
    return null;
  }
}

export async function submitLiffPayment(client,liff,payment) {
  const idToken = liff?.getIDToken();
  if (!idToken) throw new Error('BOOKING_LINE_EXPIRED');
  const {data,error} = await client.functions.invoke('booking-line-payment',{
    body:{id_token:idToken,payment}
  });
  if (error) throw new Error('BOOKING_LINE_UNAVAILABLE');
  if (data?.error) throw new Error(data.error);
  if (!data?.booking) throw new Error('BOOKING_LINE_UNAVAILABLE');
  return data.booking;
}
