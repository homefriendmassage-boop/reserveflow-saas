# ReserveFlow SaaS

หน้าร้านจริงอ่านข้อมูลร้านจาก Supabase ส่วน `booking-layout-archive.html` เก็บหน้าต้นแบบที่ใช้ข้อมูลในเบราว์เซอร์เดิมสำหรับอ้างอิงและกู้ผัง

## รันและทดสอบในเครื่อง

ต้องมี Python 3 รันจากรากของ repository

```bash
python3 -m http.server 8000 --bind 127.0.0.1
```

เปิด `http://127.0.0.1:8000/` เพื่อเข้าหน้าจองจริง หรือเปิด `booking-layout-archive.html` โดยตรงเพื่อทดสอบต้นแบบด้วยข้อมูลสมมติ

- ลูกค้า: ลองจองโต๊ะ พนักงาน ห้อง VIP ที่นั่ง และบัตรด้วยข้อมูลตัวอย่าง จากนั้นค้นหาด้วยเบอร์ที่ใช้จอง
- Merchant Admin: ลองเพิ่ม เปลี่ยนชื่อ เรียง ซ่อน และลบหมวด แล้วทดสอบเปลี่ยนเทมเพลต ลาก คัดลอก ปรับขนาดจุดจอง และเพิ่มบล็อกในผัง
- สลิปจำลอง: ใช้ชื่อธนาคาร ชื่อบัญชี เลขบัญชี และไฟล์รูปตัวอย่าง ส่งสลิปแล้วลองผลผ่านและไม่ผ่าน ตรวจบัตร QR หลังยืนยัน
- Superadmin: ดูภาพรวมร้านตัวอย่างสองร้าน ส่วนการจัดการสิทธิ์ระดับแพลตฟอร์มเป็นงาน Phase 2

## โครงสร้าง

- `assets/css/app.css` — สไตล์จากต้นแบบและการจัดเมนูเพิ่มบนมือถือ
- `src/app.js` — เริ่มแอปและผูกเหตุการณ์กับหน้า
- `src/features/` — หน้าและขั้นตอนการจอง จัดการร้าน จัดการผัง ดูภาพรวมร้าน และชำระจำลอง
- `src/data/` — ข้อมูลตัวอย่าง ตัวจัดเก็บในเบราว์เซอร์ และตัวอ่าน Supabase แบบรับ client จากผู้เรียก
- `supabase/` — migration, การตั้งค่า seed และข้อมูลสมมติสองร้าน ครบห้าแม่แบบ

## GitHub Pages

หลังรีวิวและ merge ให้เลือก **Settings → Pages → Deploy from a branch → main → /(root)** หน้าเว็บใช้พาธสัมพัทธ์ จึงเปิดได้ใต้ `/reserveflow-saas/` โดยไม่มีขั้นตอน build ตั้งค่า Pages เมื่อพร้อมเปิดเดโมสาธารณะ

## Supabase สำหรับ Phase 2

ใช้ Supabase CLI และ Docker เพื่อทดลองกับสภาพแวดล้อม local จากรากของ repository รัน `supabase start` ซึ่งจะใช้ migration และ seed ในโปรเจกต์นี้ สำหรับฐาน local ที่รันอยู่แล้ว ให้ใช้ `supabase db reset --local` เฉพาะเมื่อต้องการทิ้งข้อมูลทดสอบเดิมทั้งหมด

