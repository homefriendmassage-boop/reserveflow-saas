async function read(query) {
  const { data, error } = await query;
  if (error) throw error;
  return data;
}

export async function listMerchantShops(client) {
  const [shops, memberships] = await Promise.all([
    read(client.from('shops').select('id,name,timezone,public_booking_enabled').order('name')),
    read(client.from('shop_members').select('shop_id,role'))
  ]);
  const roles = new Map(memberships.map(member => [member.shop_id, member.role]));
  return shops.filter(shop => roles.has(shop.id)).map(shop => ({ ...shop, role: roles.get(shop.id) }));
}

export function createSupabaseStore(client, shopId) {
  if (!shopId) throw new Error('A shop ID is required');

  return {
    updateShop: (name, enabled) => read(client.rpc('update_merchant_shop', {
      p_shop_id: shopId, p_name: name, p_enabled: enabled
    })),
    setStaffRole: (userId, role) => read(client.rpc('set_merchant_staff_role', {
      p_shop_id: shopId, p_user_id: userId, p_role: role
    })),
    moveTable: (category, resource, x, y) => read(client.rpc('move_merchant_table', {
      p_shop_id: shopId, p_category_code: category, p_resource_code: resource, p_x: x, p_y: y
    })),
    checkIn: id => read(client.rpc('check_in_merchant_booking', { p_shop_id: shopId, p_booking_id: id })),
    createTableBooking: payload => read(client.rpc('create_merchant_table_booking', { ...payload, p_shop_id: shopId })),
    changeTableStatus: (id, status) => read(client.rpc('change_merchant_table_booking_status', {
      p_shop_id: shopId, p_booking_id: id, p_status: status
    })),
    getShop: () => read(client.from('shops').select('*').eq('id', shopId).single()),
    getCategories: () => read(client.from('categories').select('*').eq('shop_id', shopId).order('sort_order').order('code')),
    getResources: () => read(client.from('resources').select('*').eq('shop_id', shopId)),
    getLayouts: () => read(client.from('layouts').select('*').eq('shop_id', shopId)),
    getBookings: () => read(client.from('bookings').select('id,category_code,resource_code,starts_at,ends_at,amount,status').eq('shop_id', shopId).order('created_at', { ascending: false }))
  };
}
