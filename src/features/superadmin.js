function renderSuperadmin() {
  const shop = getConfig().shop || DEFAULT_CONFIG.shop;
  const shops = [shop, { name: 'ร้านตัวอย่างที่สอง', tenantId: 'SHOP_DEMO_2', plan: 'Starter' }];
  $('superadminShops').innerHTML = shops.map(store => `
    <article class="booking">
      <h3>${esc(store.name)}</h3>
      <p>รหัสร้าน ${esc(store.tenantId)} · แพ็กเกจ ${esc(store.plan)}</p>
    </article>
  `).join('');
}