1. สร้าง Supabase โปรเจกต์ทดสอบเฉพาะ ReserveFlow และทดสอบ migration ก่อนเชื่อมหน้าเว็บ
2. ตั้ง URL และ publishable key สำหรับหน้าร้านใน `src/data/supabase-config.js` เว็บไซต์ static ไม่โหลดไฟล์ `.env` เก็บสิทธิ์ระดับเซิร์ฟเวอร์ไว้นอกโค้ดหน้าเว็บ
3. สร้างผู้ใช้ทดสอบสองคนผ่าน Auth แล้วกำหนด `shop_members` ให้แต่ละคนอยู่คนละร้านด้วยช่องทางแอดมินที่เชื่อถือได้ RLS ปัจจุบันอนุญาตให้สมาชิกอ่านข้อมูลร้านของตัวเองเท่านั้น ส่วน browser roles ยังเขียนข้อมูลไม่ได้ และ anonymous access ถูกปิดไว้
4. เพิ่มการล็อกอินร้าน การยืนยันสิทธิ์ของลูกค้า การเปิดแค็ตตาล็อกแบบจำกัดข้อมูล และคำสั่งสร้างการจองที่คำนวณราคา ตรวจความจุ และตรวจการเปลี่ยนสถานะฝั่งเซิร์ฟเวอร์ Migration มีข้อบังคับป้องกันช่วงเวลาซ้อนของทรัพยากรเดียวกันภายในร้าน ส่วนโซนบัตรที่ต้องรองรับจำนวนคงเหลือร่วมกันต้องกำหนดกติกาสต็อกเพิ่ม
5. เพิ่มสิทธิ์ Superadmin ฝั่งเซิร์ฟเวอร์และ Storage สำหรับภาพผังและหลักฐานจำลอง QR ปัจจุบันใช้เลขอ้างอิงเดโม ส่วนการตรวจบัตรจริงต้องเพิ่มการตรวจสอบฝั่งเซิร์ฟเวอร์ การรับเงินจริงและ LINE API อยู่นอกขอบเขต Phase 1

## Merchant Portal (Phase 2)

เปิด `merchant.html` หรือเลือกลิงก์เข้าสู่ระบบร้านค้าจากหน้าเดโม
ระบบใช้ Supabase JS 2.98.0 จาก `assets/vendor/supabase-js/` และ publishable key
ของโปรเจกต์ ReserveFlow ใน `src/data/supabase-config.js`
บัญชีต้องมีแถวใน `shop_members` ก่อนอ่านร้านและรายการจองผ่าน RLS
เซสชัน LINE อยู่ใน sessionStorage ของแท็บ

การทดสอบกับฐานจริง ให้ล็อกอินด้วยบัญชี LINE ที่ผูกสิทธิ์กับ demo-one และ demo-two ทีละบัญชี
ตรวจว่าตัวเลือกร้านและรายการจองเป็นของร้านที่บัญชีเป็นสมาชิก แล้วออกจากระบบ
หน้าเดโมเดิมยังใช้ข้อมูลในเบราว์เซอร์

## ส่งคำขอจองจากหน้าลูกค้า (Phase 2)

ใช้ migration `supabase/migrations/20261119000001_customer_booking.sql` กับโปรเจกต์
ReserveFlow ที่ลง migration Phase 1 แล้ว ผ่าน SQL Editor หรือ Supabase CLI ตาม workflow ของโปรเจกต์
ไฟล์นี้เพิ่มการเปิดรับจองรายร้านและ RPC สองตัวสำหรับอ่านแค็ตตาล็อกและส่งคำขอจอง
โดยไม่ให้ผู้ไม่ล็อกอินอ่านหรือเขียนตารางโดยตรง หากรัน SQL Editor ด้วยตนเองและจะเปลี่ยนมาใช้
`supabase db push` ภายหลัง ให้ตรวจสถานะ migration history ก่อนเพื่อหลีกเลี่ยงการรันไฟล์ซ้ำ

หลัง migration สำเร็จ เปิดเฉพาะร้านเดโมที่ต้องการทดสอบในโปรเจกต์ ReserveFlow:

```sql
update public.shops
set public_booking_enabled = true
where slug = 'demo-one'
returning slug, public_booking_enabled;
```

เปิด `book.html?shop=demo-one` เลือกรอบอนาคตที่ยังว่าง แล้วส่งด้วยข้อมูลสมมติ
เมื่อสำเร็จจะแสดงเลขจอง ยอดที่ฐานข้อมูลคำนวณ และสถานะรอร้านยืนยัน
ตรวจผลโดยล็อกอิน `merchant.html` ด้วยบัญชีของร้าน DEMO แล้วลองส่งอีกครั้งด้วยเลขคำขอใหม่
สำหรับรายการและช่วงเวลาเดิมเพื่อทดสอบว่าฐานข้อมูลปฏิเสธการจองทับ

