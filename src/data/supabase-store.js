async function read(query) {
  const { data, error } = await query;
  if (error) throw error;
  return data;
}

export function listMerchantShops(client) {
  return read(client.from('shops').select('id,name,timezone').order('name'));
}

export function createSupabaseStore(client, shopId) {
  if (!shopId) throw new Error('A shop ID is required');

  return {
    createTableBooking: payload => read(client.rpc('create_merchant_table_booking', { ...payload, p_shop_id: shopId })),
    changeTableStatus: (id, status) => read(client.rpc('change_merchant_table_booking_status', {
      p_shop_id: shopId, p_booking_id: id, p_status: status
    })),
    getShop: () => read(client.from('shops').select('*').eq('id', shopId).single()),
    getCategories: () => read(client.from('categories').select('*').eq('shop_id', shopId).order('sort_order')),
    getResources: () => read(client.from('resources').select('*').eq('shop_id', shopId)),
    getLayouts: () => read(client.from('layouts').select('*').eq('shop_id', shopId)),
    getBookings: () => read(client.from('bookings').select('id,category_code,resource_code,starts_at,ends_at,amount,status').eq('shop_id', shopId).order('created_at', { ascending: false }))
  };
}
