<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">แอปอ่านภาษาญี่ปุ่นแบบดื่มด่ำสำหรับ Android</p>
<p align="center">EPUB · พจนานุกรม · Anki · ซิงค์หนังสือเสียง</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <b>ภาษาไทย</b> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## แนะนำ

**hibiki** เป็นแอปอ่านหนังสือบน Android สำหรับผู้เรียนภาษาญี่ปุ่น

## คุณสมบัติ

### การอ่าน EPUB
- แสดงผล EPUB ใน WebView (เอนจินแบ่งหน้าที่พัฒนาต่อจาก [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))
- แตะเพื่อค้นหาคำศัพท์ เลือกข้อความเพื่อวิเคราะห์
- ฟอนต์กำหนดเอง ธีม (สว่าง/มืด)
- สถิติการอ่านและบุ๊กมาร์ก
- โหมดเลื่อนต่อเนื่อง / แบ่งหน้า

### พจนานุกรม
- นำเข้าพจนานุกรมรูปแบบ [Yomitan](https://github.com/yomidevs/yomitan) (เดิม Yomichan)
- ข้อมูลสำเนียงและความถี่ของคำ
- ค้นหาพร้อมกันหลายพจนานุกรม ประวัติการค้นหา
- การผันกลับด้วย Ve

### บัตรคำ Anki
- ส่งออกด้วยการแตะครั้งเดียวไปยัง [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- เติมประโยคบริบทอัตโนมัติ
- รองรับบันทึกเสียง ครอปภาพหน้าจอ
- โปรไฟล์ส่งออกหลายแบบ แมปฟิลด์กำหนดเอง
- การดำเนินการด่วน (Quick Actions) สร้างบัตรคำขั้นตอนเดียว

### ซิงค์หนังสือเสียง (Sasayaki)
- รูปแบบซับไตเติ้ล: SRT / LRC / VTT / ASS
- จับคู่ซับไตเติ้ลกับข้อความ EPUB โดยอัตโนมัติ
- ไฮไลต์ตามเสียงอ่าน เลื่อนหน้าซิงค์กับเสียง
- แถบควบคุมการเล่น (ความคืบหน้า ข้ามไป ความเร็ว)

### อื่นๆ
- 17 ภาษาสำหรับอินเทอร์เฟซ
- โปรไฟล์ผู้ใช้หลายรายการ
- โหมดไม่ระบุตัวตน
- แชร์ข้อความจากแอปอื่นเพื่อค้นหาคำศัพท์

## ภาษาที่รองรับ

อินเทอร์เฟซรองรับภาษาต่อไปนี้:

| ภาษา | รหัส |
|---|---|
| English | `en` |
| 简体中文 | `zh-CN` |
| 繁體中文 | `zh-HK` |
| 日本語 | `ja` |
| 한국어 | `ko` |
| Español | `es` |
| Français | `fr` |
| Deutsch | `de` |
| Português (Brasil) | `pt-BR` |
| Русский | `ru` |
| Tiếng Việt | `vi` |
| ภาษาไทย | `th` |
| Bahasa Indonesia | `id` |
| Italiano | `it` |
| Nederlands | `nl` |
| Türkçe | `tr` |
| العربية | `ar` |

## สแตกเทคโนโลยี

| ชั้น | เทคโนโลยี |
|---|---|
| เฟรมเวิร์ก | Flutter 3.41.6 (Dart SDK `>=3.5.0 <4.0.0`) |
| แพลตฟอร์ม | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino ปรับตามแพลตฟอร์ม) |
| ตัวอ่าน | เอนจินแบ่งหน้า WebView (พัฒนาต่อจาก [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| จัดเก็บข้อมูล | Drift (SQLite, WAL) + hoshidicts (เอนจินพจนานุกรม C++ FFI) |
| NLP | Ve (การผันกลับ) |
| สร้างบัตรคำ | AnkiDroid API |
| สากลานุวัตน์ | Slang (17 ภาษา) |
| เวอร์ชันขั้นต่ำ | Android 7.0 (API 24) |

## การสร้าง

เตรียมด้วยคำสั่งเดียว (`flutter pub get` + แพตช์) จากนั้นสร้าง:

```bash
# ที่รากของ repo
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # หรือ (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` รวมสองสิ่งไว้ในคำสั่งเดียว: ① `flutter pub get`;
② รัน `ci/apply-patches.sh` `melos bootstrap` ทำสิ่งเดียวกันผ่าน post hook
(บน Windows melos มีบั๊กการเข้ารหัส CJK จึงใช้ `tool/bootstrap.ps1` แทน)

> **หมายเหตุเกี่ยวกับแพตช์:** `ci/apply-patches.sh` จะเขียนทับการเปลี่ยนแปลงใน `ci/patches/` ลงบน pub cache จริง ทุกครั้งที่ล้าง pub cache หรือรัน `flutter pub get` ใหม่ต้องรันซ้ำ (bootstrap รวมขั้นตอนนี้แล้ว) เมื่อสคริปต์ไม่พบเป้าหมายแพตช์ใดเลย จะข้ามและเตือนแทนที่จะแสร้งว่าสำเร็จ

## การพึ่งพาและแพตช์

โปรเจกต์นี้ล็อกเวอร์ชัน Flutter 3.41.6 การพึ่งพาต้นทางบางส่วนยังไม่รองรับ การแพตช์แบ่งเป็นสองกลไก: ① แพ็กเกจที่ต้องใช้เป็นอินพุตของการสร้างและทำซ้ำให้เหมือนกันทุกเครื่อง จะถูก vendor ไว้ใน `third_party/` โดยตรงและชี้ด้วย `dependency_overrides` (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, **ไม่** ต้องแพตช์ pub-cache); ② แพ็กเกจที่เหลือถูกแพตช์ซอร์สใน pub cache โดย `ci/apply-patches.sh` รายละเอียดกลไกดูที่ [docs/agent/build.md](../agent/build.md) ตารางพับด้านล่างเป็นรายการเชิงประวัติจัดกลุ่มตามการเปลี่ยนแปลง แพ็กเกจที่ทับซ้อนกับกลไก ① ให้ยึดเวอร์ชัน vendored เป็นหลัก

<details>
<summary><b>แพตช์การเปลี่ยนแปลง Flutter API</b></summary>

| แพ็กเกจ | การเปลี่ยนแปลง |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; แทนที่ `imageCache.putIfAbsent` ที่ถูกลบ |
| `flutter_blurhash` 0.7.0 | เช่นเดียวกัน `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | เพิ่ม `hide CarouselController` ใน import ภายในเพื่อหลีกเลี่ยงชื่อซ้ำ |
| `fading_edge_scrollview` 3.0.0 | แก้ไข `PageView.controller` nullable |

</details>

<details>
<summary><b>แพตช์ลบ v1 Embedding</b></summary>

Flutter 3.41.6 ลบ v1 embedding API (`PluginRegistry.Registrar`) ออกทั้งหมด ปลั๊กอินต่อไปนี้ต้องลบการอ้างอิงที่เกี่ยวข้อง:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>แพตช์ Gradle / Kotlin</b></summary>

| เป้าหมาย | การเปลี่ยนแปลง |
|---|---|
| `android/build.gradle` afterEvaluate | บังคับ `compileSdk` ในโปรเจกต์ย่อย (ค่าเริ่มต้น 36, บางตัว 34); ลบ `-Werror` |
| `audio_session` 0.1.14 | ลบ `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | แก้ไข Kotlin null safety |
| `receive_intent` (git) | แก้ไข Kotlin null safety |

</details>

<details>
<summary><b>การพึ่งพา Git</b></summary>

| แพ็กเกจ | แหล่งที่มา |
|---|---|
| `blurrycontainer` | [arianneorpilla/blurry_container](https://github.com/arianneorpilla/blurry_container/) |
| `filesystem_picker` | [arianneorpilla/filesystem_picker](https://github.com/arianneorpilla/filesystem_picker) |
| `flutter_inappwebview` | [arianneorpilla/flutter_inappwebview](https://github.com/arianneorpilla/flutter_inappwebview) |
| `material_floating_search_bar` | [arianneorpilla/material_floating_search_bar](https://github.com/arianneorpilla/material_floating_search_bar) |
| `ruby_text` | [arianneorpilla/RubyText](https://github.com/arianneorpilla/RubyText) |
| `spaces` | [arianneorpilla/spaces](https://github.com/arianneorpilla/spaces) |
| `ve_dart` | [arianneorpilla/ve_dart](https://github.com/arianneorpilla/ve_dart) |
| `receive_intent` | [arianneorpilla/receive_intent](https://github.com/arianneorpilla/receive_intent) |
| `wakelock` | [diegotori/wakelock](https://github.com/diegotori/wakelock) |

</details>

## โครงสร้างโปรเจกต์

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
├── third_party/             # แพ็กเกจแพตช์ vendored (dependency_overrides ชี้มา)
├── ci/                      # สคริปต์แพตช์การสร้างและการทดสอบรวม
├── tool/                    # สคริปต์ bootstrap / i18n_sync ฯลฯ
└── docs/                    # เอกสารการพัฒนา (รวมคู่มือการดำเนินการ agent docs/agent/)
```

## กิตติกรรมประกาศ

| โปรเจกต์ | คำอธิบาย |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | เครื่องมือเรียนภาษาญี่ปุ่นแบบดื่มด่ำ |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | แอปอ่านภาษาญี่ปุ่นสำหรับ Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | เอนจินพจนานุกรม C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | แอปอ่านภาษาญี่ปุ่นสำหรับ iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | โซลูชันซิงค์หนังสือเสียง |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | เอนจินแสดงผล EPUB |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | เวอร์ชันชุมชนของ ttu (SvelteKit v2) ต้นทางของ hibiki fork |
| [Yomitan](https://github.com/yomidevs/yomitan) | แหล่งที่มารูปแบบพจนานุกรม |

## สัญญาอนุญาต

[GNU General Public License v3.0](../../LICENSE)