รัน `supabase/migrations/20261119000002_half_hour_booking_slots.sql` ก่อนเผยแพร่หน้าเว็บรุ่นนี้
รอบเริ่มใช้ 10:00 ถึง 22:00 ทุก 30 นาที ตามเขตเวลาของร้าน โต๊ะและบัตรจองเป็นรอบสองชั่วโมง
ส่วนพนักงาน ห้อง และที่นั่งเลือกระยะเวลาได้ โซนบัตรจองแบบหนึ่งคำขอต่อรอบ ยังไม่มีสต็อกบัตรร่วม
หลังบ้านจัดการสถานะการจองโต๊ะได้ตามหัวข้อด้านล่าง คำขอยังไม่มีระบบหมดอายุอัตโนมัติ
ก่อนเปิดรับจองสาธารณะ ให้เพิ่มการป้องกันสแปมที่ตรวจสอบได้ เพราะโควตาต่อเบอร์โทรเป็นเพียงข้อจำกัดเบื้องต้น
ปิดหน้ารับจองของร้านได้โดยเปลี่ยน `public_booking_enabled` เป็น `false`

### จัดการการจองโต๊ะในหลังบ้าน

รัน `supabase/migrations/20261119000003_merchant_table_bookings.sql` หลัง migration รอบเวลา
30 นาทีและก่อนเปิดหน้าเว็บรุ่นนี้ ผู้มีบทบาท owner หรือ admin จองโต๊ะให้ร้านที่ตนเป็นสมาชิกได้
โดยเลือก **ตอนนี้** สำหรับลูกค้าหน้าร้าน หรือ **จองล่วงหน้า** สำหรับวันและรอบเวลาที่เลือก
ฐานข้อมูลตรวจความจุ คิดราคา และปฏิเสธช่วงเวลาซ้อนจากทั้งสองช่องทาง

ในรายการจองโต๊ะ ให้กด **ยืนยันการจอง** สำหรับคำขอในอนาคตที่รอยืนยัน
กด **ใช้งานเสร็จ · คืนโต๊ะ** หลังเริ่มใช้โต๊ะ หรือกด **ยกเลิกการจอง** เพื่อคืนโต๊ะ
ทั้งสองสถานะเก็บรายการเดิมไว้และคืนช่วงเวลาให้จองได้อีกครั้ง

### ผังโต๊ะลูกค้าและ LINE Login หลังบ้าน

รัน `supabase/migrations/20261119000004_public_table_plan.sql` เพื่อเปิด RPC ผังโต๊ะ
หน้าจองใช้ตำแหน่งจาก `resources.display` และขนาดกับองค์ประกอบผังจาก `layouts`
พร้อมสถานะว่างตามวันที่และเวลา RPC ส่งเพียงข้อมูลผังและสถานะโต๊ะสำหรับร้านที่เปิดรับจอง
ภาพพื้นหลังจาก Storage และการบันทึกผังจากตัวแก้ผังเดโมยังไม่ได้เชื่อมในขั้นนี้

ตั้งค่า LINE Login ก่อนเผยแพร่หน้าหลังบ้านรุ่นนี้:

1. ใน LINE Developers Console สร้างหรือใช้ LINE Login channel ของ ReserveFlow
   เปิด Web app และเพิ่ม Callback URL
   `https://zotgxsimkrofqxkhjjak.supabase.co/auth/v1/callback`
2. ใช้ Supabase Auth Admin API สร้าง Custom Provider ชนิด OAuth2 ด้วย identifier `custom:line-manual`
   ใส่ LINE Channel ID และ Channel Secret ฝั่ง Supabase ตั้ง scopes เป็น `openid profile`
   และเปิด `email_optional` ใช้ปลายทางดังนี้
   - Authorization URL `https://access.line.me/oauth2/v2.1/authorize`
   - Token URL `https://api.line.me/oauth2/v2.1/token`
   - UserInfo URL `https://api.line.me/oauth2/v2.1/userinfo`

   โปรเจกต์นี้ใช้ OAuth2 เพื่ออ่านโปรไฟล์จาก LINE UserInfo เพราะการทดสอบ OIDC
   ของช่อง LINE เดิมถูก Supabase ปฏิเสธด้วยอัลกอริทึมลายเซ็น HS256
