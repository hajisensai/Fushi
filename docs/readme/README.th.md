<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="โลโก้ hibiki" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | **ภาษาไทย** | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[คู่มือผู้ใช้](../user-guide.th.md) | [ดาวน์โหลดเวอร์ชันล่าสุด](https://github.com/hajisensai/hibiki/releases)

> **ดูสิ่งที่อยากดู แล้วเรียนรู้ภาษาไปในตัว**

hibiki เปลี่ยนนิยายที่คุณอ่าน ซีรีส์ที่คุณติดตาม และหนังสือเสียงที่คุณฟัง ให้กลายเป็นอินพุตทางภาษาของคุณ — แตะคำที่ไม่รู้จักเพื่อค้นหา แล้วแตะอีกครั้งเดียวเพื่อทำเป็นการ์ด Anki พร้อมบริบทต้นฉบับ มันไม่ได้บังคับให้คุณท่องรายการคำที่กำหนดไว้ล่วงหน้า แต่ช่วยให้คุณคว้าคำที่คุณ**ได้อ่านและได้ยินจริง ๆ**

วิธีเรียนภาษาที่ได้ผลที่สุดคือการสัมผัสเนื้อหาจริงในปริมาณมาก ไม่ใช่ท่องคำโดด ๆ จากหนังสือคำศัพท์ แต่ "การดื่มด่ำ" มักมีสองเรื่องน่ารำคาญเสมอ คือ การค้นคำทำให้สมาธิขาดตอน และพอละสายตาก็ลืม hibiki เชื่อมต่อวงจรนี้เข้าด้วยกัน —

📖 **อ่าน**: แตะคำในโปรแกรมอ่าน EPUB เพื่อค้นหา โดยไม่ต้องออกจากหน้าปัจจุบัน<br>
🎧 **ฟัง**: หนังสือเสียงไฮไลต์ตามทีละประโยคและพลิกหน้าให้อัตโนมัติ<br>
🎬 **ดู**: ค้นคำและทำการ์ดได้จากคำบรรยายวิดีโอโดยตรง — การติดตามซีรีส์ก็*คือ*อินพุต<br>
🃏 **สะสม**: ส่งคำที่ค้นจากทุกสถานการณ์เข้า Anki ด้วยปุ่มเดียว แล้วทบทวนเฉพาะคำที่คุณพบจริง ๆ

ทุกสถานการณ์ใช้พจนานุกรม สถิติ และกระบวนการทบทวนชุดเดียวกัน เหมาะกับทุกภาษา (ญี่ปุ่น อังกฤษ …) โดยเฉพาะผู้เรียนแบบดื่มด่ำที่เชื่อใน**การรับอินพุตปริมาณมาก + ท่องเฉพาะการ์ดที่ทำเอง** รองรับ Android และ Windows (iOS, macOS อยู่ระหว่างวางแผน)

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="ชั้นหนังสือ" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="คลังวิดีโอ" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="การอ่านแนวตั้งบนเดสก์ท็อปพร้อมป๊อปอัปค้นคำ" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="การค้นคำในวิดีโอ (ป๊อปอัปซ้อน)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="การค้นคำในวิดีโอ (รายการคำบรรยาย)" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-out-of-app-lookup-mobile.png" alt="การค้นคำด้วยการเลือกข้อความนอกแอป (มือถือ)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-out-of-app-lookup-desktop.png" alt="การค้นคำด้วยการเลือกข้อความนอกแอป (เดสก์ท็อป)" width="100%"></td>
  </tr>
</table>

**เดโมการสร้างการ์ด Anki ด้วยการแตะครั้งเดียว**

<video src="https://github.com/hajisensai/hibiki/raw/main/docs/static-assets/screenshots/hibiki-readme-anki-mining-demo.mp4" controls muted width="100%"></video>

> วิดีโอไม่แสดง? [ดูเดโมการสร้างการ์ดในคลิกเดียว ▶](https://github.com/hajisensai/hibiki/raw/main/docs/static-assets/screenshots/hibiki-readme-anki-mining-demo.mp4)

</div>

## คุณสมบัติ

### ชั้นหนังสือ

- นำเข้า EPUB ทีละไฟล์ เป็นชุด หรือแบบเรียกซ้ำตามโฟลเดอร์ ดูความคืบหน้าการอ่านบนชั้นหนังสือ
- จัดระเบียบหนังสือด้วยชั้นหนังสือที่กำหนดเอง การกรองด้วยแท็ก และการลากเพื่อจัดเรียงใหม่
- ลากและวางไฟล์เพื่อนำเข้าหนังสือ คำบรรยาย หรือวิดีโอ (เดสก์ท็อป)
- เชื่อมโยงไฟล์คำบรรยาย / เสียงที่มีชื่อเดียวกันโดยอัตโนมัติเมื่อนำเข้า

### การอ่าน

- อ่านแบบแนวตั้งหรือแนวนอน สลับระหว่างโหมดแบ่งหน้าและโหมดเลื่อนต่อเนื่อง
- ปรับแต่งธีม (สว่าง / มืด / ดำสนิท / กำหนดเอง) แบบอักษร ระยะห่างย่อหน้า และตัวควบคุมของโปรแกรมอ่าน
- คำอ่านกำกับ Furigana (ふりがな)
- ปรับขนาดส่วนติดต่อผู้ใช้ได้ ตัวควบคุมแถบล่างจะปรับตามขนาด
- โปรไฟล์ผู้ใช้หลายคน (Profile) สลับอัตโนมัติตามหนังสือ

### การค้นคำ

- นำเข้าพจนานุกรม [Yomitan](https://github.com/yomidevs/yomitan) (เดิมคือ Yomichan) ABBYY Lingvo (DSL) MDict (MDX) และ Migaku
- แตะข้อความในโปรแกรมอ่านเพื่อค้นคำ ค้นหาในหน้าพจนานุกรม หรือแชร์ข้อความจากแอปอื่น
- การแยกรูปคำ (deinflection) ครอบคลุม **ทุกภาษาของตารางการแปลงรูปของ Yomitan** + การปรับมาตรฐานข้อความก่อนค้นคำ (ตัวพิมพ์ / เครื่องหมายกำกับเสียง / harakat ภาษาอาหรับ) ขับเคลื่อนด้วยจุดรหัส (code points) โดยไม่ต้องสลับภาษา
- แตะคำภายในคำนิยามเพื่อค้นคำแบบเรียกซ้ำ (ป๊อปอัปซ้อน)
- การค้นหลายพจนานุกรมพร้อมกัน การจัดลำดับความสำคัญและการเปิด/ปิดแหล่งย่อย คำอ่านกำกับระดับเสียง (pitch-accent) และความถี่
- เสียงคำทั้งแบบออนไลน์และในเครื่อง
- แทรก CSS ที่กำหนดเอง

### ไฮไลต์และสถิติ

- เพิ่มไฮไลต์ห้าสีขณะอ่าน กระโดดไปยังไฮไลต์ใดก็ได้ทุกเมื่อ
- สถิติการอ่าน: จำนวนอักขระที่อ่าน ระยะเวลา ความเร็วในการอ่าน แสดงแบบเรียลไทม์ขณะอ่าน
- สถิติวิดีโอ: เวลาในการรับชม การ์ดที่สร้าง และรายการโปรด

### การสร้างการ์ด Anki

- สร้างการ์ดผ่าน [AnkiDroid](https://github.com/ankidroid/Anki-Android) หรือ AnkiConnect
- มีประเภทบันทึก [Lapis](https://github.com/donkuri/lapis) ในตัว (vendored 1.7.0) สร้างเทมเพลตการ์ดและสำรับภายในแอปด้วยการแตะครั้งเดียว
- เติมประโยคบริบทอัตโนมัติ การบันทึกเสียงและการครอบตัดภาพหน้าจอ
- โปรไฟล์การส่งออกหลายชุด (Profile) และการจับคู่ฟิลด์ที่กำหนดเอง
- คำโปรด การ์ดที่สร้างและรายการโปรดจะถูกนับรวมในสถิติ

### การซิงก์หนังสือเสียง (Sasayaki)

- รองรับคำบรรยาย SRT / LRC / VTT / ASS จับคู่ข้อความคำบรรยายกับเนื้อหา EPUB โดยอัตโนมัติ
- การไฮไลต์ประโยคตามการเล่นและการเปลี่ยนหน้าอัตโนมัติระหว่างเล่น
- ความเร็วในการเล่น การกระโดดตำแหน่ง และตัวควบคุมสื่อของระบบ
- "เล่นจากประโยคนี้" พร้อมการเล่นต่อข้ามบทอย่างราบรื่น

### การค้นคำจากคำบรรยายวิดีโอ

- เครื่องเล่นวิดีโอในตัวที่ใช้ [media_kit](https://github.com/media-kit/media-kit) (แกนหลัก libmpv)
- คำบรรยายแบบฝัง (แทร็กข้อความ + กราฟิก) และแบบภายนอก การนำเข้ารายการเล่น .m3u8
- ค้นคำและสร้างการ์ดจากคำบรรยายได้โดยตรงระหว่างเล่น
- การจัดการคลังวิดีโอ การกรองด้วยแท็ก การจัดกลุ่มเป็นซีรีส์ และการดำเนินการเป็นชุด

### การซิงก์ข้อมูล

- แบ็กเอนด์การซิงก์เจ็ดแบบ: Google Drive, OneDrive, Dropbox, WebDAV, FTP, SFTP และ Hibiki P2P
- ซิงก์ความคืบหน้าการอ่าน สถิติ และหนังสือ

### อื่น ๆ

- **ส่วนติดต่อผู้ใช้ 17 ภาษา** แปลครบทุกแพลตฟอร์ม
- แชร์ข้อความจากแอปอื่นเพื่อค้นคำได้โดยตรง

## การรองรับแพลตฟอร์ม

| แพลตฟอร์ม | สถานะ | การเรนเดอร์ / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |

> รองรับต่ำสุด Android 7.0 (API 24) ภาษาที่ใช้ค้นคำในพจนานุกรมจะถูกกำหนดโดยพจนานุกรมที่นำเข้าและตารางการแปลงรูปของ Yomitan โดยไม่ขึ้นกับภาษาของส่วนติดต่อผู้ใช้

### ภาษาของส่วนติดต่อผู้ใช้ (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## การติดตั้งและการสร้าง

เตรียมความพร้อมด้วยคำสั่งเดียว (`flutter pub get` + apply patches) แล้วจึงสร้าง:

```bash
# จากรากของ repository
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd hibiki
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows desktop
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` รวม `flutter pub get` และ `ci/apply-patches.sh` ไว้ในคำสั่งเดียว โปรเจกต์นี้ถูกล็อกไว้ที่ Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) ดีเพนเดนซีต้นทางบางตัวถูก vendor ไว้ใต้ `third_party/` หรือถูกแพตช์โดย `ci/apply-patches.sh` ดูรายละเอียดได้ที่ [docs/agent/build.md](../agent/build.md)

<details>
<summary><b>เทคโนโลยีที่ใช้</b></summary>

| ชั้น | เทคโนโลยี |
|---|---|
| เฟรมเวิร์ก | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| แพลตฟอร์ม | Android / Windows (Material Design 3) |
| โปรแกรมอ่าน | เครื่องมือแบ่งหน้าด้วย WebView (พัฒนาจากตระกูล Hoshi Reader) |
| วิดีโอ | media_kit (แกนหลัก libmpv) |
| ที่จัดเก็บข้อมูล | Drift (SQLite, WAL) + hoshidicts (เครื่องมือพจนานุกรม C++ FFI) |
| NLP | ตารางการแปลงรูปของ Yomitan (การหารูปฐานแบบหลายภาษา) + kana_kit (การแปลงคานะ) การแบ่งคำผ่าน hoshidicts FFI |
| การสร้างการ์ด | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 ภาษา) |

</details>

<details>
<summary><b>โครงสร้างโปรเจกต์</b></summary>

```
hibiki/                      # Repository root (Melos workspace: hibiki_workspace)
├── hibiki/                  # Flutter app main directory
│   ├── lib/
│   │   ├── i18n/            # Internationalization (17 languages, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (bookshelf, reader, dictionary, settings, etc.)
│   │   │   ├── reader/      # Reader WebView JS/CSS scripts
│   │   │   ├── media/       # Audiobook, subtitle parsing, reader source
│   │   │   └── models/      # Data models and state management (AppModel)
│   │   └── main.dart
│   └── android/             # Android project (manifest, native hoshidicts)
├── packages/                # Internal packages + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # hoshidicts C++ dictionary engine (FFI)
├── third_party/             # Vendored patched packages (dependency_overrides)
├── ci/                      # Build patches and integration test scripts
├── tool/                    # bootstrap / i18n_sync and other scripts
└── docs/                    # Development documentation (incl. docs/agent/ operations manual)
```

</details>

## ความเป็นส่วนตัวและข้อมูล

hibiki จัดเก็บหนังสือ พจนานุกรม แบบอักษร ข้อมูลหนังสือเสียง วิดีโอ ความคืบหน้าการอ่าน ไฮไลต์ สถิติ และการตั้งค่าที่นำเข้าไว้ในที่จัดเก็บข้อมูลในเครื่องของแอป

การซิงก์บนคลาวด์ (Google Drive / OneDrive / Dropbox) ใช้ข้อมูลรับรอง OAuth ที่ผู้ใช้กำหนดค่าเอง WebDAV / FTP / SFTP ใช้ที่อยู่เซิร์ฟเวอร์และข้อมูลรับรองที่ผู้ใช้ระบุ Hibiki P2P เชื่อมต่อโดยตรงผ่านที่อยู่ที่ผู้ใช้กำหนดค่า การสร้างการ์ด Anki จะสื่อสารกับ AnkiDroid หรือที่อยู่ AnkiConnect ที่กำหนดค่าไว้

## กิตติกรรมประกาศ

hibiki ต่อยอดจากโปรเจกต์และระบบนิเวศต่อไปนี้:

| โปรเจกต์ | คำอธิบาย |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | เครื่องมือเรียนภาษาญี่ปุ่นแบบ immersive |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | โปรแกรมอ่านภาษาญี่ปุ่นบน iOS แหล่งอ้างอิงเครื่องมือแบ่งหน้าของโปรแกรมอ่าน |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | โปรแกรมอ่านภาษาญี่ปุ่นแบบเนทีฟบน Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | เครื่องมือพจนานุกรม C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | โซลูชันการซิงก์หนังสือเสียง |
| [Yomitan](https://github.com/yomidevs/yomitan) | แหล่งอ้างอิงรูปแบบพจนานุกรม ตารางการแปลงรูป และประสบการณ์การค้นคำ |
| [Lapis](https://github.com/donkuri/lapis) | ประเภทบันทึกของ Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | การผสานการสร้างการ์ดบน Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | แหล่งอ้างอิงเสียงในเครื่องและการโต้ตอบกับ AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | แหล่งอ้างอิงโปรแกรมอ่าน สถิติ และความเข้ากันได้ของการซิงก์ |
| [media_kit](https://github.com/media-kit/media-kit) | เฟรมเวิร์กการเล่นวิดีโอของ Flutter (แกนหลัก libmpv) |

## สัญญาอนุญาต

เผยแพร่ภายใต้ GNU General Public License v3.0 ดูรายละเอียดได้ที่ [LICENSE](../../LICENSE)

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | **ภาษาไทย** | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
