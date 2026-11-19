let currentMode='customer';
let currentCategory='table';
let selectedResourceId='';

function $(id){return document.getElementById(id)}
function deep(obj){return JSON.parse(JSON.stringify(obj))}
function esc(v){return String(v||'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function money(n){return new Intl.NumberFormat('th-TH').format(Number(n||0))+' บาท'}
function today(){const d=new Date();return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`}
function toast(msg){const el=document.createElement('div');el.className='toast';el.textContent=msg;document.body.appendChild(el);setTimeout(()=>el.remove(),3400)}
function setMode(mode){
  currentMode=mode;
  $('customerView').classList.toggle('hidden',mode!=='customer');
  $('adminView').classList.toggle('hidden',mode!=='admin');
  $('superadminView').classList.toggle('hidden',mode!=='superadmin');
  $('superadminMode').classList.toggle('active',mode==='superadmin');
  $('customerMode').classList.toggle('active',mode==='customer');
  $('adminMode').classList.toggle('active',mode==='admin');
  if(mode==='admin') renderAdmin();
  if(mode==='customer') renderCustomer();
  if(mode==='superadmin') renderSuperadmin();
}
function bindPageEvents() {
  const clickHandlers = {
    customerMode: () => setMode('customer'),
    adminMode: () => { location.href = './merchant.html'; },
    superadminMode: () => setMode('superadmin'),
    submitBooking: createBooking,
    addCategoryButton: addCategory,
    applyLayoutTemplateButton: applyLayoutTemplate,
    addLayoutResource: layoutAdd,
    copyLayoutButton: layoutCopy,
    clearLayoutBackgroundButton: clearLayoutBackground,
    addLayoutDecor: layoutAddDecor,
    resetDemoButton: resetAll
  };
  const changeHandlers = {
    shopName: saveShopSettings,
    bankName: saveShopSettings,
    bankOwner: saveShopSettings,
    bankNumber: saveShopSettings,
    promptpayId: saveShopSettings,
    saasPlan: saveShopSettings,
    layoutCategory: event => layoutSelectCategory(event.currentTarget.value),
    layoutBackgroundInput: event => uploadLayoutBackground(event.currentTarget),
    layoutAspect: event => changeLayoutAspect(event.currentTarget.value),
    layoutWidth: updateLayoutSize,
    layoutHeight: updateLayoutSize,
    adminCategoryFilter: renderAdminBookings,
    adminStatusFilter: renderAdminBookings
  };
  const inputHandlers = { lookupPhone: renderMyBookings, adminSearch: renderAdminBookings };
  for (const [event, handlers] of Object.entries({
    click: clickHandlers, change: changeHandlers, input: inputHandlers
  })) {
    for (const [id, handler] of Object.entries(handlers)) $(id).addEventListener(event, handler);
  }
}

function init(){
  bindPageEvents();
  if(!localStorage.getItem(CONFIG_KEY)) setConfig(deep(DEFAULT_CONFIG));
  ensureCurrentCategory();
  renderCustomer();
}
init();