3. ใน Supabase Authentication → URL Configuration เพิ่ม Redirect URL
   `https://homefriendmassage-boop.github.io/reserveflow-saas/merchant.html`
4. ให้แอดมินล็อกอิน LINE ครั้งแรกเพื่อให้ Supabase สร้างหรือเชื่อมบัญชี Auth
   ตรวจ UID จาก Authentication → Users แล้วผูก UID ที่ยืนยันแล้วกับร้านใน `shop_members`
   บทบาท `owner` หรือ `admin` จึงเห็นร้านและจัดการรายการได้ อีเมลเก่าอาจมี UID คนละตัวกับ LINE
5. ทดสอบด้วย LINE ของแอดมินที่ผูกไว้และอีกบัญชีที่ไม่มีสมาชิกในร้าน
   รักษา Channel Secret ไว้เฉพาะใน Supabase

### สิทธิ์หลังบ้านและ LIFF

รัน `supabase/migrations/20261119000005_merchant_roles.sql` ก่อนเผยแพร่หน้านี้
หลังบ้านตรวจสิทธิ์จาก `shop_members` ของร้านทั้งใน UI และในคำสั่งเขียนที่ฐานข้อมูล

- เจ้าของร้านตั้งชื่อ เปิดหรือปิดการรับจอง กำหนดหรือนำสิทธิ์ทีมงานออก และจัดการโต๊ะได้
- แคชเชียร์จัดการการจองโต๊ะ ยืนยัน ยกเลิก คืนโต๊ะ และปรับพิกัดโต๊ะบนผังได้
  สมาชิกบทบาท admin ที่มีอยู่ใช้สิทธิ์จัดการโต๊ะเช่นเดียวกับ cashier
- พนักงานค้นหารายการด้วยเลขจองหรือรหัสรายการ และเช็กอินรายการที่ยืนยันแล้วได้
  ตั้งแต่ 30 นาทีก่อนเริ่มจนถึงก่อนหมดเวลาจอง

ให้ทีมงานเข้าสู่ระบบเพื่อสร้างบัญชี Auth แล้วนำ User UID ที่ตรวจสอบแล้วไปกำหนดสิทธิ์ในเมนูตั้งค่าร้าน
หน้าเว็บมีอีเมลสำหรับบัญชีเดิมระหว่างตั้งค่า LINE และตรวจสิทธิ์รายร้านทั้งสองวิธี

ใส่ URL หน้าจองของร้านในช่อง **Endpoint URL** ของ LINE LIFF เช่น
`https://homefriendmassage-boop.github.io/reserveflow-saas/book.html?shop=demo-one`
ลิงก์ `https://liff.line.me/...` ที่ LINE สร้างให้ใช้ส่งให้ลูกค้าหรือใส่ Rich Menu
ก่อนส่งให้ลูกค้า ให้เปิด LINE Developers → LINE Login Channel → Basic settings แล้วเปลี่ยนสถานะ Developing เป็น Published ด้วยบัญชี Admin ของ Channel
ตัวอย่าง LIFF ของร้าน DEMO คือ `https://liff.line.me/2012709644-JfBNY79l`
หน้าจองแสดงผังและข้อมูลผู้จองในหน้าเดียว บนมือถือฟอร์มอยู่ถัดจากผัง
หน้าจองใช้งานเป็นเว็บปกติใน LIFF และไม่อ่านโปรไฟล์ LINE ของลูกค้า

### ตั้งค่าหมวดและออกแบบผังบนหลังบ้านจริง

