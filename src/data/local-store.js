const BOOKING_KEY='reserveflow_bookings_v2';
const CONFIG_KEY='reserveflow_config_v2';
function getBookings(){try{return JSON.parse(localStorage.getItem(BOOKING_KEY)||'[]')}catch(e){return []}}
function setBookings(v){localStorage.setItem(BOOKING_KEY,JSON.stringify(v))}
function getConfig(){
  try{
    const data=JSON.parse(localStorage.getItem(CONFIG_KEY)||'null');
    if(data&&data.categories&&data.resources)return data;
  }catch(e){}
  return deep(DEFAULT_CONFIG);
}
function setConfig(v){localStorage.setItem(CONFIG_KEY,JSON.stringify(v))}
function getCategory(id){return getConfig().categories.find(c=>c.id===id)}
function visibleCategories(){return getConfig().categories.filter(c=>c.visible)}
function getResources(catId){const cat=getCategory(catId);if(!cat)return[];const cfg=getConfig();return cfg.resources[catId]||cfg.resources[cat.template]||[]}

function resetDemoStore(){
  localStorage.removeItem(BOOKING_KEY);
  localStorage.removeItem(CONFIG_KEY);
}
