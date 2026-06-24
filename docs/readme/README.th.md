<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>อ่านหนังสือสักเล่ม แล้วเปลี่ยนทุกคำศัพท์ใหม่ให้กลายเป็นของคุณ</b></p>
<p align="center">เครื่องอ่านแบบดื่มด่ำหลายแพลตฟอร์ม หลายภาษา —— อ่าน EPUB · แตะค้นหาคำ · สร้างบัตรคำ Anki · ซิงค์หนังสือเสียง · ค้นหาคำจากซับไตเติ้ลวิดีโอ</p>

<p align="center">
  <img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android">
  <img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black" alt="Linux">
  &nbsp;·&nbsp;
  <img src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="GPLv3">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 หน้าหลักของโปรเจกต์ (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <b>ภาษาไทย</b> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## บทนำ

**hibiki** เป็นเครื่องอ่านสำหรับเรียนภาษาแบบดื่มด่ำที่ทำงานได้หลายแพลตฟอร์ม **แตะเพื่อค้นหาคำ เลือกคำเพื่อวิเคราะห์** ได้ทันทีในเนื้อหา EPUB เปลี่ยนคำศัพท์ใหม่ให้กลายเป็นบัตรคำ Anki ด้วยการแตะครั้งเดียว ทำให้เสียงหนังสือเสียงไฮไลต์ทีละประโยคซิงค์กับเนื้อหา และยังค้นหาคำพร้อมสร้างบัตรคำได้จากซับไตเติ้ลวิดีโอโดยตรง เครื่องมือชุดเดียวครอบคลุมการรับข้อมูลแบบดื่มด่ำทั้งสามทาง คือ «อ่าน · ฟัง · ดู»

การค้นหาในพจนานุกรมครอบคลุม **ภาษาแปลงทั้งหมด** ของ [Yomitan](https://github.com/yomidevs/yomitan) (การผันกลับ + การทำให้ข้อความเป็นมาตรฐานก่อนค้นหา) อินเทอร์เฟซรองรับ **17 ภาษา** และรองรับ **Android / iOS / macOS / Windows / Linux** ครบทั้งห้าแพลตฟอร์ม

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="ชั้นหนังสือ" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="ค้นหาคำ" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="การตั้งค่าและธีม" width="300">
</p>
<p align="center"><sub>ชั้นหนังสือ · ค้นหาคำ · การตั้งค่าและธีม</sub></p>

---

## จุดเด่นหลัก

### 📖 อ่าน EPUB แตะแล้วค้นหาทันที

เครื่องอ่าน EPUB ที่แสดงผลด้วย WebView (เอนจินแบ่งหน้าที่พัฒนาต่อจาก [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) แตะคำใดก็ค้นหาได้ทันที เลือกข้อความก็วิเคราะห์ได้ทันที มีทั้งโหมดเลื่อนต่อเนื่องและแบ่งหน้า ฟอนต์และธีมกำหนดเอง (สว่าง / มืด / ดำสนิท / กำหนดเอง) พร้อมทั้งฟุริงานะ สถิติการอ่าน และบุ๊กมาร์กครบครัน

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="อ่านแนวตั้ง · ฟุริงานะ · ซิงค์หนังสือเสียง" width="300">
</p>
<p align="center"><sub>เนื้อหาแนวตั้ง · ฟุริงานะ · ไฮไลต์คำที่เลือก · แถบควบคุมการซิงค์หนังสือเสียงด้านล่าง</sub></p>

### 🔍 แตะค้นหาคำ ครอบคลุมภาษาแปลงทั้งหมดของ Yomitan

นำเข้าพจนานุกรมได้หลายรูปแบบ ทั้ง **Yomitan** (เดิม Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku** การคืนรูปคำหลายภาษา (ตารางแปลงของ Yomitan) + การทำให้ข้อความเป็นมาตรฐานก่อนค้นหา (ตัวพิมพ์ใหญ่เล็ก / เครื่องหมายเสียง / harakat ของอาหรับ) ขับเคลื่อนตามจุดรหัส (code point) โดยไม่ต้องสลับภาษา ค้นหาพร้อมกันหลายพจนานุกรม จัดลำดับและเปิดปิดแหล่งย่อย พร้อมการกำกับเสียงและความถี่ของคำ ทั้งหมดจบในหน้าต่างเดียว

### 🎴 สร้างบัตรคำ Anki ในขั้นตอนเดียว

เมื่อค้นพบคำใหม่ ส่งออกไปยัง [AnkiDroid](https://github.com/ankidroid/Anki-Android) และ AnkiConnect ได้ในขั้นตอนเดียว มาพร้อม schema ของชนิดโน้ต [Lapis](https://github.com/donkuri/lapis) ในตัว (vendored 1.7.0) สามารถสร้างเทมเพลตบัตรคำและสำรับได้ในแอปโดยตรง เติมประโยคบริบทอัตโนมัติ รองรับการบันทึกเสียงและการครอปภาพหน้าจอ มีหลายโปรไฟล์ส่งออก (Profile) การแมปฟิลด์กำหนดเอง และการดำเนินการด่วนสร้างบัตรคำในขั้นตอนเดียว

### 🎧 ซิงค์หนังสือเสียง (Sasayaki)

รองรับซับไตเติ้ล SRT / LRC / VTT / ASS โดยจัดวางข้อความซับไตเติ้ลให้ตรงกับเนื้อหา EPUB อัตโนมัติ ขณะเล่นจะ**ไฮไลต์ตามเสียงอ่านและเลื่อนหน้าซิงค์กับเสียง** ผสานกับแถบควบคุมการเล่น (ความคืบหน้า ข้ามไป ความเร็ว) ฟังหนังสือไปก็เห็นเนื้อหาสว่างทีละประโยค —— แถบควบคุมที่ด้านล่างของภาพหน้าจอการอ่านด้านบนของหน้านี้ก็คือฟังก์ชันนี้

### 🎬 ค้นหาคำจากซับไตเติ้ลวิดีโอ

มีเครื่องเล่นวิดีโอในตัวที่ใช้ media_kit / libmpv รองรับซับไตเติ้ลทั้งแบบฝังในและแบบไฟล์แยก ขณะเล่นวิดีโอสามารถ**ค้นหาคำและสร้างบัตรคำได้โดยตรงจากซับไตเติ้ล** นำสื่อภาพยนตร์มาเป็นส่วนหนึ่งของการรับข้อมูลแบบดื่มด่ำ พร้อมทั้งบันทึกสถิติเวลาในการดูและจำนวนบัตรคำที่สร้าง

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 ภาพหน้าจอเครื่องเล่นวิดีโอจะเพิ่มภายหลัง —— ต้องเก็บบนเครื่องจริง / เบื้องหน้า (ภาพวิดีโอ + แถบซับไตเติ้ล + หน้าต่างค้นหาคำ ดูรายละเอียดในคำอธิบายด้านล่าง)</sub></p>

### 🔗 เพิ่มเติม

- **17 ภาษาสำหรับอินเทอร์เฟซ** แปลครบทุกแพลตฟอร์ม
- **Hibiki Interconnect**: ซิงค์หนังสือ / พจนานุกรม / หนังสือเสียง / ความคืบหน้าการอ่าน ระหว่างอุปกรณ์
- **หลายโปรไฟล์ผู้ใช้ (Profile)** สลับอัตโนมัติตามหนังสือ
- **โหมดไม่ระบุตัวตน**; **แชร์ข้อความจากแอปอื่นเพื่อค้นหาคำ** ได้โดยตรง

---

## แพลตฟอร์มที่รองรับ

| แพลตฟอร์ม | สถานะ | การแสดงผล / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (fork ของ `flutter_inappwebview_windows` แสดงผล EPUB) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> ขั้นต่ำ Android 7.0 (API 24) ภาษาที่ใช้ค้นหาในพจนานุกรมขึ้นอยู่กับพจนานุกรมที่นำเข้าและตารางแปลงของ Yomitan เป็นอิสระจากภาษาอินเทอร์เฟซ

### ภาษาอินเทอร์เฟซ (17 ภาษา)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## การติดตั้งและการสร้าง

เตรียมด้วยคำสั่งเดียว (`flutter pub get` + แพตช์) จากนั้นสร้าง:

```bash
# ที่รากของ repo
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # หรือ (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` รวม ① `flutter pub get` กับ ② `ci/apply-patches.sh` ไว้ในคำสั่งเดียว โปรเจกต์นี้ล็อกเวอร์ชัน Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) ส่วนการพึ่งพาต้นทางบางส่วนถูก vendor ไว้ใน `third_party/` หรือถูกแพตช์โดย `ci/apply-patches.sh` —— รายละเอียดกลไก การสร้างทั้งห้าแพลตฟอร์ม รายการการพึ่งพาและแพตช์ ดูที่ [docs/agent/build.md](../agent/build.md)

<details>
<summary><b>สแตกเทคโนโลยีโดยสรุป</b></summary>

| ชั้น | เทคโนโลยี |
|---|---|
| เฟรมเวิร์ก | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| แพลตฟอร์ม | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino ปรับตามแพลตฟอร์ม) |
| ตัวอ่าน | เอนจินแบ่งหน้า WebView (พัฒนาต่อจาก [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| วิดีโอ | media_kit / libmpv |
| จัดเก็บข้อมูล | Drift (SQLite, WAL) + hoshidicts (เอนจินพจนานุกรม C++ FFI) |
| NLP | ตารางแปลงของ Yomitan (การคืนรูปคำหลายภาษา) + kana_kit (การแปลงคานะ); การแบ่งคำใช้ hoshidicts FFI |
| สร้างบัตรคำ | AnkiDroid API + AnkiConnect |
| สากลานุวัตน์ | Slang (17 ภาษา) |

</details>

<details>
<summary><b>โครงสร้างโปรเจกต์</b></summary>

```
hibiki/                      # รากของ repo (Melos workspace: hibiki_workspace)
├── hibiki/                  # ไดเรกทอรีหลักของแอป Flutter
│   ├── lib/
│   │   ├── i18n/            # สากลานุวัตน์ (17 ภาษา, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # หน้า (ชั้นหนังสือ, ตัวอ่าน, พจนานุกรม, การตั้งค่า ฯลฯ)
│   │   │   ├── reader/      # สคริปต์ JS/CSS WebView ของตัวอ่าน
│   │   │   ├── media/       # หนังสือเสียง, แยกวิเคราะห์ซับไตเติ้ล, reader source
│   │   │   └── models/      # โมเดลข้อมูลและการจัดการสถานะ (AppModel)
│   │   └── main.dart
│   └── android/             # โปรเจกต์ Android (manifest, native hoshidicts)
├── packages/                # package ภายใน + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── native/                  # เอนจินพจนานุกรม C++ hoshidicts (FFI)
├── third_party/             # แพ็กเกจแพตช์ vendored (dependency_overrides ชี้มา)
├── ci/                      # สคริปต์แพตช์การสร้างและการทดสอบรวม
├── tool/                    # สคริปต์ bootstrap / i18n_sync ฯลฯ
└── docs/                    # เอกสารการพัฒนา (รวมคู่มือการดำเนินการ agent ที่ docs/agent/)
```

</details>

---

## กิตติกรรมประกาศ

| โปรเจกต์ | คำอธิบาย |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | เครื่องมือเรียนภาษาญี่ปุ่นแบบดื่มด่ำ |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | เครื่องอ่านภาษาญี่ปุ่นสำหรับ Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | เอนจินพจนานุกรม C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | เครื่องอ่านภาษาญี่ปุ่นสำหรับ iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | โซลูชันซิงค์หนังสือเสียง |
| [Yomitan](https://github.com/yomidevs/yomitan) | แหล่งที่มาของรูปแบบพจนานุกรมและตารางแปลง |
| [Lapis](https://github.com/donkuri/lapis) | ชนิดโน้ตของ Anki |

## สัญญาอนุญาต

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <b>ภาษาไทย</b> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
