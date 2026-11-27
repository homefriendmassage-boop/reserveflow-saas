# โปรโมชั่นตกกุ้ง / QR ใช้ได้ครั้งเดียว (PR รอตรวจ)

## เพิ่มเข้ามาใน Branch นี้
- `promotion-manager.html` — แอดมิน owner/admin สร้างแพ็กเกจลดราคา หรือแพ็กเกจราคาปกติพร้อมเครื่องดื่ม/อาหาร
- `promotion-redeem.html` — พนักงานตรวจคูปองผ่าน QR หรือวางรหัส ก่อนกดยืนยันรับสิทธิ์
- `rf_promotion_offers`, `rf_promotion_vouchers`, `rf_promotion_events` — เก็บแพ็กเกจ, token แบบ UUID, สถานะและคิว LINE
- `rf_redeem_promotion_voucher` — บันทึกใช้สิทธิ์แบบล็อกแถว ป้องกันกดยืนยันซ้ำพร้อมกันจากหลายเครื่อง
- `promotion-qr` — สร้าง QR PNG แบบไม่เปิดเผยข้อมูลลูกค้า เมื่อใช้หรือหมดอายุจะตอบ 410
- `promotion-line-worker` — ส่ง Flex แสดงภาพ QR ตอนออกคูปองและส่ง Flex อีกครั้งเมื่อพนักงานยืนยันสิทธิ์ พร้อม retry ตามคิว

## โปรเริ่มต้นที่แนะนำ
| ระยะเวลา | ปกติ | โปรลดราคา | ตัวเลือกจ่ายเต็ม + ของแถม |
| --- | ---: | ---: | --- |
| 1 ชม. | 120 | 120 | ไม่มี |
| 2 ชม. | 240 | 220 | น้ำดื่ม 1 ขวด |
| 3 ชม. | 360 | 300 | เครื่องดื่ม <= 40 บาท |
| 4 ชม. | 480 | 380 | ของทานเล่น <= 59 บาท |
| 5 ชม. | 600 | 450 | อาหาร <= 89 บาท |

**ห้ามใช้ทั้งส่วนลดและของแถมพร้อมกัน** เว้นแต่ร้านกำหนดเป็นแพ็กเกจเฉพาะ กติกาออกคูปองต้องอ้างอิงแพ็กเกจที่ลูกค้าเลือกจริง

## จุดที่ยังต้องเชื่อมก่อนเปิดจริง (สำคัญ)
1. ฝั่งลูกค้าเลือก `offer_id` และฝั่งเซิร์ฟเวอร์คำนวณราคาโปรใหม่ ณ เวลาจอง ไม่เชื่อราคาจากเบราว์เซอร์
2. บันทึก `offer_id` กับ Booking และเมื่อสลิปตรวจผ่าน / สถานะชำระยืนยันแล้ว ให้ Edge Function ที่เชื่อถือได้เรียก `rf_issue_promotion_voucher(booking_id,offer_id,verified_line_user_id,expiry)` เฉพาะสิทธิ์ของแถม; **โปรลดราคาไม่ต้องออก QR สำหรับรับของแถม**
3. LINE UID ต้องได้รับจากการยืนยัน LIFF ID token ของ OA ที่จะส่ง Flex และผู้ใช้ต้องเป็นเพื่อน OA นั้น บัญชี OA ร้านต่างกันไม่สามารถใช้ LINE UID และ Channel Access Token ข้าม Channel โดยสมมติได้
4. Worker ใน PR นี้ใช้ `LINE_CHANNEL_ACCESS_TOKEN` ส่วนกลาง **ยังไม่รองรับการเลือก OA แยกร้าน** (ระบบหลักมี OA แยกร้านอยู่แล้ว ควรนำกลไกเดิมมาใช้)
5. ต้องเปิดสาธารณะเฉพาะ `promotion-qr` ที่ return รูป QR ไม่เปิดข้อมูลลูกค้า; `promotion-line-worker` ต้องมี Header Secret และทำงานจาก Cron เท่านั้น
6. วางแผนวันหมดอายุและการยกเลิก Booking: ยกเลิก Booking แล้วต้อง void คูปองที่ยังไม่ใช้
7. Deploy migrations และ functions ใน **Project ReserveFlow เท่านั้น** หลังสำรองข้อมูล/ทดสอบบน staging

**สถานะงาน:** ยังไม่ deploy, ยังไม่เชื่อมการออกคูปองอัตโนมัติจากการชำระเงิน, ยังไม่ทดสอบ LINE Push จริง, จึงห้ามเปิด PR นี้เป็นระบบ Production จนกว่าจะปิดงานค้าง

## แนวทางทดสอบ
1. ทดสอบ SQL migration บน Supabase local/staging ที่มี schema ฐาน `shops`, `shop_members`, `bookings`
2. owner สร้าง Offer ผ่าน Promotion Manager; staff ไม่สามารถแก้ Offer แต่ preview/redeem ได้
3. สร้าง booking ที่ยืนยันแล้วจริงและเลือก offer ของแถม; เรียก issuance ด้วย service role จาก Edge Function (ห้ามนำ service key ลงเว็บ)
4. ใช้ LINE ที่ผูกกับ OA เดียวกัน ทดสอบ worker กับ Test OA; ตรวจ Flex และ QR
5. เปิดสแกนสองเครื่องพร้อมกัน กดยืนยันพร้อมกัน: อนุญาตสำเร็จได้ 1 ครั้งเท่านั้น
6. scan ซ้ำ: แสดง Already redeemed และไม่แจ้ง LINE ซ้ำ
7. ตรวจ QR หมดอายุ, บัตรของร้านอื่น, พนักงานไม่มีสิทธิ์, ยกเลิก/คืนเงิน และ LINE worker retry
8. ตรวจว่า event ที่ถูกส่งแล้วมีเพียง 1 รายการต่อ voucher+kind และทดสอบ rate limit/Spam protection ก่อนเผยแพร่

## การตั้งค่า (เมื่อพร้อม Deploy)
- Functions: `promotion-qr` และ `promotion-line-worker` (ดู `supabase/config.toml`)
- Secrets: `PROMOTION_WORKER_SECRET` (สุ่มใหม่ยาว) และ `LINE_CHANNEL_ACCESS_TOKEN` ของ **OA ที่ระบุตัวตนลูกค้าได้จริง**
- Worker schedule: ส่ง POST ไป `/functions/v1/promotion-line-worker` พร้อม header `x-promotion-worker-secret` ผ่าน Supabase Cron+Vault; เก็บ secret ใน Vault ไม่เขียนลง SQL migration หรือ GitHub
- ห้ามเรียก Worker จาก Browser และห้ามใช้ client service_role
