# คู่มือผู้ใช้ hibiki

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | **ภาษาไทย** | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> คู่มือภาษาจีนตัวย่อโฮสต์อยู่บน Feishu (ลิงก์ด้านบน) ส่วนคู่มือภาษาอังกฤษมีให้ [บน GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md) ด้วย

## บทนำ

นี่คือซอฟต์แวร์ฟรีสำหรับ Android / Windows (วางแผนรองรับ iOS / macOS) — แอปโอเพนซอร์สข้ามแพลตฟอร์มที่ก้าวล้ำ ซึ่งรวมการอ่านนิยาย การเล่นหนังสือเสียง การเล่นวิดีโอ และการค้นหาในพจนานุกรมไว้ด้วยกัน

### URL ของโปรเจกต์

https://github.com/hajisensai/hibiki

อยู่ระหว่างการพัฒนาอย่างต่อเนื่อง — ความคิดเห็นของคุณจะได้รับการดำเนินการอย่างรวดเร็ว ยินดีรับรายงานข้อบกพร่องและคำขอฟีเจอร์ หากคุณเห็นว่า Hibiki มีประโยชน์ เราจะขอบคุณมากหากคุณแบ่งปันให้ผู้อื่นหรือกดดาว ⭐ ให้กับที่เก็บโค้ด

### ดาวน์โหลด

https://github.com/hajisensai/hibiki/releases/latest

Android: เลือก **arm64** Windows: เลือกไฟล์ **.exe**

## บทแนะนำการตั้งค่า

### 1. นำเข้าพจนานุกรมที่แนะนำและไฟล์เสียงในเครื่อง (ไม่บังคับ)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

ในแอป: การตั้งค่า -> ซิงค์และสำรองข้อมูล -> แตะ **นำเข้าข้อมูลสำรอง**

**หมายเหตุ: การนำเข้าข้อมูลสำรองจะล้างข้อมูลในเครื่อง ขั้นตอนนี้จะได้รับการปรับปรุงในการอัปเดตครั้งต่อไป**

![หน้าจอนำเข้าข้อมูลสำรอง](static-assets/user-guide/import-backup.png)

### 2. ดาวน์โหลดและตั้งค่า Anki จากเว็บไซต์ทางการของ Anki

Anki — ตั้งชื่อตาม 暗記 (あんき) — เป็น [ระบบการทบทวนแบบเว้นช่วง (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) ที่ใช้กันแพร่หลายที่สุดในโลก และเป็นเครื่องมือที่สำคัญมาก

ลิงก์: [เว็บไซต์ทางการของ Anki](https://apps.ankiweb.net/) · [คู่มือ (จีน)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [คำถามที่พบบ่อย](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(จีน)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[รูปภาพ: ภาพประกอบ / คำอธิบาย]*

คุณสามารถป้อนเนื้อหาใดก็ตามที่ต้องการจดจำให้กับ Anki และมันจะช่วยให้คุณจดจำได้ดีที่สุดด้วยเวลาเรียนน้อยที่สุด

Anki มี [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) อยู่ในตัว — หนึ่งในอัลกอริทึมการทบทวนแบบเว้นช่วงที่ดีที่สุดในโลก

**แต่!!!** อัลกอริทึมเริ่มต้นของ Anki คือ SM2 ซึ่งเป็นอัลกอริทึมจากกว่า 30 ปีก่อนที่ทำงานได้ไม่ดี โปรดเปลี่ยนอัลกอริทึมที่ Anki ใช้เป็น **FSRS** ให้แน่ใจ

#### Anki

##### Android

1. ติดตั้งและเปิด Anki
2. กลับไปที่ hibiki ไปที่ การตั้งค่า -> การสร้างการ์ด
3. แตะ **รีเฟรชสำรับและประเภทโน้ต** (ทำเครื่องหมาย "1" ในรูป); hibiki จะขอสิทธิ์ — แตะ อนุญาต
4. แตะ **สร้างสำรับ Lapis** (ทำเครื่องหมาย "2" ในรูป)
5. หากไม่มีคำเตือนหรือข้อผิดพลาดสีแดง แสดงว่าการตั้งค่าสำเร็จ

![การตั้งค่า Anki บน Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. ติดตั้งและเปิด Anki
2. คลิก **เครื่องมือ (Tools)** ที่มุมบนซ้าย

![เมนูเครื่องมือของ Anki บน Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. วางโค้ดส่วนเสริมของ Anki ด้านล่างเพื่อติดตั้ง: `2055492159`
4. กลับไปที่ hibiki ไปที่ การตั้งค่า -> การสร้างการ์ด
5. แตะ **รีเฟรชสำรับและประเภทโน้ต** (ทำเครื่องหมาย "1")
6. แตะ **สร้างสำรับ Lapis** (ทำเครื่องหมาย "2")
7. หากไม่มีคำเตือนหรือข้อผิดพลาดสีแดง แสดงว่าการตั้งค่าสำเร็จ

![การตั้งค่า Anki บน Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. ลองดูตัวเลือกการตั้งค่าต่าง ๆ ในหน้าการตั้งค่า และดูว่ามีอะไรที่คุณอยากปรับหรือไม่ (ไม่บังคับ)

## กิตติกรรมประกาศ

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
