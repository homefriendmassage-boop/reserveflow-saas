import { renderMerchantSettings } from './merchant-settings.js?v=floor-template-41';

function node(tag,text = '') {
  const item = document.createElement(tag);
  item.textContent = text;
  return item;
}

function field(label,value,options = {}) {
  const input = Object.assign(node('input'),options);
  if (input.type === 'checkbox') input.checked = Boolean(value);
  else input.value = value ?? '';
  const wrapper = node('label');
  wrapper.className = 'field';
  wrapper.append(node('span',label),input);
  return {wrapper,input};
}

export function shopSupportPanel(client,shop,onShopChanged) {
  const panel = node('details');
  const body = node('div');
  const status = node('p');
  status.setAttribute('role','status');
  panel.append(node('summary','ช่วยตั้งค่าร้านนี้'),status,body);
  const errors = {
    PGRST202:'รัน SQL 49 และ 50 เพื่อเปิดเมนูช่วยตั้งค่าร้าน',
    '42501':'เฉพาะ Superadmin ที่ใช้เมนูนี้ได้',
    '22023':'กรุณาตรวจข้อมูลที่กรอก',
    PLATFORM_SHOP_NOT_FOUND:'ไม่พบร้านนี้',
    PLATFORM_CATEGORY_NOT_FOUND:'ไม่พบหมวดนี้ในร้าน',
    PLATFORM_SHOP_BOOKING_SUSPENDED:'ร้านถูกระงับการจอง ให้เปิดรับจองจากเมนูจัดการร้านก่อน',
    SHOP_LINE_NOT_CONFIGURED:'ให้เจ้าของร้านเชื่อม LINE OA ก่อน'
  };
  const errorText = error => errors[error.message] || errors[error.code] || 'ทำรายการไม่สำเร็จ กรุณาลองใหม่';
  function form(title,section,fields,extra = {}) {
    const wrapper = node('form');
    wrapper.className = 'merchant-settings-panel';
    const inputs = node('div');
    inputs.className = 'fields';
    inputs.append(...Object.values(fields).map(item => item.wrapper));
    const save = node('button','บันทึก');
    save.type = 'submit';
    save.className = 'btn soft small';
    const feedback = node('p');
    feedback.setAttribute('role','status');
    wrapper.append(node('h4',title),inputs,save,feedback);
    wrapper.onsubmit = async event => {
      event.preventDefault();
      if (save.disabled) return;
      const values = {...extra};
      for (const [key,{input}] of Object.entries(fields)) {
        values[key] = input.type === 'checkbox' ? input.checked
          : input.type === 'number' ? Number(input.value) : input.value.trim();
      }
      save.disabled = true;
      try {
        const {error} = await client.rpc('save_platform_shop_support',{
          p_shop_id:shop.shop_id,p_section:section,p_values:values
        });
        if (error) throw error;
        feedback.textContent = 'บันทึกแล้ว';
        if (section === 'shop') onShopChanged(values);
      } catch (error) { feedback.textContent = errorText(error); }
      finally { save.disabled = false; }
    };
    return wrapper;
  }

  const categoryEditor = node('div');
  const layoutEditor = node('div');
  categoryEditor.className = layoutEditor.className = 'merchant-editor';
  async function loadEditors() {
    const {data,error} = await client.rpc('platform_shop_support_editors',{p_shop_id:shop.shop_id});
    if (error) throw error;
    renderMerchantSettings(layoutEditor,{
      categoryContainer:categoryEditor,...data,owner:true,
      save:async (rpc,args) => {
        const {data,error} = await client.rpc(rpc,{...args,p_shop_id:shop.shop_id});
        if (error) throw error;
        return data;
      },
      reload:loadEditors
    });
  }
  panel.addEventListener('toggle',async () => {
    if (!panel.open || body.childElementCount || status.dataset.loading) return;
    status.dataset.loading = '1';
    status.textContent = 'กำลังโหลดการตั้งค่าร้าน…';
    try {
      const {data,error} = await client.rpc('platform_shop_support_settings',{p_shop_id:shop.shop_id});
      if (error) throw error;
      body.append(form('ตั้งค่าร้านค้า','shop',{
        name:field('ชื่อร้าน',data.name,{required:true,maxLength:100}),
        open:field('เปิดรับจองออนไลน์',data.open,{type:'checkbox',disabled:data.suspended})
      }));
      const webhook = field('Webhook URL ของร้าน',
        `https://zotgxsimkrofqxkhjjak.supabase.co/functions/v1/line-webhook?shop=${encodeURIComponent(shop.shop_id)}`,
        {readOnly:true});
      body.append(webhook.wrapper);
      if (data.line) {
        body.append(form('LINE OA · ' + data.line.bot_name,'line',{
          friend_id:field('LINE ID สำหรับเพิ่มเพื่อน',data.line.friend_id,{maxLength:50}),
          liff_id:field('LIFF ID สำหรับหน้าจอง',data.line.liff_id,{maxLength:53})
        }));
      } else body.append(node('p','เจ้าของร้านยังไม่ได้เชื่อม LINE OA'));
      body.append(categoryEditor,layoutEditor);
      try {
        await loadEditors();
        status.textContent = '';
      } catch (error) {
        status.textContent = error.code === 'PGRST202' ? 'รัน SQL 50 เพื่อเปิดหมวด พนักงาน โซนบัตร และผัง' : errorText(error);
      }
    } catch (error) { status.textContent = errorText(error); }
    finally { delete status.dataset.loading; }
  });
  return panel;
}