รัน `supabase/migrations/20261119000006_merchant_settings.sql` ก่อนเผยแพร่
เจ้าของร้านเพิ่มหรือแก้หมวด ตั้งราคา ค่าบริการ ลำดับ และการแสดงผลได้
ใช้ซ่อนหมวดเมื่อหยุดรับจอง เพื่อเก็บข้อมูลอ้างอิงของการจองเก่า
เจ้าของและแคชเชียร์จัดผังโต๊ะหรือที่นั่ง เลือกขนาดกรอบ ใช้เทมเพลตตาราง
เพิ่มบล็อก ลาก คัดลอก และแก้ชื่อ ขนาด หรือความจุของจุดจองได้
การลากหรือแก้พิกัดจะมีผลหลังจากกดบันทึกจุดจอง ส่วนบล็อกจะมีผลเมื่อบันทึกผัง
หมวดที่เพิ่งเพิ่มต้องมีทรัพยากรก่อนจึงรับจองได้ ตัวแก้ผังรองรับทรัพยากรแบบโต๊ะและที่นั่ง
รัน `supabase/migrations/20261120000009_public_seat_plan.sql` เพื่อแสดงผังที่นั่งและตรวจรอบตามจำนวนชั่วโมง
หน้าจองแสดงผังโต๊ะและที่นั่งจากทรัพยากรที่บันทึกใน Supabase การชำระเงินจริงและอัปโหลดภาพพื้นหลังยังไม่เปิดใช้

หากต้องการทดสอบด้วยโต๊ะตัวอย่างเพิ่ม ให้รัน `supabase/demo_floor.sql` เพื่อเติม T02–T06
เข้า `demo-one` โดยรักษาโต๊ะที่มีอยู่และข้อมูลการจองเดิม

### สมัครร้านใหม่

ใช้ migration `supabase/migrations/20261119000007_shop_registration.sql` ก่อนเผยแพร่
ร้านใหม่เปิด `merchant.html` และล็อกอินด้วย LINE บัญชีที่ยังไม่มีร้านจะเห็นฟอร์มสมัคร
ระบบสร้างร้าน หมวดโต๊ะ โต๊ะตัวอย่าง และสิทธิ์เจ้าของให้ในธุรกรรมเดียว การรับจองออนไลน์ปิดเป็นค่าเริ่มต้น
เจ้าของจัดผัง ตั้งราคา แล้วเปิดรับจองจากเมนูตั้งค่าร้านก่อนแชร์ลิงก์ในปุ่มดูหน้าจองของร้านนี้
สมาชิกทีมงานใช้ UID จากหน้าสมัครให้เจ้าของร้านผูกสิทธิ์แทนการสร้างร้าน

`index.html` เปิดหน้าจองจริง โดยใช้ `demo-one` เป็นตัวอย่างเมื่อไม่ได้ระบุชื่อร้าน
ลิงก์เก่า `booking-platform-demo.html` เปิดหน้าจองจริงเช่นกันและรักษาค่า `shop` ที่อยู่ใน URL
หน้าจองจริงใช้ลำดับหมวดที่บันทึกจากหลังบ้านและเลือกหมวดแรกที่เปิดแสดงเมื่อเปิดหน้า

### รายชื่อทีมงานและคำขอเข้าร้าน

รัน `supabase/migrations/20261119000008_merchant_team_requests.sql` หลัง migration สมัครร้าน
ทีมงานล็อกอินด้วย LINE จากหลังบ้าน แล้วเลือก **ขอเข้าร้านในฐานะทีมงาน** จากหน้าที่แสดง
สำหรับบัญชีที่ยังไม่มีร้าน ใส่ลิงก์จองหรือรหัสร้านและชื่อที่เจ้าของรู้จัก
เจ้าของเปิด **ตั้งค่าร้าน → กำหนดสิทธิ์ทีมงาน** ค้นหาชื่อหรือ UID แล้วอนุมัติเป็นพนักงานหรือแคชเชียร์
คอยเทียบชื่อและ UID กับบัญชีที่ทีมงานยืนยัน เนื่องจากชื่อแสดงตั้งซ้ำกันได้
รายชื่อเดิมและคำขอแสดงเฉพาะเจ้าของร้าน และคำขอไม่ให้สิทธิ์จนกว่าเจ้าของจะอนุมัติ

### Superadmin and LINE notifications

Apply `20261120000010_superadmin_line_notifications.sql` after the booking migrations. The LINE login account with Supabase Auth UID `70900f9a-8a21-425f-95ba-ddac9b4e4612` gets the Superadmin panel in `merchant.html` if that account exists when the migration runs.

