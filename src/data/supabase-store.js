// A future entry point can inject an authenticated Supabase JS client here.
export function createSupabaseStore(client, shopId) {
  if (!shopId) throw new Error('A shop ID is required');

  async function read(query) {
    const { data, error } = await query;
    if (error) throw error;
    return data;
  }

  return {
    getShop: () => read(client.from('shops').select('*').eq('id', shopId).single()),
    getCategories: () => read(client.from('categories').select('*').eq('shop_id', shopId).order('sort_order')),
    getResources: () => read(client.from('resources').select('*').eq('shop_id', shopId)),
    getLayouts: () => read(client.from('layouts').select('*').eq('shop_id', shopId)),
    getBookings: () => read(client.from('bookings').select('*').eq('shop_id', shopId).order('created_at', { ascending: false }))
  };
}
