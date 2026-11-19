const STATUS_LABEL={
  pending_payment:'จองรอชำระ',
  slip_review:'รอตรวจสลิป',
  pending_confirm:'รอลูกค้าคอนเฟิร์ม',
  confirmed:'จองแล้ว',
  checked_in:'เช็กอินแล้ว',
  completed:'เสร็จสิ้น',
  cancelled:'ยกเลิก'
};

const TEMPLATE_META={
  table:{icon:'🍽️',title:'เลือกโต๊ะจากผังร้าน',desc:'เลือกโต๊ะตามจำนวนผู้ใช้บริการและช่วงเวลาที่ต้องการ',unit:'ผู้ใช้บริการ'},
  staff:{icon:'👩‍💼',title:'เลือกพนักงานผู้ให้บริการ',desc:'เลือกพนักงานและระยะเวลาที่ต้องการจอง',unit:'ชั่วโมง'},
  vip:{icon:'🚪',title:'เลือกห้อง VIP',desc:'เลือกห้อง VIP พร้อมจำนวนผู้ใช้บริการและจำนวนชั่วโมง',unit:'ชั่วโมง'},
  seat:{icon:'💺',title:'เลือกที่นั่งจากผัง',desc:'เหมาะกับการจองที่นั่งรายชั่วโมงหรือรอบเวลา',unit:'ชั่วโมง'},
  ticket:{icon:'🎫',title:'เลือกประเภทบัตร',desc:'เลือกโซนบัตรและจำนวนบัตรที่ต้องการจอง',unit:'บัตร'}
};

const DEFAULT_CONFIG={
  shop:{name:'ร้าน DEMO',tenantId:'SHOP_DEMO',bankName:'',bankOwner:'',bankNumber:'',promptpayId:'',plan:'Trial'},
  layoutImages:{},
  layoutDecor:{},
  layoutSizes:{},
  categories:[
    {id:'table',name:'จองโต๊ะ',template:'table',visible:true,price:200,serviceFee:0,paymentMode:'deposit',defaultStatus:'pending_payment'},
    {id:'staff',name:'จองพนักงาน',template:'staff',visible:true,price:500,serviceFee:50,paymentMode:'full',defaultStatus:'pending_confirm'},
    {id:'vip',name:'จองห้อง',template:'vip',visible:true,price:1500,serviceFee:100,paymentMode:'deposit',defaultStatus:'pending_payment'},
    {id:'seat',name:'จองที่นั่ง',template:'seat',visible:true,price:150,serviceFee:0,paymentMode:'full',defaultStatus:'pending_confirm'},
    {id:'ticket',name:'จองบัตร',template:'ticket',visible:true,price:900,serviceFee:20,paymentMode:'full',defaultStatus:'pending_payment'}
  ],
  resources:{
    table:[
      {id:'T01',name:'โต๊ะ T01',capacity:2,desc:'ริมหน้าต่าง',x:19,y:25},
      {id:'T02',name:'โต๊ะ T02',capacity:4,desc:'กลางร้าน',x:50,y:30},
      {id:'T03',name:'โต๊ะ T03',capacity:4,desc:'ริมสวน',x:81,y:25},
      {id:'T04',name:'โต๊ะ T04',capacity:6,desc:'โซนครอบครัว',x:19,y:62},
      {id:'T05',name:'โต๊ะ T05',capacity:6,desc:'ใกล้เวที',x:50,y:63},
      {id:'T06',name:'โต๊ะ T06',capacity:8,desc:'โต๊ะใหญ่',x:81,y:62}
    ],
    staff:[
      {id:'S01',name:'คุณมายด์',desc:'พนักงานดูแลส่วนตัว',icon:'👩🏻‍💼',photo:''},
      {id:'S02',name:'คุณน้ำ',desc:'พนักงานบริการลูกค้า VIP',icon:'👩🏽‍💼',photo:''},
      {id:'S03',name:'คุณต้น',desc:'ผู้ช่วยส่วนตัว / เทรนเนอร์',icon:'👨🏻‍💼',photo:''},
      {id:'S04',name:'คุณฟ้า',desc:'พนักงานบริการเฉพาะบุคคล',icon:'👩🏼‍💼',photo:''}
    ],
    vip:[
      {id:'V01',name:'ห้อง VIP A',capacity:4,desc:'ห้องส่วนตัวขนาดเล็ก',icon:'🚪'},
      {id:'V02',name:'ห้อง VIP B',capacity:8,desc:'ห้องคาราโอเกะ',icon:'🎤'},
      {id:'V03',name:'ห้อง VIP C',capacity:10,desc:'ห้องประชุม/จัดเลี้ยง',icon:'✨'}
    ],
    seat:[
      {id:'A01',name:'ที่นั่ง A01',desc:'ติดทางเข้า',x:18,y:24},
      {id:'A02',name:'ที่นั่ง A02',desc:'มุมซ้าย',x:38,y:24},
      {id:'A03',name:'ที่นั่ง A03',desc:'กลางแถวหน้า',x:58,y:24},
      {id:'A04',name:'ที่นั่ง A04',desc:'มุมขวา',x:78,y:24},
      {id:'B01',name:'ที่นั่ง B01',desc:'แถวกลางซ้าย',x:18,y:58},
      {id:'B02',name:'ที่นั่ง B02',desc:'แถวกลาง',x:38,y:58},
      {id:'B03',name:'ที่นั่ง B03',desc:'แถวกลางขวา',x:58,y:58},
      {id:'B04',name:'ที่นั่ง B04',desc:'ใกล้ทางออก',x:78,y:58}
    ],
    ticket:[
      {id:'E01',name:'โซน General',desc:'บัตรยืน / ต่อใบ',icon:'🎵'},
      {id:'E02',name:'โซน Seating',desc:'บัตรนั่ง / ต่อใบ',icon:'💺'},
      {id:'E03',name:'โซน VIP',desc:'บัตร VIP / ต่อใบ',icon:'⭐'}
    ]
  }
};