1. In Supabase Edge Function Secrets, set `LINE_CHANNEL_SECRET` and `LINE_CHANNEL_ACCESS_TOKEN` from the LINE Official Account's **Messaging API** channel. Set `LINE_WORKER_SECRET` to a separate strong random value.
2. Deploy `line-webhook` and `line-notification-worker` from this repository using `supabase functions deploy <function> --project-ref zotgxsimkrofqxkhjjak --no-verify-jwt`. The functions check their own credentials.
3. In LINE Developers, set the Messaging API webhook URL to `https://zotgxsimkrofqxkhjjak.supabase.co/functions/v1/line-webhook` and enable **Use webhook**. Enable group joins for group notifications. If the channel already serves another app's webhook, integrate the handlers or use a dedicated Official Account.
4. Enable Supabase Cron and `pg_net`. In Supabase Vault, create `reserveflow_line_worker_secret` with the same value as `LINE_WORKER_SECRET`. Schedule the worker in the SQL Editor.

```sql
select cron.schedule('reserveflow-line-notify','* * * * *',$$
  select net.http_post(
    url := 'https://zotgxsimkrofqxkhjjak.supabase.co/functions/v1/line-notification-worker',
    headers := jsonb_build_object('Content-Type','application/json','x-rf-worker-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'reserveflow_line_worker_secret')),
    body := '{}'::jsonb
  );
$$);
```

5. In Superadmin, generate a pairing code and send it in a private chat with the Official Account. Shop owners can generate a code under shop settings and send it to the Official Account or in a LINE group the Official Account has joined. Generate a fresh code for each destination and refresh the destination list after sending.

New registrations send a Flex message to the Superadmin destination. New bookings send a text message to the destinations linked to the booking's shop. Test with a fresh registration and booking after pairing.

### ตรวจสลิปด้วย Thunder v2

1. รัน migration `20261120000017_thunder_booking_decisions.sql` หลังไฟล์ 15 และ 16
2. ตั้ง Edge Function Secret ชื่อ `THUNDER_API_KEY` ใน Supabase
3. เผยแพร่ฟังก์ชันใหม่ด้วย `supabase functions deploy thunder-verify-slip --project-ref zotgxsimkrofqxkhjjak --no-verify-jwt`
4. ตั้งเบอร์มือถือพร้อมเพย์ของร้านในหลังบ้าน แล้วทดสอบด้วยการจองใหม่และแนบสลิปจริง

