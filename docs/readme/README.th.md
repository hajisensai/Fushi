<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="โลโก้ Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | **ภาษาไทย** | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![ดาวน์โหลดเวอร์ชันล่าสุด](https://img.shields.io/badge/%E2%AC%87%20%E0%B8%94%E0%B8%B2%E0%B8%A7%E0%B8%99%E0%B9%8C%E0%B9%82%E0%B8%AB%E0%B8%A5%E0%B8%94%E0%B9%80%E0%B8%A7%E0%B8%AD%E0%B8%A3%E0%B9%8C%E0%B8%8A%E0%B8%B1%E0%B8%99%E0%B8%A5%E0%B9%88%E0%B8%B2%E0%B8%AA%E0%B8%B8%E0%B8%94-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![เข้าร่วม Discord](https://img.shields.io/badge/%E0%B9%80%E0%B8%82%E0%B9%89%E0%B8%B2%E0%B8%A3%E0%B9%88%E0%B8%A7%E0%B8%A1%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## การรองรับแพลตฟอร์ม

| แพลตฟอร์ม | สถานะ | การเรนเดอร์ / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> รองรับต่ำสุด Android 7.0 (API 24) ภาษาที่ใช้ค้นคำในพจนานุกรมจะถูกกำหนดโดยพจนานุกรมที่นำเข้าและตารางการแปลงรูปของ Yomitan โดยไม่ขึ้นกับภาษาของส่วนติดต่อผู้ใช้

### ภาษาของส่วนติดต่อผู้ใช้ (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## การติดตั้งและการสร้าง

เตรียมความพร้อมด้วยคำสั่งเดียว (`flutter pub get` + apply patches) แล้วจึงสร้าง:

```bash
# จากรากของ repository
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
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
| แพลตฟอร์ม | Android / Windows / macOS / iOS (Material Design 3) |
| โปรแกรมอ่าน | เครื่องมือแบ่งหน้าด้วย WebView (พัฒนาจากตระกูล Hoshi Reader) |
| วิดีโอ | media_kit (แกนหลัก libmpv) |
| ที่จัดเก็บข้อมูล | Drift (SQLite, WAL) + fushidicts (เครื่องมือพจนานุกรม C++ FFI) |
| NLP | ตารางการแปลงรูปของ Yomitan (การหารูปฐานแบบหลายภาษา) + kana_kit (การแปลงคานะ) การแบ่งคำผ่าน fushidicts FFI |
| การสร้างการ์ด | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 ภาษา) |

</details>

<details>
<summary><b>โครงสร้างโปรเจกต์</b></summary>

```
Fushi/                      # Repository root (Melos workspace: fushi_workspace)
├── fushi/                  # Flutter app main directory
│   ├── lib/
│   │   ├── i18n/            # Internationalization (17 languages, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (bookshelf, reader, dictionary, settings, etc.)
│   │   │   ├── reader/      # Reader WebView JS/CSS scripts
│   │   │   ├── media/       # Audiobook, subtitle parsing, reader source
│   │   │   └── models/      # Data models and state management (AppModel)
│   │   └── main.dart
│   └── android/             # Android project (manifest, native fushidicts)
├── packages/                # Internal packages + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # fushidicts C++ dictionary engine (FFI)
├── third_party/             # Vendored patched packages (dependency_overrides)
├── ci/                      # Build patches and integration test scripts
├── tool/                    # bootstrap / i18n_sync and other scripts
└── docs/                    # Development documentation (incl. docs/agent/ operations manual)
```

</details>

## ความเป็นส่วนตัวและข้อมูล

Fushi จัดเก็บหนังสือ พจนานุกรม แบบอักษร ข้อมูลหนังสือเสียง วิดีโอ ความคืบหน้าการอ่าน ไฮไลต์ สถิติ และการตั้งค่าที่นำเข้าไว้ในที่จัดเก็บข้อมูลในเครื่องของแอป

การซิงก์บนคลาวด์ (Google Drive / OneDrive / Dropbox) ใช้ข้อมูลรับรอง OAuth ที่ผู้ใช้กำหนดค่าเอง WebDAV / FTP / SFTP ใช้ที่อยู่เซิร์ฟเวอร์และข้อมูลรับรองที่ผู้ใช้ระบุ Fushi Interconnect เชื่อมต่อโดยตรงผ่านที่อยู่ที่ผู้ใช้กำหนดค่า การสร้างการ์ด Anki จะสื่อสารกับ AnkiDroid หรือที่อยู่ AnkiConnect ที่กำหนดค่าไว้

## กิตติกรรมประกาศ

Fushi ต่อยอดจากโปรเจกต์และระบบนิเวศต่อไปนี้:

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
| [Niratan](https://github.com/W1ght/Niratan) | ชุดเครื่องมือเรียนภาษาแบบ immersive สำหรับ macOS |

## สัญญาอนุญาต

เผยแพร่ภายใต้ GNU General Public License v3.0 ดูรายละเอียดได้ที่ [LICENSE](../../LICENSE)

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | **ภาษาไทย** | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
