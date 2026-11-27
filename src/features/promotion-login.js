const key = 'reserveflow.promotion-login-return';
const promotionPages = new Set(['promotion-manager.html','promotion-redeem.html']);

export function signInForPromotion(client,page) {
  if (!promotionPages.has(page)) throw new Error('Unknown promotion page');
  sessionStorage.setItem(key,JSON.stringify({page,expires:Date.now()+600000}));
  return client.auth.signInWithOAuth({
    provider:'custom:line-manual',
    options:{redirectTo:new URL('./merchant.html',location.href).href}
  });
}

export function resumePromotionLogin() {
  try {
    const value = sessionStorage.getItem(key);
    sessionStorage.removeItem(key);
    if (!value) return false;
    const {page,expires} = JSON.parse(value);
    if (!promotionPages.has(page) || expires<Date.now()) return false;
    location.replace(new URL('./'+page,location.href).href);
    return true;
  } catch {
    return false;
  }
}

export function cancelPromotionLogin() {
  try { sessionStorage.removeItem(key); } catch {}
}