เมื่อส่งรูปสลิป ระบบอ่าน QR จากรูป JPG หรือ PNG ที่แนบและส่งเฉพาะ QR payload ไปที่ [Thunder v2](https://document.thunder.in.th/th/) กรณียอดไม่ตรง ระบบเก็บผลไว้ให้แอดมินตรวจและยืนยันเอง ตรวจซ้ำได้จาก **รายการจอง → ดูสลิปที่แนบ → ตรวจสลิปด้วย Thunder**

การยืนยันอัตโนมัติต้องได้ยอดที่ตรง เลขอ้างอิงที่ยังไม่ใช้ เวลาโอนหลังสร้างการจอง และข้อมูลมือถือผู้รับแบบเต็มที่ตรงกับพร้อมเพย์ของร้าน ฟังก์ชันอ่านข้อมูลผู้รับจาก `receiver.account.proxy` ชนิด `MSISDN` และเวลาโอนจาก `date` ที่ระบุเขตเวลา หาก Thunder ส่งเฉพาะชื่อผู้รับหรือเบอร์ที่ปิดบางหลัก ระบบส่งให้แอดมินตรวจ รูป WebP เก็บเป็นหลักฐานให้แอดมินเปิดดูได้

### สมัครร้าน แพ็กเกจ และค่าแนะนำ

รัน SQL ไฟล์ 19 หลังไฟล์ 10 และ 18 จากนั้น Superadmin เปิด **ราคาแพ็กเกจ ตรวจสลิป และค่าแนะนำ** เพื่อตั้งเบอร์พร้อมเพย์ของแพลตฟอร์ม ราคาต่อรอบ และเปอร์เซ็นต์ค่าแนะนำ แพ็กเกจที่ยังเว้นราคาไว้จะไม่เปิดชำระ ร้านเดิมใช้งานต่อได้และเริ่มนับอายุเมื่อชำระแพ็กเกจครั้งแรก ร้านใหม่ได้ทดลอง 7 วัน เมื่อหมดอายุหน้าจองสาธารณะจะปิดและเจ้าของยังเข้าหลังบ้านเพื่อต่ออายุได้

ใบสมัครอยู่ใน **Superadmin → สมัครร้านใหม่และแชร์ใบสมัคร** เจ้าของร้านเปิด **แชร์แนะนำร้านค้า** เพื่อคัดลอกลิงก์หรือสร้าง QR ที่ผูกร้านผู้แนะนำไว้ การส่ง Flex ใช้ปลายทาง LINE ที่เชื่อมไว้และส่งต่อจากแชตได้

เผยแพร่ Edge Functions `line-notification-worker` และ `thunder-verify-slip` เวอร์ชันล่าสุดเพื่อส่ง Flex และตรวจสลิปแพ็กเกจตามลำดับ ระบบใช้ Secret เดิม Superadmin ต้องอนุมัติสลิปแพ็กเกจเพื่อเพิ่มอายุและบันทึกยอดค่าแนะนำ เมื่อโอนค่าแนะนำแล้วสามารถกดบันทึกว่าจ่ายแล้ว

### รายงานประจำวันและ Flex เข้ากลุ่ม LINE

รัน SQL ไฟล์ 20 หลังไฟล์ 19 และเผยแพร่ Edge Function `line-notification-worker` เวอร์ชันล่าสุด เจ้าของร้านและแคชเชียร์เปิด **รายงานประจำวัน** จากหลังบ้านเพื่อเลือกวันที่และส่ง Flex ไปยังกลุ่ม LINE ที่เชื่อมไว้ผ่าน **ตั้งค่าร้าน → แจ้งเตือนผ่าน LINE** การกดส่งจะเข้าคิวตามรอบตัวส่ง LINE ที่ตั้งไว้

ยอดจองแยกตามวันใช้บริการและนับยอดเฉพาะสถานะยืนยันแล้ว เช็กอินแล้ว หรือเสร็จสิ้น ส่วนยอดรับนับตามเวลาโอนที่ยืนยันได้จาก Thunder หลังติดตั้งไฟล์ 20 รายการเงินสด การอนุมัติด้วยมือ และสลิปเดิมที่ไม่มีเวลาโอนที่บันทึกไว้ต้องนำมาลงบัญชีเพิ่มเติม

### LINE OA แยกตามร้าน

รัน SQL ไฟล์ 21 หลังเปิด Vault และติดตั้งรายงาน แล้วเผยแพร่ `line-webhook` และ `line-notification-worker` เวอร์ชันล่าสุด ทั้งสองไฟล์คัดลอกไปวางใน Supabase Dashboard Editor ได้โดยตรงและใช้การตรวจลายเซ็นหรือ Secret ของระบบ จึงปิด Verify JWT with legacy secret ตามการติดตั้งเดิม รหัส Cron และ URL ของ worker ใช้ค่าเดิม

เจ้าของร้านเปิด **ตั้งค่าร้าน → แจ้งเตือนผ่าน LINE** แล้วกรอก Channel secret และ Channel access token จาก Messaging API ของ OA ร้านตัวเอง ระบบตรวจ Token กับ LINE และเก็บข้อมูลลับใน Vault ให้นำ Webhook URL ที่มี `?shop=...` จากหน้าตั้งค่าไปวางใน LINE Developers ของ OA ร้าน กด Verify และเชื่อมปลายทางใหม่ด้วย RF จากร้านนั้น

การแจ้งจอง รายงาน และใบสมัครแนะนำของร้านส่งด้วย Token ของร้าน การแจ้งเตือน Superadmin ไปทาง OA ของแพลตฟอร์มตามเดิม ปลายทางเก่าที่เชื่อมกับ OA กลางจะไม่ถูกนำไปใช้กับ OA ร้านจนกว่าจะเชื่อมใหม่
